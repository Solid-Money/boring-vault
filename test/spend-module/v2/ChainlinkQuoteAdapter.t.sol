// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {Authority} from "@solmate/auth/Auth.sol";

import {ChainlinkQuoteAdapter} from "src/spend-module/v2/adapters/ChainlinkQuoteAdapter.sol";

import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/**
 * @notice Coverage for the first implementation of `IPriceAdapter`.
 *
 * @dev Organised around the three promises the adapter makes, because those are what the provider
 *      and the whole authorize path depend on:
 *
 *        1. **It never reverts.** Every failure mode collapses to `(0, false, 0)`. A revert here
 *           would propagate through `priceUsdDetailed` into `_positionValue`, which walks every
 *           allowlisted token, and decline every card transaction for every user over one asset.
 *        2. **The composition and decimal normalisation are right.** A price that is wrong by a
 *           factor of ten is worse than no price, and the numerator/denominator form is exactly
 *           where an off-by-a-decimal hides.
 *        3. **It refuses to price while the L2 sequencer is down or inside its grace period.**
 *           This is the property a staleness bound alone cannot provide.
 */
contract ChainlinkQuoteAdapterTest is Test {
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal eurc = makeAddr("EURC");
    address internal usdc = makeAddr("USDC");
    address internal weth = makeAddr("WETH");

    uint64 internal constant GRACE = 1 hours;
    uint64 internal constant STALENESS = 24 hours;

    ChainlinkQuoteAdapter internal adapter;
    MockAggregatorV3 internal sequencer;
    MockAggregatorV3 internal eurUsd;
    MockAggregatorV3 internal eurcUsd;
    MockAggregatorV3 internal ethUsd;

    function setUp() public {
        vm.warp(1_750_000_000);

        // Sequencer up (0), and up since well before the grace period.
        sequencer = new MockAggregatorV3(0, 0);
        sequencer.setStartedAt(block.timestamp - 10 days);

        // Chainlink USD pairs are 8 decimals.
        eurUsd = new MockAggregatorV3(8, 1.08e8);
        eurcUsd = new MockAggregatorV3(8, 1.0795e8);
        ethUsd = new MockAggregatorV3(8, 3000e8);

        adapter = new ChainlinkQuoteAdapter(owner, address(sequencer), GRACE);
    }

    // ===================================== COMPOSITION =====================================

    /// @dev A dollar instance prices EURC straight off one feed: no denominator at all.
    function test_price_directFeed_normalisesDecimals() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        (uint256 price, bool usable,) = adapter.price(eurc);

        assertTrue(usable, "direct feed should be usable");
        // 1.0795 at 8 decimals becomes 1.0795 at 6.
        assertEq(price, 1.0795e6, "decimal normalisation is wrong");
    }

    /// @dev The euro-book shape, kept covered because the adapter supports both books and the
    ///      denominator path is where a decimal error would hide.
    function test_price_composed_dividesAndNormalises() external {
        vm.prank(owner);
        adapter.setQuote(weth, address(ethUsd), STALENESS, address(eurUsd), STALENESS);

        (uint256 price, bool usable,) = adapter.price(weth);

        assertTrue(usable, "composed feed should be usable");
        // 3000 / 1.08 = 2777.777..., floored at 6 decimals.
        assertEq(price, 2_777_777_777, "composition is wrong");
    }

    /// @dev Numerator omitted entirely: the reciprocal of a feed, which is how a dollar stable is
    ///      priced on a euro book.
    function test_price_reciprocal() external {
        vm.prank(owner);
        adapter.setQuote(usdc, address(0), 0, address(eurUsd), STALENESS);

        (uint256 price, bool usable,) = adapter.price(usdc);

        assertTrue(usable, "reciprocal should be usable");
        // 1 / 1.08 = 0.925925...
        assertEq(price, 925_925, "reciprocal is wrong");
    }

    /// @dev A composed price is only as fresh as its stalest leg.
    function test_price_reportsOlderTimestampOfTheTwoLegs() external {
        uint256 older = block.timestamp - 100;
        ethUsd.setAnswerStale(3000e8, older);

        vm.prank(owner);
        adapter.setQuote(weth, address(ethUsd), STALENESS, address(eurUsd), STALENESS);

        (,, uint64 updatedAt) = adapter.price(weth);

        assertEq(updatedAt, uint64(older), "should report the stalest leg");
    }

    // ===================================== NEVER REVERTS =====================================

    function test_price_unconfiguredToken() external {
        (uint256 price, bool usable,) = adapter.price(makeAddr("unknown"));
        assertFalse(usable, "unconfigured must be unusable");
        assertEq(price, 0, "unusable must price at zero");
    }

    function test_price_revertingFeedFailsClosed() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        eurcUsd.setReverts(true);

        (uint256 price, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "a reverting feed must fail closed, not propagate");
        assertEq(price, 0, "unusable must price at zero");
    }

    /// @dev The no-code shape. A call to an address with no code succeeds and returns nothing, so
    ///      the length check rather than the success flag is what catches it.
    function test_price_shortReturnDataFailsClosed() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        eurcUsd.setReturnsShort(true);

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "short return data must fail closed");
    }

    function test_price_nonPositiveAnswerFailsClosed() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        eurcUsd.setAnswer(0);
        (, bool zeroUsable,) = adapter.price(eurc);
        assertFalse(zeroUsable, "a zero answer must fail closed");

        eurcUsd.setAnswer(-1);
        (, bool negativeUsable,) = adapter.price(eurc);
        assertFalse(negativeUsable, "a negative answer must fail closed");
    }

    function test_price_staleLegFailsClosed() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        eurcUsd.setAnswerStale(1.08e8, block.timestamp - STALENESS - 1);

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "a lapsed heartbeat must fail closed");
    }

    /// @dev A future-dated round must not revert the subtraction.
    function test_price_futureDatedRoundDoesNotRevert() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        eurcUsd.setAnswerStale(1.08e8, block.timestamp + 1 days);

        (, bool usable,) = adapter.price(eurc);
        assertTrue(usable, "a future timestamp is age zero, not a revert");
    }

    // ===================================== SEQUENCER =====================================

    /**
     * @dev The property a staleness bound cannot provide. While the sequencer is down feeds keep
     *      returning their last answer with a perfectly recent timestamp, so nothing else here
     *      would catch it.
     */
    function test_price_refusesWhileSequencerDown() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        sequencer.setAnswer(1); // 1 means down.

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "must not price while the sequencer is down");
    }

    /// @dev And not immediately on recovery either: feeds have not necessarily updated yet.
    function test_price_refusesInsideGracePeriod() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        sequencer.setAnswer(0);
        sequencer.setStartedAt(block.timestamp - (GRACE / 2));

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "must wait out the grace period after recovery");
    }

    function test_price_resumesAfterGracePeriod() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        sequencer.setAnswer(0);
        sequencer.setStartedAt(block.timestamp - GRACE - 1);

        (, bool usable,) = adapter.price(eurc);
        assertTrue(usable, "should resume once the grace period has elapsed");
    }

    /// @dev An uninitialised round reads as down rather than as up.
    function test_price_refusesOnUninitialisedSequencerRound() external {
        vm.prank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        sequencer.setStartedAt(0);

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "startedAt of zero must not read as up");
    }

    /// @dev An L1 deployment passes no uptime feed and must price normally.
    function test_price_noSequencerConfigured() external {
        ChainlinkQuoteAdapter l1 = new ChainlinkQuoteAdapter(owner, address(0), 0);

        vm.prank(owner);
        l1.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);

        (, bool usable,) = l1.price(eurc);
        assertTrue(usable, "an L1 deployment should skip the sequencer check");
    }

    // ===================================== CONFIGURATION =====================================

    function test_setQuote_onlyOwner() external {
        vm.prank(stranger);
        vm.expectRevert(ChainlinkQuoteAdapter.Unauthorized.selector);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);
    }

    /// @dev Repointing a feed is equivalent to setting a price, so no role may reach it however
    ///      an authority is configured. `setAuthority` is refused outright for the same reason.
    function test_setAuthority_permanentlyDisabled() external {
        vm.prank(owner);
        vm.expectRevert(ChainlinkQuoteAdapter.Unauthorized.selector);
        adapter.setAuthority(Authority(makeAddr("authority")));
    }

    function test_transferOwnership_onlyOwner() external {
        vm.prank(stranger);
        vm.expectRevert(ChainlinkQuoteAdapter.Unauthorized.selector);
        adapter.transferOwnership(stranger);

        vm.prank(owner);
        adapter.transferOwnership(stranger);
        assertEq(adapter.owner(), stranger, "owner could not hand over");
    }

    /// @dev Two absent legs would be a constant 1.00, which is a bare peg with nothing observing
    ///      it. This contract exists so a price has something behind it.
    function test_setQuote_rejectsTwoEmptyLegs() external {
        vm.prank(owner);
        vm.expectRevert(ChainlinkQuoteAdapter.InvalidInput.selector);
        adapter.setQuote(eurc, address(0), 0, address(0), 0);
    }

    function test_setQuote_rejectsFeedWithoutStaleness() external {
        vm.prank(owner);
        vm.expectRevert(ChainlinkQuoteAdapter.InvalidInput.selector);
        adapter.setQuote(eurc, address(eurcUsd), 0, address(0), 0);
    }

    /// @dev Probed before it is stored, so a configuration that cannot price its own token fails
    ///      at configuration time rather than surfacing later as a declined card transaction.
    function test_setQuote_rejectsUnusableConfiguration() external {
        eurcUsd.setReverts(true);

        vm.prank(owner);
        vm.expectRevert(ChainlinkQuoteAdapter.FeedUnusable.selector);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);
    }

    /// @dev And a failed probe must leave nothing behind.
    function test_setQuote_failedProbeStoresNothing() external {
        eurcUsd.setReverts(true);

        vm.prank(owner);
        try adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0) {
            revert("should have reverted");
        } catch {}

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "a failed probe must not leave a partial entry");
    }

    function test_removeQuote_makesTokenUnpriceable() external {
        vm.startPrank(owner);
        adapter.setQuote(eurc, address(eurcUsd), STALENESS, address(0), 0);
        adapter.removeQuote(eurc);
        vm.stopPrank();

        (, bool usable,) = adapter.price(eurc);
        assertFalse(usable, "a removed quote must fail closed");
    }

    function test_removeQuote_rejectsUnconfigured() external {
        vm.prank(owner);
        vm.expectRevert(ChainlinkQuoteAdapter.NotConfigured.selector);
        adapter.removeQuote(makeAddr("unknown"));
    }
}
