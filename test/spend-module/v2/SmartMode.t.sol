// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {Authority} from "@solmate/auth/Auth.sol";
import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidCashStorageV2} from "src/spend-module/v2/SolidCashStorageV2.sol";
import {Mode, Params, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";

import {MockSafe} from "../mocks/MockSafe.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockPriceProviderV2} from "./mocks/MockPriceProviderV2.sol";

/**
 * @notice Coverage for `Mode.Smart` — the mode that permits BOTH funding paths on one Safe.
 *
 * @dev Organised around the two claims the design rests on, because those are what a reviewer and a
 *      compromised-key scenario actually care about:
 *
 *        1. **Smart is exactly `Debit` union `Credit` at the permission check.** Both paths open,
 *           the exclusive modes still exclusive, and nothing downstream behaves differently.
 *        2. **The properties that make one module safe survive it.** One `SpendingLimit` charged by
 *           both paths, one `booked[safe][txId]` replay marker shared by both, and a debit sale
 *           that cannot move an existing credit position's health.
 *
 *      Plus the switch-timing matrix, which is where the generalised `_modeRank` rule could
 *      silently regress the two pre-existing rows.
 */
contract SmartModeTest is Test {
    uint8 internal constant SPENDER_ROLE = 1;
    uint8 internal constant CREDIT_SPENDER_ROLE = 2;

    uint256 internal constant WAD = 1e18;

    address internal owner = makeAddr("owner");
    address internal spender = makeAddr("spender");
    address internal creditSpender = makeAddr("creditSpender");
    address internal treasury = makeAddr("treasury");
    address internal v1Module = makeAddr("v1Module");

    FuseRolesAuthority internal authority;
    MockPriceProviderV2 internal provider;
    SolidCashModuleV2 internal module;
    MockSafe internal safe;
    MockToken internal soUSD;

    uint64 internal constant MODE_DELAY = 1 days;
    uint256 internal constant MAX_PER_TX = 500e6;
    uint256 internal constant DAILY = 1_000e6;
    uint256 internal constant MONTHLY = 10_000e6;

    function setUp() external {
        // Fixed, mid-month, mid-day anchor so the rolling-window assertions are deterministic.
        vm.warp(1_750_000_000);

        soUSD = new MockToken("Solid USD", "soUSD", 6);

        provider = new MockPriceProviderV2();
        provider.setPrice(address(soUSD), 1e6);

        authority = new FuseRolesAuthority(owner, Authority(address(0)));

        SolidCashModuleV2Setters setters = new SolidCashModuleV2Setters(owner, address(authority), treasury, v1Module);
        module = new SolidCashModuleV2(owner, address(authority), treasury, v1Module, address(provider));

        vm.startPrank(owner);
        module.setSettersImpl(address(setters));

        authority.setRoleCapability(SPENDER_ROLE, address(module), SolidCashModuleV2.spend.selector, true);
        authority.setRoleCapability(CREDIT_SPENDER_ROLE, address(module), SolidCashModuleV2.spendCredit.selector, true);
        authority.setUserRole(spender, SPENDER_ROLE, true);
        authority.setUserRole(creditSpender, CREDIT_SPENDER_ROLE, true);

        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setParams, (_params())));
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.allowToken, (address(soUSD), _tokenConfig())));
        vm.stopPrank();

        safe = new MockSafe();
        safe.enableModule(address(module));
        soUSD.mint(address(safe), 100_000e6);

        vm.prank(address(safe));
        module.registerSafe(0, 0, 0);
    }

    // ========================================= SETUP HELPERS =========================================

    /// @dev Configuration lives behind the core's fallback, so every setter call goes through it.
    function _callSetters(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(module).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _params() internal pure returns (Params memory) {
        return Params({
            maxPerTxUsd: MAX_PER_TX,
            maxDailyLimitUsd: DAILY,
            maxMonthlyLimitUsd: MONTHLY,
            defaultDailyLimitUsd: DAILY,
            defaultMonthlyLimitUsd: MONTHLY,
            maxDebtPerSafeUsd: 50_000e6,
            maxGlobalDebtUsd: 1_000_000e6,
            maxForcedSpendUsd: 1_000e6,
            dustFloorUsd: 0,
            minPositionUsd: 10e6,
            targetLtvBps: 8_000,
            closeFactorBps: 5_000,
            maxAdjustmentBps: 2_000,
            modeDelay: MODE_DELAY,
            limitRaiseDelay: 1 days,
            collateralWithdrawDelay: 1 minutes,
            liquidationGracePeriod: 30 minutes,
            graceFloorHf: 0.95e18,
            paramChangeDelay: 1 days,
            limitWaiveDelay: 1 days
        });
    }

    function _tokenConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: true,
            tokenDecimals: 6,
            haircutBps: 0,
            liquidationBonusBps: 500,
            ltv: 0.9e18,
            liquidationThreshold: 0.94e18,
            maxStalenessSeconds: 7 days,
            minPriceUsd: 0.9e6,
            maxPriceUsd: 3e6,
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }

    function _tokens() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = address(soUSD);
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = amount;
    }

    /// @dev Moves the Safe into `mode`, waiting out the delay when the switch is an up-rank.
    function _setMode(Mode mode) internal {
        vm.prank(address(safe));
        module.setMode(mode);

        if (module.getMode(address(safe)) != mode) {
            vm.warp(block.timestamp + MODE_DELAY);
        }

        assertEq(uint8(module.getMode(address(safe))), uint8(mode), "mode did not take effect");
    }

    function _spend(bytes32 txId, uint256 amountUsd) internal {
        vm.prank(spender);
        module.spend(address(safe), txId, _tokens(), _amounts(amountUsd));
    }

    function _spendCredit(bytes32 txId, uint256 amountUsd) internal {
        vm.prank(creditSpender);
        module.spendCredit(address(safe), txId, amountUsd, _tokens());
    }

    // ========================================= PATH PERMISSION =========================================

    function test_smart_permitsDebit() external {
        _setMode(Mode.Smart);

        _spend(bytes32("tx-1"), 100e6);

        assertEq(soUSD.balanceOf(treasury), 100e6, "debit did not settle to the treasury");
    }

    function test_smart_permitsCredit() external {
        _setMode(Mode.Smart);

        _spendCredit(bytes32("tx-1"), 100e6);

        assertEq(module.debtUsd(address(safe)), 100e6, "credit did not book debt");
        assertGt(module.collateralOf(address(safe), address(soUSD)), 0, "no collateral locked");
    }

    /// @dev Smart must widen, never redirect: nothing may reach anywhere but the two fixed targets.
    function test_smart_creditStillSendsNothingToTreasury() external {
        _setMode(Mode.Smart);

        _spendCredit(bytes32("tx-1"), 100e6);

        assertEq(soUSD.balanceOf(treasury), 0, "credit leaked value to the treasury");
    }

    function test_debitMode_stillRefusesCredit() external {
        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.WrongMode.selector);
        module.spendCredit(address(safe), bytes32("tx-1"), 100e6, _tokens());
    }

    function test_creditMode_stillRefusesDebit() external {
        _setMode(Mode.Credit);

        vm.prank(spender);
        vm.expectRevert(SolidCashStorageV2.WrongMode.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(), _amounts(100e6));
    }

    /// @dev The role map is unchanged: Smart opens paths, it does not make either key universal.
    function test_smart_debitStillRequiresSpenderRole() external {
        _setMode(Mode.Smart);

        vm.prank(creditSpender);
        vm.expectRevert();
        module.spend(address(safe), bytes32("tx-1"), _tokens(), _amounts(100e6));
    }

    function test_smart_creditStillRequiresCreditSpenderRole() external {
        _setMode(Mode.Smart);

        vm.prank(spender);
        vm.expectRevert();
        module.spendCredit(address(safe), bytes32("tx-1"), 100e6, _tokens());
    }

    // ========================================= SHARED STATE =========================================

    /**
     * @dev The invariant the module's header cites as the reason there is one module and not two.
     *      Two independent cap sets would let one user consume two daily limits in a day, and Smart
     *      is the mode where that would actually be reachable.
     */
    function test_smart_bothPathsChargeOneDailyLimit() external {
        _setMode(Mode.Smart);

        _spend(bytes32("tx-1"), 400e6);
        _spendCredit(bytes32("tx-2"), 400e6);

        // 1,000 daily cap, 800 consumed across the two paths.
        assertEq(module.maxCanSpendUsd(address(safe)), 200e6, "paths did not share one window");

        vm.prank(spender);
        vm.expectRevert(SolidCashStorageV2.ExceedsAvailableLimit.selector);
        module.spend(address(safe), bytes32("tx-3"), _tokens(), _amounts(300e6));
    }

    /// @dev Replay protection is correctness, not policy, and must not be escapable by switching path.
    function test_smart_txIdCannotBeBookedOnBothPaths() external {
        _setMode(Mode.Smart);

        _spend(bytes32("tx-1"), 100e6);

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.TransactionAlreadyBooked.selector);
        module.spendCredit(address(safe), bytes32("tx-1"), 100e6, _tokens());
    }

    function test_smart_txIdCannotBeBookedOnBothPaths_creditFirst() external {
        _setMode(Mode.Smart);

        _spendCredit(bytes32("tx-1"), 100e6);

        vm.prank(spender);
        vm.expectRevert(SolidCashStorageV2.TransactionAlreadyBooked.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(), _amounts(100e6));
    }

    /**
     * @dev The question every reviewer asks first about Smart: can a debit sale strand a credit
     *      position? It cannot. `_positionValue` reads module escrow while `_settleDebitToken`
     *      moves the Safe's OWN balance, so the two never touch the same tokens. Selling reduces
     *      future borrowing power — an availability effect — and leaves health exactly where it was.
     */
    function test_smart_debitDoesNotMoveHealthOfAnExistingPosition() external {
        _setMode(Mode.Smart);

        _spendCredit(bytes32("tx-1"), 200e6);

        uint256 hfBefore = module.healthFactor(address(safe));
        uint256 escrowBefore = module.collateralOf(address(safe), address(soUSD));

        _spend(bytes32("tx-2"), 300e6);

        assertEq(module.healthFactor(address(safe)), hfBefore, "debit moved the health factor");
        assertEq(module.collateralOf(address(safe), address(soUSD)), escrowBefore, "debit reached into escrow");
    }

    // ========================================= SWITCH TIMING =========================================

    /// @dev Pre-existing row. A regression here breaks the shipped Credit rollout, not just Smart.
    function test_switch_debitToCredit_isDelayed() external {
        vm.prank(address(safe));
        module.setMode(Mode.Credit);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "up-rank applied early");

        vm.warp(block.timestamp + MODE_DELAY);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Credit));
    }

    /// @dev Pre-existing row.
    function test_switch_creditToDebit_isImmediate() external {
        _setMode(Mode.Credit);

        vm.prank(address(safe));
        module.setMode(Mode.Debit);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "down-rank was delayed");
    }

    function test_switch_debitToSmart_isDelayed() external {
        vm.prank(address(safe));
        module.setMode(Mode.Smart);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "up-rank applied early");

        vm.warp(block.timestamp + MODE_DELAY);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Smart));
    }

    function test_switch_creditToSmart_isDelayed() external {
        _setMode(Mode.Credit);

        vm.prank(address(safe));
        module.setMode(Mode.Smart);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Credit), "up-rank applied early");

        vm.warp(block.timestamp + MODE_DELAY);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Smart));
    }

    function test_switch_smartToDebit_isImmediate() external {
        _setMode(Mode.Smart);

        vm.prank(address(safe));
        module.setMode(Mode.Debit);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "down-rank was delayed");
    }

    function test_switch_smartToCredit_isImmediate() external {
        _setMode(Mode.Smart);

        vm.prank(address(safe));
        module.setMode(Mode.Credit);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Credit), "down-rank was delayed");
    }

    /// @dev Leaving Smart must close the path it opened, immediately and in both directions.
    function test_switch_smartToDebit_closesTheCreditPath() external {
        _setMode(Mode.Smart);

        vm.prank(address(safe));
        module.setMode(Mode.Debit);

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.WrongMode.selector);
        module.spendCredit(address(safe), bytes32("tx-1"), 100e6, _tokens());
    }

    function test_switch_smartToCredit_closesTheDebitPath() external {
        _setMode(Mode.Smart);

        vm.prank(address(safe));
        module.setMode(Mode.Credit);

        vm.prank(spender);
        vm.expectRevert(SolidCashStorageV2.WrongMode.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(), _amounts(100e6));
    }

    // ========================================= ARM / CANCEL / RE-ARM =========================================

    /// @dev The documented cancellation window: call `setMode` with the mode you are already in.
    function test_arm_cancelSmartSwitch() external {
        vm.prank(address(safe));
        module.setMode(Mode.Smart);
        assertGt(module.incomingModeStartTime(address(safe)), 0, "switch was not armed");

        vm.prank(address(safe));
        module.setMode(Mode.Debit);

        assertEq(module.incomingModeStartTime(address(safe)), 0, "cancel did not disarm");

        vm.warp(block.timestamp + MODE_DELAY * 2);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "cancelled switch matured");
    }

    /**
     * @dev Re-arming onto a different higher-ranked mode must restart the clock rather than inherit
     *      the elapsed part of the one it replaces — otherwise an armed switch could be converted
     *      into a different, wider one that matures early.
     */
    function test_arm_reArmOntoDifferentModeRestartsTheDelay() external {
        vm.prank(address(safe));
        module.setMode(Mode.Smart);

        vm.warp(block.timestamp + MODE_DELAY - 1);

        vm.prank(address(safe));
        module.setMode(Mode.Credit);

        // The original Smart switch would have matured one second from here.
        vm.warp(block.timestamp + 1);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "re-arm inherited the old clock");

        vm.warp(block.timestamp + MODE_DELAY);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Credit));
    }

    /// @dev A down-rank while armed both applies and disarms, leaving nothing pending.
    function test_arm_downRankWhileArmedDisarms() external {
        _setMode(Mode.Credit);

        vm.prank(address(safe));
        module.setMode(Mode.Smart);
        assertGt(module.incomingModeStartTime(address(safe)), 0, "switch was not armed");

        vm.prank(address(safe));
        module.setMode(Mode.Debit);

        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit));
        assertEq(module.incomingModeStartTime(address(safe)), 0, "armed switch survived a down-rank");

        vm.warp(block.timestamp + MODE_DELAY * 2);
        assertEq(uint8(module.getMode(address(safe))), uint8(Mode.Debit), "armed Smart matured anyway");
    }

    function test_setMode_rejectsTheModeAlreadyActive() external {
        vm.prank(address(safe));
        vm.expectRevert(SolidCashStorageV2.InvalidInput.selector);
        module.setMode(Mode.Debit);
    }

    // ========================================= REGISTRATION =========================================

    /// @dev Registration is always into `Debit`; Smart costs one delay, the same as Credit does.
    function test_registration_startsInDebit() external {
        MockSafe fresh = new MockSafe();
        fresh.enableModule(address(module));

        vm.prank(address(fresh));
        module.registerSafe(0, 0, 0);

        assertEq(uint8(module.getMode(address(fresh))), uint8(Mode.Debit));
    }
}
