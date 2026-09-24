// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashStorageV2} from "src/spend-module/v2/SolidCashStorageV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidLiquidator} from "src/spend-module/v2/SolidLiquidator.sol";
import {Mode} from "src/spend-module/v2/SolidCashTypes.sol";

import {V2Fixture} from "./V2Fixture.sol";

/**
 * @notice The audit's highest-severity finding, and each of the four gates that close it.
 *
 * @dev **The attack, as it was.** `bookForcedSpend` books debt with no collateral check, no mode
 *      check and no per-Safe debt cap, because a mandatory card authorization has already happened
 *      off-chain. Liquidation was permissionless. So one compromised `CREDIT_SPENDER_ROLE` key
 *      could: book unbacked debt against any registered Safe, watch its health factor collapse
 *      below `graceFloorHf` — which SKIPS the grace period — and liquidate the position it had just
 *      manufactured, keeping the collateral plus a 5% bonus. Repeat per Safe, using `reverseSpend`
 *      to free the global cap.
 *
 *      Four changes close it, and this suite pins each one separately so a future edit that removes
 *      any single gate fails here rather than silently restoring a route:
 *
 *        1. forced spend honours the Safe's mode          (`test_forcedSpend_refusedOnDebitSafe`)
 *        2. liquidation is whitelisted                    (`test_liquidate_*`)
 *        3. forced debt never takes the grace shortcut    (`test_forcedDebt_*Grace*`)
 *        4. the per-Safe debt cap applies                 (`test_forcedSpend_respectsPerSafeDebtCap`)
 *
 *      The end-to-end case at the bottom is the one that matters most: it runs the whole attack with
 *      BOTH keys compromised and asserts the attacker's balance is unchanged.
 */
contract ForcedSpendExtractionTest is V2Fixture {
    function setUp() public override {
        super.setUp();
        // The attack targets a credit user; the Debit case is its own test below.
        _setMode(Mode.Credit);
    }

    // ===================================== GATE 1: MODE =====================================

    /// @dev A Debit Safe never agreed to carry debt or to have its assets escrowed.
    function test_forcedSpend_refusedOnDebitSafe() external {
        _setMode(Mode.Debit);

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.WrongMode.selector);
        module.bookForcedSpend(address(safe), bytes32("tx1"), 1_000e6, _pref(address(soUSD)));

        assertEq(module.debtUsd(address(safe)), 0, "debt booked against a Debit Safe");
        assertEq(module.collateralOf(address(safe), address(soUSD)), 0, "collateral escrowed from a Debit Safe");
    }

    function test_forcedSpend_allowedOnSmartSafe() external {
        _setMode(Mode.Smart);

        vm.prank(creditSpender);
        module.bookForcedSpend(address(safe), bytes32("tx1"), 1_000e6, _pref(address(soUSD)));

        assertGt(module.debtUsd(address(safe)), 0, "Smart should permit the credit route");
    }

    // ===================================== GATE 4: DEBT CAP =====================================

    function test_forcedSpend_respectsPerSafeDebtCap() external {
        // maxDebtPerSafeUsd is 25_000e6 and maxForcedSpendUsd is the same, so two full-size
        // bookings cross the cap even though each one is individually permitted.
        vm.prank(creditSpender);
        module.bookForcedSpend(address(safe), bytes32("tx1"), 25_000e6, _pref(address(soUSD)));

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.ExceedsSafeDebtCap.selector);
        module.bookForcedSpend(address(safe), bytes32("tx2"), 25_000e6, _pref(address(soUSD)));
    }

    /// @dev The cap is policy, so the per-Safe waiver lifts it — with a delay and an event.
    function test_forcedSpend_debtCapIsWaivable() external {
        vm.prank(creditSpender);
        module.bookForcedSpend(address(safe), bytes32("tx1"), 25_000e6, _pref(address(soUSD)));

        vm.prank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.requestWaiveSafeLimits, (address(safe))));
        skip(1 hours);

        vm.prank(creditSpender);
        module.bookForcedSpend(address(safe), bytes32("tx2"), 25_000e6, _pref(address(soUSD)));
    }

    // ===================================== GATE 3: GRACE =====================================

    /**
     * @dev The exact shortcut the attack relied on. A $25k booking against a Safe holding $100k of
     *      soUSD at a 0.95 threshold lands the health factor far below `graceFloorHf`, which for
     *      ordinary price-driven debt means "real crash, skip the wait". Forced debt must not get
     *      that treatment: nothing about a price moved.
     */
    function test_forcedDebt_cannotSkipGraceViaFloor() external {
        _bookForcedAndStarveCollateral();

        assertLt(module.healthFactor(address(safe)), _params().graceFloorHf, "setup: should be below the floor");

        module.pokeHealth(address(safe));

        vm.prank(liquidationOperator);
        vm.expectRevert(SolidCashStorageV2.LiquidationGraceNotElapsed.selector);
        liquidator.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));
    }

    /// @dev And it becomes liquidatable once the full period has actually elapsed — the gate is a
    ///      delay, not a permanent exemption that would strand bad debt.
    function test_forcedDebt_liquidatableAfterFullGrace() external {
        _bookForcedAndStarveCollateral();
        module.pokeHealth(address(safe));

        skip(GRACE + 1);

        vm.prank(liquidationOperator);
        liquidator.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));
    }

    /// @dev A day is the window the launch decision buys. Pinned so lowering it is a deliberate act.
    function test_gracePeriodIsAtLeastOneDay() external view {
        assertGe(_params().liquidationGracePeriod, 1 days, "grace below the launch decision");
        assertGe(_params().paramChangeDelay, _params().liquidationGracePeriod, "param delay below grace");
    }

    // ===================================== GATE 2: WHITELIST =====================================

    function test_liquidate_refusedForOutsider() external {
        _bookForcedAndStarveCollateral();
        module.pokeHealth(address(safe));
        skip(GRACE + 1);

        vm.prank(outsider);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        module.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));
    }

    /// @dev The key that can create the debt must not be the key that can realise it.
    function test_liquidate_refusedForCreditSpender() external {
        _bookForcedAndStarveCollateral();
        module.pokeHealth(address(safe));
        skip(GRACE + 1);

        vm.prank(creditSpender);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        module.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));

        // Nor through the liquidator contract, which is the other half of the two-key split.
        vm.prank(creditSpender);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        liquidator.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));
    }

    function test_liquidate_permittedForOperatorThroughContract() external {
        _bookForcedAndStarveCollateral();
        module.pokeHealth(address(safe));
        skip(GRACE + 1);

        vm.prank(liquidationOperator);
        liquidator.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));
    }

    // ===================================== THE WHOLE THING =====================================

    /**
     * @notice Both keys compromised, full attack, zero profit.
     * @dev This is the assertion that matters. Even granting the attacker everything the two-key
     *      split is supposed to deny them, the seized collateral and the 5% bonus land in the
     *      treasury, because `SolidLiquidator` has no function that names a destination.
     */
    function test_fullAttack_yieldsNothingToTheAttacker() external {
        address attacker = makeAddr("attacker");
        vm.startPrank(owner);
        authority.setUserRole(attacker, CREDIT_SPENDER_ROLE, true);
        authority.setUserRole(attacker, LIQUIDATION_OPERATOR_ROLE, true);
        vm.stopPrank();

        uint256 attackerSoUsdBefore = soUSD.balanceOf(attacker);
        uint256 treasurySoUsdBefore = soUSD.balanceOf(treasury);
        uint256 safeCollateralBefore = module.collateralOf(address(safe), address(soUSD));

        vm.prank(attacker);
        module.bookForcedSpend(address(safe), bytes32("attack"), 25_000e6, _pref(address(soUSD)));

        module.pokeHealth(address(safe));
        skip(GRACE + 1);

        vm.prank(attacker);
        liquidator.liquidate(address(safe), address(soUSD), 10_000e6, address(soUSD));

        assertEq(soUSD.balanceOf(attacker), attackerSoUsdBefore, "attacker profited from the liquidation");
        assertGt(soUSD.balanceOf(treasury), treasurySoUsdBefore, "seized collateral did not reach the treasury");
        assertLt(
            module.collateralOf(address(safe), address(soUSD)),
            safeCollateralBefore + 25_000e6,
            "sanity: some collateral was seized"
        );
    }

    /// @dev And the liquidator keeps nothing between calls beyond its float.
    function test_liquidator_retainsNoCollateral() external {
        _bookForcedAndStarveCollateral();
        module.pokeHealth(address(safe));
        skip(GRACE + 1);

        uint256 floatBefore = soUSD.balanceOf(address(liquidator));

        vm.prank(liquidationOperator);
        liquidator.liquidate(address(safe), address(soUSD), 1_000e6, address(soUSD));

        // soUSD is both the float and the seized asset here, so the sweep returns both — the
        // conservative direction, and the reason `sweep` is permissionless.
        assertEq(soUSD.balanceOf(address(liquidator)), 0, "liquidator kept value");
        assertGt(floatBefore, 0, "sanity: the float existed");
    }

    function test_liquidator_sweepIsPermissionlessAndGoesToTreasury() external {
        uint256 before = soUSD.balanceOf(treasury);

        vm.prank(outsider);
        liquidator.sweep(address(soUSD));

        assertEq(soUSD.balanceOf(address(liquidator)), 0, "sweep left a balance");
        assertGt(soUSD.balanceOf(treasury), before, "sweep did not reach the treasury");
    }

    // ===================================== HELPERS =====================================

    /**
     * @dev Books unbacked debt and leaves the Safe deeply underwater.
     *
     *      The Safe holds far more than the booking, so a best-effort lock would cover it — which is
     *      correct behaviour and not what this suite is about. Draining the loose balance first is
     *      what produces the genuinely unbacked position the attack needed.
     */
    function _bookForcedAndStarveCollateral() private {
        vm.prank(address(safe));
        soUSD.transfer(outsider, soUSD.balanceOf(address(safe)) - 1_000e6);

        vm.prank(creditSpender);
        module.bookForcedSpend(address(safe), bytes32("forced"), 25_000e6, _pref(address(soUSD)));
    }
}
