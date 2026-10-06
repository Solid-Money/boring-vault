// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashStorageV2} from "src/spend-module/v2/SolidCashStorageV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {Mode} from "src/spend-module/v2/SolidCashTypes.sol";

import {V2Fixture} from "./V2Fixture.sol";

/**
 * @notice Findings 3, 4 and 7: repay tender, the health stamp under a feed outage, and the pause
 *         gate on adjustment increases.
 */
contract TenderAndHealthTest is V2Fixture {
    function setUp() public override {
        super.setUp();
        _setMode(Mode.Credit);

        vm.prank(creditSpender);
        module.spendCredit(address(safe), bytes32("open"), 10_000e6, _pref(address(soUSD)));
    }

    // ===================================== TENDER (finding 3) =====================================

    /**
     * @dev USDT is spendable but its price here is a bare peg with nothing observing it. Accepting
     *      it as tender would let a borrower retire a dollar of debt with a token that has stopped
     *      being worth a dollar — the one use of a bare peg the provider's design never argued for.
     */
    function test_repay_refusesNonTenderToken() external {
        usdt.mint(outsider, 1_000e6);
        vm.startPrank(outsider);
        usdt.approve(address(module), type(uint256).max);
        vm.expectRevert(SolidCashStorageV2.TokenNotTender.selector);
        SolidCashModuleV2Setters(address(module)).repay(address(safe), address(usdt), 1_000e6);
        vm.stopPrank();
    }

    function test_repay_acceptsTenderToken() external {
        soUSD.mint(outsider, 1_000e6);
        uint256 debtBefore = module.debtUsd(address(safe));

        vm.startPrank(outsider);
        soUSD.approve(address(module), type(uint256).max);
        SolidCashModuleV2Setters(address(module)).repay(address(safe), address(soUSD), 1_000e6);
        vm.stopPrank();

        assertLt(module.debtUsd(address(safe)), debtBefore, "tender repay did not reduce debt");
    }

    function test_repayFromSafe_refusesNonTenderToken() external {
        vm.prank(address(safe));
        vm.expectRevert(SolidCashStorageV2.TokenNotTender.selector);
        SolidCashModuleV2Setters(address(module)).repayFromSafe(address(safe), address(usdt), 1_000e6);
    }

    /**
     * @dev Deliberately exempt. It spends the borrower's OWN escrowed balance and prices it as
     *      collateral rather than accepting it as payment, so gating it would trap the position it
     *      exists to rescue.
     */
    function test_repayFromCollateral_exemptFromTender() external {
        vm.prank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setRepayTender, (address(soUSD), false)));

        uint256 debtBefore = module.debtUsd(address(safe));

        vm.prank(address(safe));
        SolidCashModuleV2Setters(address(module)).repayFromCollateral(address(safe), address(soUSD), 1_000e6);

        assertLt(module.debtUsd(address(safe)), debtBefore, "deleverage blocked by the tender list");
    }

    function test_disallowToken_clearsTenderBit() external {
        // usdt carries no escrow, so it can be removed.
        vm.startPrank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setRepayTender, (address(usdt), true)));
        assertTrue(module.repayTender(address(usdt)), "setup: tender not set");

        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.disallowToken, (address(usdt))));
        vm.stopPrank();

        assertFalse(module.repayTender(address(usdt)), "stale tender bit survived disallowToken");
    }

    function test_setRepayTender_requiresAllowlistedToken() external {
        address stranger = makeAddr("strangerToken");
        vm.prank(owner);
        vm.expectRevert(SolidCashStorageV2.TokenNotAllowed.selector);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setRepayTender, (stranger, true)));
    }

    // ================================ HEALTH STAMP (finding 4) ================================

    /**
     * @dev The outage case. `_positionValue` drops an unpriceable token from capacity, so during a
     *      feed outage every credit position reads at health 0. Stamping from that reading is not an
     *      observation that the position went bad — it is an observation that the oracle went down —
     *      and it would burn the grace clock while nothing could be liquidated anyway, leaving every
     *      marginal position instantly seizable the moment the feed returned.
     */
    function test_pokeHealth_doesNotStampWhileUnpriced() external {
        provider.setUsable(address(soUSD), false);

        assertEq(module.healthFactor(address(safe)), 0, "setup: should read as zero while unpriced");

        module.pokeHealth(address(safe));

        assertEq(module.unhealthySince(address(safe)), 0, "stamped a position it could not price");
    }

    /**
     * @dev And the clock starts from recovery, not from the outage.
     *
     *      Unhealthiness is produced with unbacked forced debt rather than with a low price,
     *      because soUSD's `minPriceUsd` floor (0.95) is above the price that would actually put
     *      this position under water — below the floor the feed reads as unusable, not as cheap.
     */
    function test_pokeHealth_stampsAfterFeedRecovers() external {
        _makeGenuinelyUnhealthy();

        provider.setUsable(address(soUSD), false);
        module.pokeHealth(address(safe));
        assertEq(module.unhealthySince(address(safe)), 0, "stamped during the outage");

        skip(GRACE + 1);
        provider.setUsable(address(soUSD), true);

        module.pokeHealth(address(safe));

        assertEq(module.unhealthySince(address(safe)), block.timestamp, "clock did not start from recovery");
    }

    /// @dev Clearing stays unconditional: a user must never be left stamped because a feed they do
    ///      not control is down, and a position that recovers must always be releasable.
    function test_pokeHealth_clearsStampOnRecovery() external {
        _makeGenuinelyUnhealthy();
        module.pokeHealth(address(safe));
        assertGt(module.unhealthySince(address(safe)), 0, "setup: expected a stamp");

        // Repay the whole position from the caller's own tender.
        uint256 debt = module.debtUsd(address(safe));
        soUSD.mint(outsider, debt);
        vm.startPrank(outsider);
        soUSD.approve(address(module), type(uint256).max);
        SolidCashModuleV2Setters(address(module)).repay(address(safe), address(soUSD), debt);
        vm.stopPrank();

        module.pokeHealth(address(safe));

        assertEq(module.unhealthySince(address(safe)), 0, "recovered position stayed stamped");
    }

    // ============================== ADJUSTMENT PAUSE (finding 7) ==============================

    function test_adjustBookedSpend_increaseHonoursPause() external {
        vm.prank(guardian);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.pause, ()));

        vm.prank(creditSpender);
        vm.expectRevert(SolidCashStorageV2.Paused.selector);
        module.adjustBookedSpend(address(safe), bytes32("open"), 11_000e6, _pref(address(soUSD)));
    }

    /// @dev Decreases stay open while paused, like every other unwind.
    function test_adjustBookedSpend_decreaseWorksWhilePaused() external {
        vm.prank(guardian);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.pause, ()));

        uint256 debtBefore = module.debtUsd(address(safe));

        vm.prank(creditSpender);
        module.adjustBookedSpend(address(safe), bytes32("open"), 9_000e6, _pref(address(soUSD)));

        assertLt(module.debtUsd(address(safe)), debtBefore, "de-risking blocked by the pause");
    }

    // ===================================== HELPERS =====================================

    /**
     * @dev Produces a position that is under water on its own terms, not because a price is low.
     *
     *      `bookForcedSpend` is the only path that adds debt without requiring collateral behind
     *      it, which is exactly what is needed here: soUSD's price band floor sits above the price
     *      that would otherwise put this position under, so a price-driven setup would read as an
     *      unusable feed rather than as a cheap asset.
     */
    function _makeGenuinelyUnhealthy() private {
        vm.prank(address(safe));
        soUSD.transfer(outsider, soUSD.balanceOf(address(safe)));

        // 10k on top of setUp's 10k credit spend: total debt 20k against ~11.1k of capacity, so
        // the position is genuinely under water while staying inside `maxDebtPerSafeUsd` (25k),
        // which `bookForcedSpend` now enforces.
        vm.prank(creditSpender);
        module.bookForcedSpend(address(safe), bytes32("forced"), 10_000e6, _pref(address(soUSD)));

        assertLt(module.healthFactor(address(safe)), WAD, "setup: position should be under water");
    }
}
