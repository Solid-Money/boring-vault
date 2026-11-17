// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

contract MockCoin is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Stands in for a BoringVault: `enter` pulls the deposit against its owner's approval of the
///      vault, as the real one does, and mints shares 1:1.
contract MockVault is MockCoin {
    constructor() MockCoin("soUSD") {}

    function enter(address from, address asset, uint256 amount, address to, uint256 shares) external {
        require(IERC20(asset).transferFrom(from, address(this), amount), "Vault: pull");
        _mint(to, shares);
    }
}

/**
 * @dev Stands in for a CrossChainTellerWithGenericBridge on Fuse: quotes a fixed native fee, and
 *      bridges by burning the shares from its caller, as the teller's `exit` does. `depositAndBridge`
 *      deposits for its caller first. `shortfall` makes the vault pull less than the deposit, so a
 *      test can see whether the caller's approval of the vault outlives the call.
 */
contract MockTeller {
    address internal constant NATIVE_FEE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    MockVault public immutable vault;
    uint256 public immutable fee;
    uint256 public shortfall;

    uint256 public lastValue;
    uint256 public lastMaxFee;
    address public lastFeeToken;
    address public lastTo;
    uint256 public lastShares;
    bytes public lastWildCard;
    uint256 public lastAllowance;

    constructor(MockVault _vault, uint256 _fee) {
        vault = _vault;
        fee = _fee;
    }

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    function previewFee(uint96, address, bytes calldata, address) external view returns (uint256) {
        return fee;
    }

    function bridge(uint96 shareAmount, address to, bytes calldata bridgeWildCard, address feeToken, uint256 maxFee)
        external
        payable
    {
        _charge(feeToken, maxFee);
        vault.burn(msg.sender, shareAmount);
        _record(to, shareAmount, bridgeWildCard);
    }

    function depositAndBridge(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata bridgeWildCard,
        address feeToken,
        uint256 maxFee
    ) external payable returns (uint256 sharesBridged) {
        _charge(feeToken, maxFee);
        lastAllowance = IERC20(depositAsset).allowance(msg.sender, address(vault));
        sharesBridged = depositAmount - shortfall;
        require(sharesBridged >= minimumMint, "Teller: minimumMint");
        vault.enter(msg.sender, depositAsset, sharesBridged, msg.sender, sharesBridged);
        vault.burn(msg.sender, sharesBridged);
        _record(to, sharesBridged, bridgeWildCard);
    }

    function _charge(address feeToken, uint256 maxFee) internal {
        require(feeToken == NATIVE_FEE_TOKEN, "Teller: fee token");
        require(fee <= maxFee, "Teller: fee above max");
        lastValue = msg.value;
        lastMaxFee = maxFee;
        lastFeeToken = feeToken;
    }

    function _record(address to, uint256 shares, bytes calldata bridgeWildCard) internal {
        lastTo = to;
        lastShares = shares;
        lastWildCard = bridgeWildCard;
    }
}

/// @dev Stands in for a Stargate OFT: only the fee quote the paymaster reads.
contract MockQuoteOFT {
    uint256 public immutable fee;

    constructor(uint256 _fee) {
        fee = _fee;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee(fee, 0);
    }
}

/// @dev Stands in for FastWithdrawManager: pulls the shares from `from` against its approval of the
///      manager, and records what the paymaster passed.
contract MockFastWithdrawManager {
    MockVault public immutable shares;
    mapping(address => bool) public isAllowedOFT;

    uint256 public lastValue;
    uint256 public lastFee;
    address public lastFrom;
    address public lastRefundAddress;
    uint256 public lastAmountIn;
    uint32 public lastDstEid;

    constructor(MockVault _shares) {
        shares = _shares;
    }

    function allowOFT(address oft) external {
        isAllowedOFT[oft] = true;
    }

    function swapAndWithdrawUsingStargate(
        address oft,
        address from,
        uint256 amountIn,
        SendParam calldata sendParam,
        uint256 fee,
        address refundAddress
    ) external payable returns (bytes memory, uint256, uint256, uint256) {
        require(isAllowedOFT[oft], "Manager: OFT");
        require(shares.transferFrom(from, address(this), amountIn), "Manager: pull");
        lastValue = msg.value;
        lastFee = fee;
        lastFrom = from;
        lastRefundAddress = refundAddress;
        lastAmountIn = amountIn;
        lastDstEid = sendParam.dstEid;
        return ("", amountIn, amountIn, 0);
    }
}

/**
 * @notice Unit tests of the teller and fast-withdraw entrypoints - `sponsorBridge`,
 *         `sponsorDepositAndBridge` and `sponsorFastWithdraw` - against stand-ins: the fee each
 *         forwards, what it costs the paymaster, the approval `sponsorDepositAndBridge` leaves, and
 *         the floors. The Stargate-facing checks shared with the card entrypoints are fork-tested in
 *         BridgePaymasterBridgeSend.t.sol.
 *
 * Run with: forge test --match-path test/fuse/BridgePaymasterSponsor.t.sol
 */
contract BridgePaymasterSponsorTest is Test {
    address internal constant NATIVE_FEE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint32 internal constant ETHEREUM = 30101;

    /// @dev About what a LayerZero send from Fuse costs, in FUSE.
    uint256 internal constant FEE = 36 ether;
    uint256 internal constant MIN = 5e6;
    uint256 internal constant AMOUNT = 40e6;

    BridgePaymaster internal pm;
    address internal deployer = makeAddr("deployer");
    address internal user = makeAddr("userSafe");
    address internal recipient = makeAddr("recipientOnEthereum");
    bytes internal wildCard = abi.encode(ETHEREUM);

    MockVault internal vault;
    MockCoin internal usdc;
    MockTeller internal teller;
    MockQuoteOFT internal oft;
    MockFastWithdrawManager internal manager;

    event FeeSponsored(address indexed target, address indexed caller, uint256 fee);

    function setUp() public {
        vault = new MockVault();
        usdc = new MockCoin("USDC");
        teller = new MockTeller(vault, FEE);
        oft = new MockQuoteOFT(FEE);
        manager = new MockFastWithdrawManager(vault);
        manager.allowOFT(address(oft));

        pm = BridgePaymaster(
            payable(
                address(
                    new ERC1967Proxy(address(new BridgePaymaster()), abi.encodeCall(BridgePaymaster.initialize, (deployer)))
                )
            )
        );
        vm.startPrank(deployer);
        pm.setTarget(address(teller), BridgePaymaster.TargetKind.TELLER, MIN);
        pm.setTarget(address(manager), BridgePaymaster.TargetKind.FAST_WITHDRAW_MANAGER, MIN);
        vm.stopPrank();
        vm.deal(address(pm), 1_000 ether);

        vault.mint(user, 100e6);
        usdc.mint(user, 100e6);
    }

    // ===================================== sponsorBridge =====================================

    function test_sponsorBridge_paysTheQuotedFeeAndBridgesTheCallersShares() public {
        uint256 paymasterBefore = address(pm).balance;

        vm.startPrank(user);
        vault.approve(address(pm), AMOUNT);
        vm.expectEmit(address(pm));
        emit FeeSponsored(address(teller), user, FEE);
        uint256 fee = pm.sponsorBridge(address(teller), uint96(AMOUNT), recipient, wildCard);
        vm.stopPrank();

        assertEq(fee, FEE);
        assertEq(teller.lastValue(), FEE);
        assertEq(teller.lastMaxFee(), FEE);
        assertEq(teller.lastFeeToken(), NATIVE_FEE_TOKEN);
        assertEq(teller.lastTo(), recipient);
        assertEq(teller.lastShares(), AMOUNT);
        assertEq(teller.lastWildCard(), wildCard);
        assertEq(vault.balanceOf(user), 100e6 - AMOUNT);
        assertEq(vault.balanceOf(address(pm)), 0);
        assertEq(vault.totalSupply(), 100e6 - AMOUNT);
        assertEq(paymasterBefore - address(pm).balance, FEE);
        assertEq(user.balance, 0);
    }

    function test_sponsorBridge_rejectsBelowMinimum() public {
        vm.startPrank(user);
        vault.approve(address(pm), MIN - 1);
        vm.expectRevert(BridgePaymaster.AmountBelowMinimum.selector);
        pm.sponsorBridge(address(teller), uint96(MIN - 1), recipient, wildCard);
        vm.stopPrank();
    }

    function test_sponsorBridge_rejectsFeeOverTheBalance() public {
        vm.deal(address(pm), FEE - 1);
        vm.startPrank(user);
        vault.approve(address(pm), AMOUNT);
        vm.expectRevert(BridgePaymaster.InsufficientBalance.selector);
        pm.sponsorBridge(address(teller), uint96(AMOUNT), recipient, wildCard);
        vm.stopPrank();
    }

    function test_sponsorBridge_rejectsAManagerAsTeller() public {
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.UnsupportedTarget.selector);
        pm.sponsorBridge(address(manager), uint96(AMOUNT), recipient, wildCard);
    }

    // ================================ sponsorDepositAndBridge ================================

    function test_sponsorDepositAndBridge_paysTheQuotedFeeAndBridgesTheDeposit() public {
        uint256 paymasterBefore = address(pm).balance;

        vm.startPrank(user);
        usdc.approve(address(pm), AMOUNT);
        vm.expectEmit(address(pm));
        emit FeeSponsored(address(teller), user, FEE);
        uint256 fee = pm.sponsorDepositAndBridge(address(teller), address(usdc), AMOUNT, AMOUNT, recipient, wildCard);
        vm.stopPrank();

        assertEq(fee, FEE);
        assertEq(teller.lastValue(), FEE);
        assertEq(teller.lastMaxFee(), FEE);
        assertEq(teller.lastFeeToken(), NATIVE_FEE_TOKEN);
        assertEq(teller.lastTo(), recipient);
        assertEq(teller.lastShares(), AMOUNT);
        assertEq(teller.lastAllowance(), AMOUNT);
        assertEq(usdc.balanceOf(user), 100e6 - AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), AMOUNT);
        assertEq(usdc.balanceOf(address(pm)), 0);
        assertEq(vault.balanceOf(address(pm)), 0);
        assertEq(paymasterBefore - address(pm).balance, FEE);
    }

    function test_sponsorDepositAndBridge_resetsTheVaultApprovalWhenItPullsLess() public {
        // The vault takes 1 USDC less than approved; without the reset it could take it later.
        teller.setShortfall(1e6);

        vm.startPrank(user);
        usdc.approve(address(pm), AMOUNT);
        pm.sponsorDepositAndBridge(address(teller), address(usdc), AMOUNT, AMOUNT - 1e6, recipient, wildCard);
        vm.stopPrank();

        assertEq(teller.lastAllowance(), AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), AMOUNT - 1e6);
        assertEq(usdc.allowance(address(pm), address(vault)), 0);
    }

    function test_sponsorDepositAndBridge_rejectsBelowMinimum() public {
        vm.startPrank(user);
        usdc.approve(address(pm), MIN - 1);
        vm.expectRevert(BridgePaymaster.AmountBelowMinimum.selector);
        pm.sponsorDepositAndBridge(address(teller), address(usdc), MIN - 1, 0, recipient, wildCard);
        vm.stopPrank();
    }

    function test_sponsorDepositAndBridge_rejectsFeeOverTheBalance() public {
        vm.deal(address(pm), FEE - 1);
        vm.startPrank(user);
        usdc.approve(address(pm), AMOUNT);
        vm.expectRevert(BridgePaymaster.InsufficientBalance.selector);
        pm.sponsorDepositAndBridge(address(teller), address(usdc), AMOUNT, AMOUNT, recipient, wildCard);
        vm.stopPrank();
    }

    // ================================== sponsorFastWithdraw ==================================

    function test_sponsorFastWithdraw_paysTheQuotedFeeAndRefundsToThePaymaster() public {
        uint256 paymasterBefore = address(pm).balance;

        vm.startPrank(user);
        vault.approve(address(manager), AMOUNT);
        vm.expectEmit(address(pm));
        emit FeeSponsored(address(manager), user, FEE);
        uint256 fee = pm.sponsorFastWithdraw(address(manager), address(oft), AMOUNT, _sendParam(""));
        vm.stopPrank();

        assertEq(fee, FEE);
        assertEq(manager.lastValue(), FEE);
        assertEq(manager.lastFee(), FEE);
        assertEq(manager.lastFrom(), user);
        assertEq(manager.lastRefundAddress(), address(pm));
        assertEq(manager.lastAmountIn(), AMOUNT);
        assertEq(manager.lastDstEid(), ETHEREUM);
        assertEq(vault.balanceOf(address(manager)), AMOUNT);
        assertEq(vault.balanceOf(user), 100e6 - AMOUNT);
        assertEq(paymasterBefore - address(pm).balance, FEE);
    }

    function test_sponsorFastWithdraw_rejectsBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.AmountBelowMinimum.selector);
        pm.sponsorFastWithdraw(address(manager), address(oft), MIN - 1, _sendParam(""));
    }

    function test_sponsorFastWithdraw_rejectsAnOFTTheManagerRefuses() public {
        MockQuoteOFT other = new MockQuoteOFT(FEE);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.OFTNotAllowed.selector);
        pm.sponsorFastWithdraw(address(manager), address(other), AMOUNT, _sendParam(""));
    }

    function test_sponsorFastWithdraw_rejectsNativeDrop() public {
        // lzNativeDrop of 0.01 ETH: priced into the fee the paymaster would pay.
        bytes memory drop = abi.encodePacked(
            uint16(3), uint8(1), uint16(49), uint8(2), uint128(0.01 ether), bytes32(uint256(uint160(user)))
        );
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.OptionsNotAllowed.selector);
        pm.sponsorFastWithdraw(address(manager), address(oft), AMOUNT, _sendParam(drop));
    }

    function test_sponsorFastWithdraw_rejectsFeeOverTheBalance() public {
        vm.deal(address(pm), FEE - 1);
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.InsufficientBalance.selector);
        pm.sponsorFastWithdraw(address(manager), address(oft), AMOUNT, _sendParam(""));
    }

    function test_sponsorFastWithdraw_rejectsATellerAsManager() public {
        vm.prank(user);
        vm.expectRevert(BridgePaymaster.UnsupportedTarget.selector);
        pm.sponsorFastWithdraw(address(teller), address(oft), AMOUNT, _sendParam(""));
    }

    // ======================================== HELPERS ========================================

    function _sendParam(bytes memory extraOptions) internal view returns (SendParam memory) {
        return SendParam({
            dstEid: ETHEREUM,
            to: bytes32(uint256(uint160(recipient))),
            amountLD: AMOUNT,
            minAmountLD: AMOUNT * 99 / 100,
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });
    }
}
