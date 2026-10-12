// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OwnableUpgradeable} from "@oz/access/OwnableUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

/**
 * @notice Fork test of a freshly deployed BridgePaymaster against the live Stargate OFTs and
 *         CardDepositManager on Fuse (chain 122).
 * @dev Deployed and configured the way script/fuse/BridgePaymasterBridgeSend.s.sol does it: an
 *      ERC1967 proxy initialised to a deployer, `initializeV2`, then the targets, caps and routes,
 *      before ownership moves to the Safe. Sends go through the real Stargate contracts, so the
 *      quoted fee, the path credit and the `minAmountLD` check are the ones users will hit, not a
 *      mock's.
 *
 * Run with: forge test --match-path test/fuse/BridgePaymasterBridgeSend.t.sol
 *           (forks FUSE_RPC_URL, defaulting to https://rpc.fuse.io)
 */
contract BridgePaymasterBridgeSendTest is Test {
    /// @dev The proxy is placed at a fixed address so the EIP-712 domain - and with it the
    ///      `CAST_SIGNATURE` below - does not depend on deployment order.
    BridgePaymaster internal constant PAYMASTER = BridgePaymaster(payable(0x0000000000000000000000000000000000012200));

    /// @dev The Safe that owns the old paymaster and takes ownership of the new one.
    address internal constant OWNER_SAFE = 0xBA308f2919aa20fbD58fc7406451077fe32F1F29;

    address internal constant CARD_DEPOSIT_MANAGER = 0x22BBc13D022735f2586d4eb04a93f0F4E0173E50;

    /// @dev Stargate v2 Hydra OFTs on Fuse and the tokens they burn.
    address internal constant USDC_OFT = 0xAF54BE5B6eEc24d6BFACf1cce4eaF680A8239398;
    address internal constant USDT_OFT = 0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6;
    address internal constant WETH_OFT = 0x45f1A95A4D3f3836523F5c83673c797f4d4d263B;
    address internal constant USDC_E = 0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9;
    address internal constant USDT = 0x3695Dd1D1D43B794C0B13eb8be8419Eb3ac22bf7;

    uint32 internal constant ETHEREUM = 30101;
    uint32 internal constant BNB = 30102;
    uint32 internal constant ARBITRUM = 30110;
    uint32 internal constant BASE = 30184;

    uint256 internal constant MIN_AMOUNT = 5e6;
    uint256 internal constant MAX_AMOUNT = 10_000e6;
    uint256 internal constant DAILY_BUDGET = 50_000 ether;

    /// @dev A voucher for these exact fields, signed by `CAST_SIGNER` with `cast wallet sign --data`
    ///      (alloy's EIP-712 encoder), against `PAYMASTER`'s domain on chain 122. Recovering it through
    ///      `hashVoucher` proves the contract's encoding matches standard typed data, not just itself.
    address internal constant CAST_SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes internal constant CAST_SIGNATURE =
        hex"da11ce494a50c99c129d6a764d0265b490ae8eda7d82f9c4a230d1524d085cd77b5667d2f7ebaa878e69d4be9e118c075a814ef9d4dfa68492c52a7cb4173a001b";

    event BridgeSent(
        address indexed from,
        address indexed oft,
        uint256 indexed nonce,
        uint32 dstEid,
        address to,
        uint256 amountLD,
        uint256 feeLD,
        uint256 amountReceivedLD,
        bytes32 guid,
        uint256 nativeFee
    );

    address internal deployer = makeAddr("deployer");
    address internal implementation;
    uint256 internal signerKey = 0xA11CE;
    address internal signer;
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal user = makeAddr("userSafe");
    address internal recipient = makeAddr("exchangeDepositAddress");
    uint256 internal nextNonce = 1;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FUSE_RPC_URL", string("https://rpc.fuse.io")));
        signer = vm.addr(signerKey);
        implementation = address(new BridgePaymaster());
    }

    modifier deployed() {
        _deployAndConfigure();
        _;
    }

    // ===================================== DEPLOYMENT =====================================

    function test_deploy_ownerAndSettings() public deployed {
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(PAYMASTER), implementationSlot)))), implementation);
        assertEq(PAYMASTER.owner(), deployer);
        assertEq(PAYMASTER.voucherSigner(), signer);
        assertEq(PAYMASTER.feeRecipient(), feeRecipient);
        assertEq(PAYMASTER.dailyFeeBudget(), DAILY_BUDGET);
        assertEq(uint8(PAYMASTER.targetKind(CARD_DEPOSIT_MANAGER)), uint8(BridgePaymaster.TargetKind.CARD_DEPOSIT_MANAGER));

        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            PAYMASTER.eip712Domain();
        assertEq(name, "BridgePaymaster");
        assertEq(version, "1");
        assertEq(chainId, 122);
        assertEq(verifyingContract, address(PAYMASTER));
    }

    function test_implementation_cannotBeInitialized() public {
        // The implementation's constructor disables initializers, so nobody can take it over.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        BridgePaymaster(payable(implementation)).initialize(makeAddr("attacker"));
    }

    function test_initializeV2_cannotRunTwice() public deployed {
        vm.prank(deployer);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PAYMASTER.initializeV2(signer, feeRecipient, DAILY_BUDGET);
    }

    function test_initializeV2_rejectsNonOwner() public {
        // A proxy initialised without the V2 step must not leave it open to anyone.
        BridgePaymaster bare = BridgePaymaster(
            payable(address(new ERC1967Proxy(implementation, abi.encodeCall(BridgePaymaster.initialize, (deployer)))))
        );

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        bare.initializeV2(attacker, attacker, type(uint256).max);
    }

    function test_transferOwnership_handsControlToTheSafe() public deployed {
        vm.prank(deployer);
        PAYMASTER.transferOwnership(OWNER_SAFE);
        assertEq(PAYMASTER.owner(), OWNER_SAFE);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, deployer));
        PAYMASTER.setRoute(USDT_OFT, BASE, true);

        vm.prank(OWNER_SAFE);
        PAYMASTER.setTarget(USDC_OFT, BridgePaymaster.TargetKind.NONE, 0);
        assertEq(uint8(PAYMASTER.targetKind(USDC_OFT)), uint8(BridgePaymaster.TargetKind.NONE));
    }

    function test_hashVoucher_matchesStandardTypedData() public deployed {
        BridgePaymaster.SendVoucher memory v = BridgePaymaster.SendVoucher({
            from: 0x1111111111111111111111111111111111111111,
            oft: USDC_OFT,
            dstEid: ARBITRUM,
            to: 0x2222222222222222222222222222222222222222,
            amountLD: 100_000000,
            feeLD: 420000,
            maxNativeFee: 40 ether,
            minAmountLD: 99_500000,
            nonce: 81723,
            deadline: 1_900_000_000
        });
        assertEq(ECDSA.recover(PAYMASTER.hashVoucher(v), CAST_SIGNATURE), CAST_SIGNER);
    }

    // ===================================== HAPPY PATH =====================================

    function test_bridgeSend_usdcToArbitrum() public deployed {
        _assertBridgeSend(USDC_OFT, USDC_E, ARBITRUM, 100e6);
    }

    function test_bridgeSend_usdcToBase() public deployed {
        _assertBridgeSend(USDC_OFT, USDC_E, BASE, 100e6);
    }

    function test_bridgeSend_usdtToEthereum() public deployed {
        _assertBridgeSend(USDT_OFT, USDT, ETHEREUM, 100e6);
    }

    function test_bridgeSend_usdtToBnb() public deployed {
        _assertBridgeSend(USDT_OFT, USDT, BNB, 100e6);
    }

    // ===================================== VOUCHER =====================================

    function test_bridgeSend_rejectsLoweredFee() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(USDC_OFT, ARBITRUM, 100e6);
        v.feeLD = 0;
        _fund(USDC_E, 100e6);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InvalidVoucherSignature.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsRedirectedRecipient() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(USDC_OFT, ARBITRUM, 100e6);
        v.to = makeAddr("someoneElse");
        _fund(USDC_E, 100e6);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InvalidVoucherSignature.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsOtherSigner() public deployed {
        (BridgePaymaster.SendVoucher memory v,) = _signedVoucher(USDC_OFT, ARBITRUM, 100e6);
        bytes memory sig = _sign(0xB0B, v);
        _fund(USDC_E, 100e6);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InvalidVoucherSignature.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsReplay() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(USDC_OFT, ARBITRUM, 100e6);
        _fund(USDC_E, 200e6);

        vm.startPrank(user);
        PAYMASTER.bridgeSend(v, sig);
        vm.expectRevert(BridgePaymaster.VoucherUsed.selector);
        PAYMASTER.bridgeSend(v, sig);
        vm.stopPrank();
    }

    function test_bridgeSend_rejectsExpired() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(USDC_OFT, ARBITRUM, 100e6);
        _fund(USDC_E, 100e6);
        vm.warp(uint256(v.deadline) + 1);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.VoucherExpired.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsOtherCaller() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(USDC_OFT, ARBITRUM, 100e6);

        vm.prank(makeAddr("thief"));
        vm.expectRevert(BridgePaymaster.VoucherNotForCaller.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    // ===================================== LIMITS =====================================

    function test_bridgeSend_rejectsFeeAboveVoucher() public deployed {
        BridgePaymaster.SendVoucher memory v = _voucher(USDC_OFT, ARBITRUM, 100e6);
        v.maxNativeFee = _quoteNativeFee(v) - 1;
        bytes memory sig = _sign(signerKey, v);
        _fund(USDC_E, 100e6);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.NativeFeeAboveVoucher.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsRouteNotAllowed() public deployed {
        // There is no standard USDT on Base, so that route is never allowed.
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucherUnquoted(USDT_OFT, BASE, 100e6);
        _fund(USDT, 100e6);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.RouteNotAllowed.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsUnregisteredOft() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucherUnquoted(WETH_OFT, ARBITRUM, 1 ether);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.UnsupportedTarget.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsBelowMinimum() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) =
            _signedVoucherUnquoted(USDC_OFT, ARBITRUM, MIN_AMOUNT - 1);
        _fund(USDC_E, MIN_AMOUNT);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.AmountBelowMinimum.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsAboveMaximum() public deployed {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) =
            _signedVoucherUnquoted(USDC_OFT, ARBITRUM, MAX_AMOUNT + 1);
        _fund(USDC_E, MAX_AMOUNT + 1);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.AmountAboveMaximum.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_rejectsFeeCoveringWholeAmount() public deployed {
        BridgePaymaster.SendVoucher memory v = _voucher(USDC_OFT, ARBITRUM, 100e6);
        v.feeLD = v.amountLD;
        bytes memory sig = _sign(signerKey, v);
        _fund(USDC_E, 100e6);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.FeeExceedsAmount.selector);
        PAYMASTER.bridgeSend(v, sig);
    }

    function test_bridgeSend_dailyBudgetCapsAndResets() public deployed {
        BridgePaymaster.SendVoucher memory first = _voucher(USDC_OFT, ARBITRUM, 100e6);
        first.deadline = uint64(block.timestamp + 2 days);
        uint256 fee = _quoteNativeFee(first);

        vm.prank(deployer);
        PAYMASTER.setDailyFeeBudget(fee);
        _fund(USDC_E, 300e6);

        // Sign before pranking: `_sign` calls `hashVoucher`, which would consume the prank.
        bytes memory firstSig = _sign(signerKey, first);
        vm.prank(user);
        PAYMASTER.bridgeSend(first, firstSig);

        BridgePaymaster.SendVoucher memory second = _voucher(USDC_OFT, ARBITRUM, 100e6);
        second.deadline = uint64(block.timestamp + 2 days);
        bytes memory secondSig = _sign(signerKey, second);

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.DailyFeeBudgetExceeded.selector);
        PAYMASTER.bridgeSend(second, secondSig);

        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        PAYMASTER.bridgeSend(second, secondSig);
    }

    // ============================ EXISTING ENTRYPOINTS: OPTIONS ============================

    function test_sponsorCardDeposit_rejectsNativeDrop() public deployed {
        SendParam memory sendParam = _bareSendParam(ARBITRUM, recipient, 1e6);
        // Executor option: worker 1, length 49, type 2 (native drop), 0.01 ETH to `recipient`.
        sendParam.extraOptions =
            abi.encodePacked(uint16(3), uint8(1), uint16(49), uint8(2), uint128(0.01 ether), bytes32(uint256(uint160(recipient))));

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.OptionsNotAllowed.selector);
        PAYMASTER.sponsorCardDeposit(CARD_DEPOSIT_MANAGER, USDC_OFT, sendParam);
    }

    function test_sponsorCardDeposit_rejectsComposeMsg() public deployed {
        SendParam memory sendParam = _bareSendParam(ARBITRUM, recipient, 1e6);
        sendParam.composeMsg = hex"01";

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.OptionsNotAllowed.selector);
        PAYMASTER.sponsorCardDeposit(CARD_DEPOSIT_MANAGER, USDC_OFT, sendParam);
    }

    function test_sponsorCardSwapAndDeposit_rejectsNativeDrop() public deployed {
        SendParam memory sendParam = _bareSendParam(ARBITRUM, recipient, 1e6);
        sendParam.extraOptions = hex"0003";

        vm.prank(user);
        vm.expectRevert(BridgePaymaster.OptionsNotAllowed.selector);
        PAYMASTER.sponsorCardSwapAndDeposit(CARD_DEPOSIT_MANAGER, USDC_OFT, 1e6, sendParam);
    }

    // ===================================== HELPERS =====================================

    function _deployAndConfigure() internal {
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(implementation, abi.encodeCall(BridgePaymaster.initialize, (deployer))),
            address(PAYMASTER)
        );

        vm.startPrank(deployer);
        PAYMASTER.initializeV2(signer, feeRecipient, DAILY_BUDGET);
        PAYMASTER.setTarget(CARD_DEPOSIT_MANAGER, BridgePaymaster.TargetKind.CARD_DEPOSIT_MANAGER, 0);
        PAYMASTER.setTarget(USDC_OFT, BridgePaymaster.TargetKind.STARGATE_OFT, MIN_AMOUNT);
        PAYMASTER.setTarget(USDT_OFT, BridgePaymaster.TargetKind.STARGATE_OFT, MIN_AMOUNT);
        PAYMASTER.setMaxSponsoredAmount(USDC_OFT, MAX_AMOUNT);
        PAYMASTER.setMaxSponsoredAmount(USDT_OFT, MAX_AMOUNT);
        PAYMASTER.setRoute(USDC_OFT, ARBITRUM, true);
        PAYMASTER.setRoute(USDC_OFT, BASE, true);
        PAYMASTER.setRoute(USDC_OFT, BNB, true);
        PAYMASTER.setRoute(USDC_OFT, ETHEREUM, true);
        PAYMASTER.setRoute(USDT_OFT, ARBITRUM, true);
        PAYMASTER.setRoute(USDT_OFT, BNB, true);
        PAYMASTER.setRoute(USDT_OFT, ETHEREUM, true);
        vm.stopPrank();

        // The FUSE the old paymaster's balance would bring over; pinned so fee tests don't depend on it.
        vm.deal(address(PAYMASTER), 10_000 ether);
    }

    struct Balances {
        uint256 user;
        uint256 feeRecipient;
        uint256 paymasterToken;
        uint256 paymasterNative;
    }

    function _assertBridgeSend(address oft, address token, uint32 dstEid, uint256 amount) internal {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(oft, dstEid, amount);
        _fund(token, amount);

        Balances memory before = _balances(token);
        uint256 expectedFee = _quoteNativeFee(v);

        vm.expectEmit(true, true, true, false, address(PAYMASTER));
        emit BridgeSent(user, oft, v.nonce, 0, address(0), 0, 0, 0, bytes32(0), 0);

        vm.prank(user);
        (uint256 nativeFee, bytes32 guid) = PAYMASTER.bridgeSend(v, sig);

        Balances memory afterSend = _balances(token);
        assertEq(nativeFee, expectedFee, "native fee is the bare quote");
        assertLe(nativeFee, v.maxNativeFee, "native fee within voucher");
        assertTrue(guid != bytes32(0), "LayerZero guid");
        assertEq(afterSend.user, before.user - amount, "user debited the full amount");
        assertEq(afterSend.feeRecipient, before.feeRecipient + v.feeLD, "fee kept in token");
        assertEq(afterSend.paymasterToken, before.paymasterToken, "nothing left on paymaster");
        assertEq(afterSend.paymasterNative, before.paymasterNative - nativeFee, "paymaster fronts exactly the fee");
        assertEq(IERC20(token).allowance(address(PAYMASTER), oft), 0, "approval reset");
        assertTrue(PAYMASTER.usedNonce(v.nonce), "nonce spent");
        assertEq(PAYMASTER.feeSpentToday(), nativeFee, "daily spend tracked");
    }

    function _balances(address token) internal view returns (Balances memory b) {
        b.user = IERC20(token).balanceOf(user);
        b.feeRecipient = IERC20(token).balanceOf(feeRecipient);
        b.paymasterToken = IERC20(token).balanceOf(address(PAYMASTER));
        b.paymasterNative = address(PAYMASTER).balance;
    }

    /// @dev Prices the voucher the way the backend will: quote the bare send, put 10% headroom on
    ///      the native fee, and require the recipient to get at least what Stargate quotes.
    function _voucher(address oft, uint32 dstEid, uint256 amount)
        internal
        returns (BridgePaymaster.SendVoucher memory v)
    {
        v = _voucherFields(oft, dstEid, amount);
        // 0.5 tokens stands in for the backend's FUSE -> token conversion; any value below
        // `amountLD` is accepted on-chain.
        v.feeLD = 500_000;
        uint256 nativeFee = _quoteNativeFee(v);
        v.maxNativeFee = nativeFee + nativeFee / 10;
        (,, OFTReceipt memory receipt) = IOFT(oft).quoteOFT(_bareSendParam(dstEid, v.to, amount - v.feeLD));
        v.minAmountLD = receipt.amountReceivedLD;
    }

    function _voucherFields(address oft, uint32 dstEid, uint256 amount)
        internal
        returns (BridgePaymaster.SendVoucher memory v)
    {
        v.from = user;
        v.oft = oft;
        v.dstEid = dstEid;
        v.to = recipient;
        v.amountLD = amount;
        v.nonce = nextNonce++;
        v.deadline = uint64(block.timestamp + 10 minutes);
    }

    function _signedVoucher(address oft, uint32 dstEid, uint256 amount)
        internal
        returns (BridgePaymaster.SendVoucher memory v, bytes memory sig)
    {
        v = _voucher(oft, dstEid, amount);
        sig = _sign(signerKey, v);
    }

    /// @dev For vouchers that must revert before any quote: unsupported routes and amounts that
    ///      Stargate itself might refuse to quote.
    function _signedVoucherUnquoted(address oft, uint32 dstEid, uint256 amount)
        internal
        returns (BridgePaymaster.SendVoucher memory v, bytes memory sig)
    {
        v = _voucherFields(oft, dstEid, amount);
        v.feeLD = 1;
        v.maxNativeFee = 1_000 ether;
        sig = _sign(signerKey, v);
    }

    function _quoteNativeFee(BridgePaymaster.SendVoucher memory v) internal view returns (uint256) {
        return IOFT(v.oft).quoteSend(_bareSendParam(v.dstEid, v.to, v.amountLD - v.feeLD), false).nativeFee;
    }

    function _bareSendParam(uint32 dstEid, address to, uint256 amountLD) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(to))),
            amountLD: amountLD,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }

    function _sign(uint256 key, BridgePaymaster.SendVoucher memory v) internal view returns (bytes memory) {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(key, PAYMASTER.hashVoucher(v));
        return abi.encodePacked(r, s, sv);
    }

    function _fund(address token, uint256 amount) internal {
        deal(token, user, IERC20(token).balanceOf(user) + amount);
        vm.prank(user);
        IERC20(token).approve(address(PAYMASTER), type(uint256).max);
    }
}
