// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

contract MockToken is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev Stands in for LI.FI's diamond: the two Stargate functions `lifiCall` accepts, taking the
 *      input the way LI.FI does (the coin from its caller, the native fee in `msg.value`) and
 *      handing back whatever leftovers a test sets, as LI.FI does with unspent input.
 */
contract MockLifiDiamond {
    using SafeERC20 for IERC20;

    uint256 public leftoverTokens;
    uint256 public leftoverNative;
    bool public fail;
    uint256 public lastValue;
    uint256 public lastAllowance;

    function configure(uint256 tokens, uint256 native, bool shouldFail) external {
        leftoverTokens = tokens;
        leftoverNative = native;
        fail = shouldFail;
    }

    function swapAndStartBridgeTokensViaStargate(
        BridgePaymaster.LifiBridgeData calldata,
        BridgePaymaster.LifiSwapData[] calldata swaps,
        BridgePaymaster.LifiStargateData calldata stargateData
    ) external payable {
        _take(swaps[0].sendingAssetId, swaps[0].fromAmount, stargateData.fee.nativeFee);
    }

    function startBridgeTokensViaStargate(
        BridgePaymaster.LifiBridgeData calldata bridgeData,
        BridgePaymaster.LifiStargateData calldata stargateData
    ) external payable {
        _take(bridgeData.sendingAssetId, bridgeData.minAmount, stargateData.fee.nativeFee);
    }

    function _take(address asset, uint256 amount, uint256 fee) internal {
        require(!fail, "LiFi: swap failed");
        lastValue = msg.value;
        if (asset == address(0)) {
            require(msg.value == amount + fee, "LiFi: value");
        } else {
            require(msg.value == fee, "LiFi: fee");
            lastAllowance = IERC20(asset).allowance(msg.sender, address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (leftoverTokens > 0) IERC20(asset).safeTransfer(msg.sender, leftoverTokens);
        }
        if (leftoverNative > 0) {
            (bool ok,) = msg.sender.call{value: leftoverNative}("");
            require(ok, "LiFi: refund");
        }
    }

    receive() external payable {}
}

/**
 * @notice Unit tests of `BridgePaymaster.lifiCall` against a stand-in LI.FI diamond: the checks
 *         on the voucher and on the LI.FI calldata, the fee paid on top, and the refunds.
 * @dev The proxy sits at a fixed address on chain 8453 so `CAST_SIGNATURE` pins the EIP-712
 *      encoding to standard typed data, as the backend signs it.
 *
 * Run with: forge test --match-path test/fuse/BridgePaymasterLifiCall.t.sol
 */
contract BridgePaymasterLifiCallTest is Test {
    BridgePaymaster internal constant PAYMASTER = BridgePaymaster(payable(0x0000000000000000000000000000000000084530));

    uint32 internal constant FUSE_EID = 30138;
    uint32 internal constant ARBITRUM_EID = 30110;
    uint256 internal constant FEE = 539248033281088;
    uint256 internal constant CAP = 0.005 ether;
    uint256 internal constant DAILY_BUDGET = 0.05 ether;

    /// @dev LI.FI's options for a Stargate send with a compose: lzCompose gas 695,200 then
    ///      lzReceive gas 131,072, as in a live Base → Fuse quote.
    bytes internal constant LIFI_OPTIONS =
        hex"0003010013030000000000000000000000000000000a9ba00100110100000000000000000000000000020000";

    /// @dev The voucher in `test_hashLifiVoucher_matchesStandardTypedData`, signed by this key with `cast wallet sign --data` (alloy's EIP-712
    ///      encoder) against `PAYMASTER`'s domain on chain 8453.
    address internal constant CAST_SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes internal constant CAST_SIGNATURE =
        hex"d17c934fd5b9d61022a1bbf17d35431a92fa7884a487880727cddc056328ff34179f7471ed326956fe901f10ba450d62b05c9c2083eff6c6b647cd67dc3ea3221b";

    address internal deployer = makeAddr("deployer");
    uint256 internal signerKey = 0xA11CE;
    address internal signer;
    address internal user = makeAddr("userSafe");
    address internal lifiReceiverOnFuse = makeAddr("lifiReceiverOnFuse");
    address internal dex = makeAddr("dex");
    MockLifiDiamond internal diamond;
    MockToken internal uni;
    MockToken internal usdc;
    uint256 internal nextNonce = 1;

    event LifiCallSponsored(
        address indexed from,
        address indexed target,
        uint256 indexed nonce,
        address token,
        uint256 amount,
        uint256 nativeFee,
        bytes32 transactionId
    );

    /// @dev The parts of a LI.FI Stargate call the checks look at, so each test can break one.
    struct Route {
        bytes4 selector;
        address receiver;
        address input;
        uint256 amount;
        uint256 destinationChainId;
        uint32 dstEid;
        uint256 nativeFee;
        uint256 lzTokenFee;
        address refundAddress;
        bytes extraOptions;
    }

    function setUp() public {
        vm.chainId(8453);
        signer = vm.addr(signerKey);
        diamond = new MockLifiDiamond();
        uni = new MockToken("UNI");
        usdc = new MockToken("USDC");

        address implementation = address(new BridgePaymaster());
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(implementation, abi.encodeCall(BridgePaymaster.initialize, (deployer))),
            address(PAYMASTER)
        );
        vm.startPrank(deployer);
        PAYMASTER.initializeV2(signer, makeAddr("feeRecipient"), DAILY_BUDGET);
        PAYMASTER.setTarget(address(diamond), BridgePaymaster.TargetKind.LIFI_DIAMOND, 0);
        PAYMASTER.setMaxSponsoredAmount(address(diamond), CAP);
        PAYMASTER.setRoute(address(diamond), FUSE_EID, true);
        vm.stopPrank();
        vm.deal(address(PAYMASTER), 1 ether);

        uni.mint(user, 1_000 ether);
        vm.deal(user, 10 ether);
    }

    // ================================= ENCODING =================================

    function test_selectors_matchLifi() public view {
        assertEq(diamond.swapAndStartBridgeTokensViaStargate.selector, bytes4(0xa6010a66));
        assertEq(diamond.startBridgeTokensViaStargate.selector, bytes4(0x14d53077));
    }

    function test_hashLifiVoucher_matchesStandardTypedData() public view {
        BridgePaymaster.LifiVoucher memory v = BridgePaymaster.LifiVoucher({
            from: 0x1111111111111111111111111111111111111111,
            target: 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE,
            token: 0xc3De830EA07524a0761646a6a4e4be0e114a3C83,
            amount: 10 ether,
            dataHash: 0x2222222222222222222222222222222222222222222222222222222222222222,
            nativeFee: FEE,
            nonce: 81723,
            deadline: 1_900_000_000
        });
        assertEq(ECDSA.recover(PAYMASTER.hashLifiVoucher(v), CAST_SIGNATURE), CAST_SIGNER);
    }

    function test_typehash_matchesSpec() public view {
        assertEq(
            PAYMASTER.LIFI_VOUCHER_TYPEHASH(),
            keccak256(
                "LifiVoucher(address from,address target,address token,uint256 amount,bytes32 dataHash,uint256 nativeFee,uint256 nonce,uint64 deadline)"
            )
        );
    }

    // ================================= HAPPY PATH =================================

    function test_tokenPayer_paysFeeOnTopAndTakesOnlyTheCoin() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        uint256 paymasterBefore = address(PAYMASTER).balance;

        vm.startPrank(user);
        uni.approve(address(PAYMASTER), 10 ether);
        vm.expectEmit(address(PAYMASTER));
        emit LifiCallSponsored(user, address(diamond), v.nonce, address(uni), 10 ether, FEE, bytes32(uint256(0x1f1)));
        bytes32 id = PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();

        assertEq(id, bytes32(uint256(0x1f1)));
        assertEq(uni.balanceOf(user), 990 ether);
        assertEq(uni.balanceOf(address(diamond)), 10 ether);
        assertEq(diamond.lastValue(), FEE);
        assertEq(diamond.lastAllowance(), 10 ether);
        assertEq(paymasterBefore - address(PAYMASTER).balance, FEE);
        assertEq(uni.allowance(address(PAYMASTER), address(diamond)), 0);
        assertEq(PAYMASTER.feeSpentToday(), FEE);
        assertTrue(PAYMASTER.usedNonce(v.nonce));
    }

    function test_nativePayer_forwardsTheirCoinPlusTheFee() public {
        bytes memory data = _encode(_route(address(0), 0.005 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(0), 0.005 ether, data);
        uint256 paymasterBefore = address(PAYMASTER).balance;

        vm.prank(user);
        PAYMASTER.lifiCall{value: 0.005 ether}(v, data, sig);

        assertEq(diamond.lastValue(), 0.005 ether + FEE);
        assertEq(paymasterBefore - address(PAYMASTER).balance, FEE);
        assertEq(user.balance, 10 ether - 0.005 ether);
    }

    function test_bridgeOnly_takesTheBridgedCoin() public {
        Route memory r = _route(address(usdc), 10e6);
        r.selector = 0x14d53077;
        bytes memory data = _encode(r);
        usdc.mint(user, 10e6);
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(usdc), 10e6, data);

        vm.startPrank(user);
        usdc.approve(address(PAYMASTER), 10e6);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(diamond)), 10e6);
        assertEq(diamond.lastValue(), FEE);
    }

    function test_realLifiOptions_pass() public {
        // The compose and receive gas options LI.FI sends carry no native.
        _assertCalls(_route(address(uni), 10 ether));
    }

    // ================================= REFUNDS =================================

    function test_unspentCoinGoesBackToTheCaller() public {
        diamond.configure(1.5 ether, 0, false);
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);

        vm.startPrank(user);
        uni.approve(address(PAYMASTER), 10 ether);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();

        assertEq(uni.balanceOf(user), 990 ether + 1.5 ether);
        assertEq(uni.balanceOf(address(PAYMASTER)), 0);
    }

    function test_refundIgnoresCoinsThePaymasterAlreadyHeld() public {
        // Dust left by an earlier `bridgeSend` is not the caller's.
        uni.mint(address(PAYMASTER), 3 ether);
        diamond.configure(1 ether, 0, false);
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);

        vm.startPrank(user);
        uni.approve(address(PAYMASTER), 10 ether);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();

        assertEq(uni.balanceOf(user), 991 ether);
        assertEq(uni.balanceOf(address(PAYMASTER)), 3 ether);
    }

    function test_nativeBackGoesToTheCallerUpToWhatTheySent() public {
        diamond.configure(0, 0.001 ether, false);
        bytes memory data = _encode(_route(address(0), 0.005 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(0), 0.005 ether, data);
        uint256 paymasterBefore = address(PAYMASTER).balance;

        vm.prank(user);
        PAYMASTER.lifiCall{value: 0.005 ether}(v, data, sig);

        assertEq(user.balance, 10 ether - 0.004 ether);
        assertEq(paymasterBefore - address(PAYMASTER).balance, FEE);
    }

    function test_nativeBackNeverExceedsWhatTheCallerSent() public {
        // More native back than the caller sent: the rest repaid the fee and stays.
        diamond.configure(0, 0.0052 ether, false);
        bytes memory data = _encode(_route(address(0), 0.005 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(0), 0.005 ether, data);
        uint256 paymasterBefore = address(PAYMASTER).balance;

        vm.prank(user);
        PAYMASTER.lifiCall{value: 0.005 ether}(v, data, sig);

        assertEq(user.balance, 10 ether);
        assertEq(address(PAYMASTER).balance, paymasterBefore - FEE + 0.0002 ether);
    }

    function test_feeRefundStaysWithThePaymasterForATokenPayer() public {
        diamond.configure(0, 0.0001 ether, false);
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        uint256 paymasterBefore = address(PAYMASTER).balance;

        vm.startPrank(user);
        uni.approve(address(PAYMASTER), 10 ether);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();

        assertEq(user.balance, 10 ether);
        assertEq(paymasterBefore - address(PAYMASTER).balance, FEE - 0.0001 ether);
    }

    function test_lifiRevertBubblesAndMovesNothing() public {
        diamond.configure(0, 0, true);
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        uint256 paymasterBefore = address(PAYMASTER).balance;

        vm.startPrank(user);
        uni.approve(address(PAYMASTER), 10 ether);
        vm.expectRevert(bytes("LiFi: swap failed"));
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();

        assertEq(uni.balanceOf(user), 1_000 ether);
        assertEq(address(PAYMASTER).balance, paymasterBefore);
        assertFalse(PAYMASTER.usedNonce(v.nonce));
    }

    // ================================= VOUCHER =================================

    function test_rejects_anotherCaller() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.prank(makeAddr("someoneElse"));
        vm.expectRevert(BridgePaymaster.VoucherNotForCaller.selector);
        PAYMASTER.lifiCall(v, data, sig);
    }

    function test_rejects_expiredVoucher() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.warp(v.deadline + 1);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.VoucherExpired.selector);
        PAYMASTER.lifiCall(v, data, sig);
    }

    function test_rejects_reusedVoucher() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.startPrank(user);
        uni.approve(address(PAYMASTER), 20 ether);
        PAYMASTER.lifiCall(v, data, sig);
        vm.expectRevert(BridgePaymaster.VoucherUsed.selector);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();
    }

    function test_rejects_voucherSignedByAnotherKey() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v,) = _voucher(address(uni), 10 ether, data);
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(0xBAD, PAYMASTER.hashLifiVoucher(v));
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InvalidVoucherSignature.selector);
        PAYMASTER.lifiCall(v, data, abi.encodePacked(r, s, sv));
    }

    function test_rejects_raisedFee() public {
        // The caller can't raise the fee the paymaster pays: it is signed.
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        v.nativeFee = FEE * 2;
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InvalidVoucherSignature.selector);
        PAYMASTER.lifiCall(v, data, sig);
    }

    function test_rejects_otherCalldata() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        Route memory other = _route(address(uni), 10 ether);
        other.receiver = makeAddr("attacker");
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.CalldataMismatch.selector);
        PAYMASTER.lifiCall(v, _encode(other), sig);
    }

    function test_rejects_unregisteredTarget() public {
        vm.prank(deployer);
        PAYMASTER.setTarget(address(diamond), BridgePaymaster.TargetKind.NONE, 0);
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.UnsupportedTarget.selector);
        PAYMASTER.lifiCall(v, data, sig);
    }

    // ================================= VALUE =================================

    function test_rejects_valueFromATokenPayer() public {
        bytes memory data = _encode(_route(address(uni), 10 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.ValueMismatch.selector);
        PAYMASTER.lifiCall{value: 1}(v, data, sig);
    }

    function test_rejects_nativePayerSendingTooLittle() public {
        bytes memory data = _encode(_route(address(0), 0.005 ether));
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(0), 0.005 ether, data);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.ValueMismatch.selector);
        PAYMASTER.lifiCall{value: 0.004 ether}(v, data, sig);
    }

    function test_rejects_feeOverTheCap() public {
        Route memory r = _route(address(uni), 10 ether);
        r.nativeFee = CAP + 1;
        _assertRejected(r, CAP + 1, BridgePaymaster.AmountAboveMaximum.selector);
    }

    function test_rejects_feeOverTheDailyBudget() public {
        vm.prank(deployer);
        PAYMASTER.setDailyFeeBudget(FEE - 1);
        _assertRejected(_route(address(uni), 10 ether), FEE, BridgePaymaster.DailyFeeBudgetExceeded.selector);
    }

    function test_rejects_feeOverTheBalance() public {
        vm.deal(address(PAYMASTER), FEE - 1);
        _assertRejected(_route(address(uni), 10 ether), FEE, BridgePaymaster.InsufficientBalance.selector);
    }

    function test_rejects_nativePayerCoveringTheFeeFromTheirOwnValue() public {
        // The paymaster's own balance pays the fee; the caller's coin can't be counted toward it.
        vm.deal(address(PAYMASTER), 0);
        Route memory r = _route(address(0), 0.005 ether);
        bytes memory data = _encode(r);
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(0), 0.005 ether, data);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InsufficientBalance.selector);
        PAYMASTER.lifiCall{value: 0.005 ether}(v, data, sig);
    }

    // ================================= CALLDATA =================================

    function test_rejects_anotherLifiFunction() public {
        Route memory r = _route(address(uni), 10 ether);
        r.selector = 0x12345678;
        _assertRejected(r, FEE, BridgePaymaster.UnsupportedCall.selector);
    }

    function test_rejects_deliveryToSomeoneElse() public {
        Route memory r = _route(address(uni), 10 ether);
        r.receiver = makeAddr("attacker");
        _assertRejected(r, FEE, BridgePaymaster.ReceiverNotCaller.selector);
    }

    function test_rejects_refundToSomeoneElse() public {
        // The 2026-09-02 drain: a refund address of the caller's choosing.
        Route memory r = _route(address(uni), 10 ether);
        r.refundAddress = user;
        _assertRejected(r, FEE, BridgePaymaster.RefundNotToPaymaster.selector);
    }

    function test_rejects_feeOtherThanTheVouchers() public {
        Route memory r = _route(address(uni), 10 ether);
        r.nativeFee = FEE + 1;
        _assertRejected(r, FEE, BridgePaymaster.FeeMismatch.selector);
    }

    function test_rejects_lzTokenFee() public {
        Route memory r = _route(address(uni), 10 ether);
        r.lzTokenFee = 1;
        _assertRejected(r, FEE, BridgePaymaster.FeeMismatch.selector);
    }

    function test_rejects_disallowedDestination() public {
        Route memory r = _route(address(uni), 10 ether);
        r.dstEid = ARBITRUM_EID;
        _assertRejected(r, FEE, BridgePaymaster.RouteNotAllowed.selector);
    }

    function test_rejects_sameChainDestination() public {
        Route memory r = _route(address(uni), 10 ether);
        r.destinationChainId = 8453;
        _assertRejected(r, FEE, BridgePaymaster.RouteNotAllowed.selector);
    }

    function test_rejects_anotherInputCoin() public {
        Route memory r = _route(address(usdc), 10 ether);
        bytes memory data = _encode(r);
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InputMismatch.selector);
        PAYMASTER.lifiCall(v, data, sig);
    }

    function test_rejects_anotherInputAmount() public {
        Route memory r = _route(address(uni), 11 ether);
        bytes memory data = _encode(r);
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(address(uni), 10 ether, data);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InputMismatch.selector);
        PAYMASTER.lifiCall(v, data, sig);
    }

    function test_rejects_nativeDropOption() public {
        // lzNativeDrop: 0.01 ETH to an address of the caller's choosing, priced into our fee.
        Route memory r = _route(address(uni), 10 ether);
        r.extraOptions = abi.encodePacked(
            uint16(3), uint8(1), uint16(49), uint8(2), uint128(0.01 ether), bytes32(uint256(uint160(user)))
        );
        _assertRejected(r, FEE, BridgePaymaster.NativeDropNotAllowed.selector);
    }

    function test_rejects_valueOnReceive() public {
        Route memory r = _route(address(uni), 10 ether);
        r.extraOptions = abi.encodePacked(uint16(3), uint8(1), uint16(33), uint8(1), uint128(200_000), uint128(1));
        _assertRejected(r, FEE, BridgePaymaster.NativeDropNotAllowed.selector);
    }

    function test_rejects_valueOnCompose() public {
        Route memory r = _route(address(uni), 10 ether);
        r.extraOptions =
            abi.encodePacked(uint16(3), uint8(1), uint16(35), uint8(3), uint16(0), uint128(600_000), uint128(1));
        _assertRejected(r, FEE, BridgePaymaster.NativeDropNotAllowed.selector);
    }

    function test_rejects_legacyAirdropOptions() public {
        Route memory r = _route(address(uni), 10 ether);
        r.extraOptions = abi.encodePacked(uint16(2), uint256(200_000), uint256(0.01 ether), user);
        _assertRejected(r, FEE, BridgePaymaster.NativeDropNotAllowed.selector);
    }

    function test_rejects_truncatedOptions() public {
        Route memory r = _route(address(uni), 10 ether);
        r.extraOptions = abi.encodePacked(uint16(3), uint8(1), uint16(40), uint8(1));
        _assertRejected(r, FEE, BridgePaymaster.NativeDropNotAllowed.selector);
    }

    function test_allows_gasOnlyOptions() public {
        Route memory r = _route(address(uni), 10 ether);
        r.extraOptions = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(200_000));
        _assertCalls(r);
        r.extraOptions = abi.encodePacked(uint16(1), uint256(200_000));
        _assertCalls(r);
    }

    // ================================= HELPERS =================================

    function _route(address input, uint256 amount) internal view returns (Route memory) {
        return Route({
            selector: 0xa6010a66,
            receiver: user,
            input: input,
            amount: amount,
            destinationChainId: 122,
            dstEid: FUSE_EID,
            nativeFee: FEE,
            lzTokenFee: 0,
            refundAddress: address(PAYMASTER),
            extraOptions: LIFI_OPTIONS
        });
    }

    function _encode(Route memory r) internal view returns (bytes memory) {
        bool swaps = r.selector != 0x14d53077;
        BridgePaymaster.LifiBridgeData memory bridgeData = BridgePaymaster.LifiBridgeData({
            transactionId: bytes32(uint256(0x1f1)),
            bridge: "stargateV2",
            integrator: "solid",
            referrer: address(0),
            sendingAssetId: swaps ? address(usdc) : r.input,
            receiver: r.receiver,
            minAmount: r.amount,
            destinationChainId: r.destinationChainId,
            hasSourceSwaps: swaps,
            hasDestinationCall: true
        });
        BridgePaymaster.LifiStargateData memory stargateData = BridgePaymaster.LifiStargateData({
            assetId: 1,
            sendParams: SendParam({
                dstEid: r.dstEid,
                to: bytes32(uint256(uint160(lifiReceiverOnFuse))),
                amountLD: r.amount,
                minAmountLD: r.amount * 99 / 100,
                extraOptions: r.extraOptions,
                composeMsg: hex"c0ffee",
                oftCmd: ""
            }),
            fee: MessagingFee(r.nativeFee, r.lzTokenFee),
            refundAddress: r.refundAddress
        });
        if (!swaps) return abi.encodeWithSelector(r.selector, bridgeData, stargateData);
        BridgePaymaster.LifiSwapData[] memory swapData = new BridgePaymaster.LifiSwapData[](1);
        swapData[0] = BridgePaymaster.LifiSwapData({
            callTo: dex,
            approveTo: dex,
            sendingAssetId: r.input,
            receivingAssetId: address(usdc),
            fromAmount: r.amount,
            callData: hex"",
            requiresDeposit: true
        });
        return abi.encodeWithSelector(r.selector, bridgeData, swapData, stargateData);
    }

    function _voucher(address token, uint256 amount, bytes memory data)
        internal
        returns (BridgePaymaster.LifiVoucher memory v, bytes memory sig)
    {
        return _voucherWithFee(token, amount, data, FEE);
    }

    function _voucherWithFee(address token, uint256 amount, bytes memory data, uint256 fee)
        internal
        returns (BridgePaymaster.LifiVoucher memory v, bytes memory sig)
    {
        v = BridgePaymaster.LifiVoucher({
            from: user,
            target: address(diamond),
            token: token,
            amount: amount,
            dataHash: keccak256(data),
            nativeFee: fee,
            nonce: nextNonce++,
            deadline: uint64(block.timestamp + 600)
        });
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(signerKey, PAYMASTER.hashLifiVoucher(v));
        sig = abi.encodePacked(r, s, sv);
    }

    function _assertRejected(Route memory r, uint256 fee, bytes4 error) internal {
        bytes memory data = _encode(r);
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucherWithFee(r.input, r.amount, data, fee);
        vm.startPrank(user);
        uni.approve(address(PAYMASTER), r.amount);
        vm.expectRevert(error);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();
    }

    function _assertCalls(Route memory r) internal {
        bytes memory data = _encode(r);
        (BridgePaymaster.LifiVoucher memory v, bytes memory sig) = _voucher(r.input, r.amount, data);
        vm.startPrank(user);
        uni.approve(address(PAYMASTER), r.amount);
        PAYMASTER.lifiCall(v, data, sig);
        vm.stopPrank();
    }
}
