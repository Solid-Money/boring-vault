// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {Authority} from "@solmate/auth/Auth.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashStorageV2} from "src/spend-module/v2/SolidCashStorageV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidCashConfigLib} from "src/spend-module/v2/libraries/SolidCashConfigLib.sol";
import {Params, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";

import {V2Fixture} from "./V2Fixture.sol";

/**
 * @notice Findings 2, 5 and 6: the risk classifier's direction, owner-only auth transfer, and the
 *         `graceFloorHf` cap.
 *
 * @dev The classifier tests deliberately derive their expectation from what each field DOES to an
 *      existing borrower rather than from the classifier's own source, because the bug being pinned
 *      was that the classifier and the arithmetic disagreed. A test written from the classifier
 *      would have agreed with the bug.
 */
contract ConfigAndAuthTest is V2Fixture {
    // ================================ CLASSIFIER (finding 2) ================================

    /**
     * @dev Liquidation capacity is `value * liquidationThreshold`. LOWERING it shrinks capacity,
     *      drops every existing borrower's health factor, and can make a currently-healthy position
     *      seizable — so it is the direction that must wait out `paramChangeDelay`.
     */
    function test_classifier_loweringLiquidationThresholdIsRiskIncreasing() external pure {
        TokenConfig memory from = _base();
        TokenConfig memory to = _base();
        to.liquidationThreshold = 0.90e18;

        assertTrue(
            SolidCashConfigLib.isRiskIncreasing(from, to),
            "lowering the threshold must be delayed - it makes positions liquidatable"
        );
    }

    /// @dev Raising it only ever adds headroom to an existing position, so it applies immediately.
    function test_classifier_raisingLiquidationThresholdIsImmediate() external pure {
        TokenConfig memory from = _base();
        TokenConfig memory to = _base();
        to.liquidationThreshold = 0.97e18;

        assertFalse(
            SolidCashConfigLib.isRiskIncreasing(from, to), "raising the threshold only adds headroom"
        );
    }

    /**
     * @dev The behavioural counterpart, through the real setter: a threshold cut must not take
     *      effect in the same transaction. This is the check that would have caught the inverted
     *      comparison even if the pure test above had been written from the buggy source.
     */
    function test_updateToken_thresholdCutIsScheduledNotApplied() external {
        TokenConfig memory cut = _sousdConfig();
        cut.liquidationThreshold = 0.91e18;

        vm.prank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.updateToken, (address(soUSD), cut)));

        TokenConfig memory live =
            SolidCashModuleV2Setters(address(module)).getTokenConfig(address(soUSD));
        assertEq(live.liquidationThreshold, 0.95e18, "threshold cut applied immediately");
    }

    function test_classifier_loweringLtvIsRiskIncreasing() external pure {
        TokenConfig memory from = _base();
        TokenConfig memory to = _base();
        to.ltv = 0.80e18;
        assertTrue(SolidCashConfigLib.isRiskIncreasing(from, to), "a lower LTV can block a withdrawal");
    }

    function test_classifier_raisingBonusIsRiskIncreasing() external pure {
        TokenConfig memory from = _base();
        TokenConfig memory to = _base();
        to.liquidationBonusBps = 1_000;
        assertTrue(SolidCashConfigLib.isRiskIncreasing(from, to), "a bigger bonus costs the borrower more");
    }

    // ================================ GRACE FLOOR (finding 6) ================================

    /**
     * @dev At WAD every unhealthy position is below the floor by definition, so the grace period
     *      would have no band left to apply in — a one-parameter bypass of the same kind the delay
     *      floors exist to close. `setParams` has no delay of its own, which is what made it urgent.
     */
    function test_setParams_rejectsGraceFloorAtWad() external {
        Params memory p = _params();
        p.graceFloorHf = uint64(WAD);

        vm.prank(owner);
        vm.expectRevert(SolidCashConfigLib.InvalidInput.selector);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setParams, (p)));
    }

    function test_setParams_rejectsGraceFloorAboveCap() external {
        Params memory p = _params();
        p.graceFloorHf = SolidCashConfigLib.MAX_GRACE_FLOOR_HF + 1;

        vm.prank(owner);
        vm.expectRevert(SolidCashConfigLib.InvalidInput.selector);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setParams, (p)));
    }

    function test_setParams_acceptsGraceFloorAtCap() external {
        Params memory p = _params();
        p.graceFloorHf = SolidCashConfigLib.MAX_GRACE_FLOOR_HF;

        vm.prank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setParams, (p)));
    }

    // ================================ AUTH (finding 5) ================================

    /**
     * @dev solmate's `transferOwnership` is `requiresAuth`, so the authority could hand it to a
     *      role — and `owner` is the one address `setSettersImpl` answers to. A role with that grant
     *      could therefore take ownership and replace the entire configuration half, and with it the
     *      treatment of every escrowed balance, in the window before `sealSetters`.
     */
    function test_transferOwnership_refusedEvenWithAnExplicitGrant() external {
        vm.prank(owner);
        authority.setRoleCapability(
            CREDIT_SPENDER_ROLE, address(module), bytes4(keccak256("transferOwnership(address)")), true
        );

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.Unauthorized.selector);
        module.transferOwnership(creditSpender);

        assertEq(module.owner(), owner, "ownership moved through the authority");
    }

    function test_setAuthority_refusedEvenWithAnExplicitGrant() external {
        vm.prank(owner);
        authority.setRoleCapability(
            CREDIT_SPENDER_ROLE, address(module), bytes4(keccak256("setAuthority(address)")), true
        );

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.Unauthorized.selector);
        module.setAuthority(Authority(address(0)));

        assertEq(address(module.authority()), address(authority), "authority swapped through itself");
    }

    function test_owner_canStillTransferOwnership() external {
        address next = makeAddr("nextOwner");

        vm.prank(owner);
        module.transferOwnership(next);

        assertEq(module.owner(), next, "owner could not hand over");
    }

    // ================================ HELPERS ================================

    function _base() private pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: true,
            tokenDecimals: 6,
            haircutBps: 0,
            liquidationBonusBps: 500,
            ltv: 0.90e18,
            liquidationThreshold: 0.95e18,
            maxStalenessSeconds: 7 days,
            minPriceUsd: 0.95e6,
            maxPriceUsd: 3e6,
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }
}
