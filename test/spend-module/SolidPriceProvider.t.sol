// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";
import {PriceFeedConfig, PriceFeedKind} from "src/spend-module/interfaces/ISolidPriceProvider.sol";

import {MockAccountant} from "./mocks/MockAccountant.sol";
import {MockToken} from "./mocks/MockToken.sol";

/**
 * @notice Coverage for the upgradeable price registry.
 * @dev The test that matters most here is `test_priceUsd_soEthComposesThroughWeth`. An earlier version
 *      of the module priced a vault share by treating its accountant's base asset as if it were dollars.
 *      That is true for soUSD (base USDC) and false for soETH (base WETH), and the failure was silent:
 *      it would have valued 1 soETH at ~$1.008 instead of ~$3025, so a $100 card debit would have
 *      collected about 0.00000003 of a cent of soETH. These tests pin the composition that fixes it.
 */
contract SolidPriceProviderTest is Test {
    address internal admin = makeAddr("admin");
    address internal priceAdmin = makeAddr("priceAdmin");
    address internal upgrader = makeAddr("upgrader");
    address internal attacker = makeAddr("attacker");

    SolidPriceProvider internal provider;

    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal soUSD;
    MockToken internal soETH;

    MockAccountant internal soUsdAccountant;
    MockAccountant internal soEthAccountant;

    /// @dev Live soUSD-on-Fuse rate at time of writing: 1 soUSD = 1.075637 USDC.
    uint96 internal constant SOUSD_RATE = 1_075_637;

    /// @dev Live soETH-on-Fuse rate: 1 soETH = 1.008413248843674606 WETH. Note the 18 decimals.
    uint96 internal constant SOETH_RATE = 1_008_413_248_843_674_606;

    uint96 internal constant WETH_PRICE_USD = 3_000e6;

    uint64 internal constant MAX_STALENESS = 7 days;

    function setUp() external {
        vm.warp(1_750_000_000);

        usdc = new MockToken("USD Coin", "USDC", 6);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        soUSD = new MockToken("Solid USD", "soUSD", 6);
        soETH = new MockToken("Solid ETH", "soETH", 18);

        soUsdAccountant = new MockAccountant(address(soUSD), 6, SOUSD_RATE, address(usdc));
        soEthAccountant = new MockAccountant(address(soETH), 18, SOETH_RATE, address(weth));

        SolidPriceProvider implementation = new SolidPriceProvider();
        provider = SolidPriceProvider(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(SolidPriceProvider.initialize, (admin))
                )
            )
        );

        vm.startPrank(admin);
        provider.grantRole(provider.PRICE_ADMIN_ROLE(), priceAdmin);
        provider.grantRole(provider.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();

        _configureStable(address(usdc), 1e6, 0.97e6, 1.03e6);
        // WETH stands in for a market feed. There is no market-price feed kind yet by design (stables
        // and Veda shares only), which is exactly why soETH cannot be onboarded for real until one is
        // added by upgrade.
        _configureStable(address(weth), WETH_PRICE_USD, 100e6, 20_000e6);
    }

    function _configureStable(address token, uint96 peg, uint96 minPrice, uint96 maxPrice) internal {
        // Read decimals *before* the prank: arguments are evaluated first, so an external call inside
        // the argument list would consume the single-call prank and leave `setTokenConfig` unpranked.
        uint8 tokenDecimals = MockToken(token).decimals();

        vm.prank(priceAdmin);
        provider.setTokenConfig(
            token,
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: tokenDecimals,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: peg,
                minPriceUsd: minPrice,
                maxPriceUsd: maxPrice
            })
        );
    }

    function _configureVeda(
        address token,
        address accountant,
        address baseAsset,
        uint96 minPrice,
        uint96 maxPrice
    ) internal {
        // Hoisted for the same reason as in `_configureStable`.
        uint8 tokenDecimals = MockToken(token).decimals();
        uint8 baseDecimals = MockToken(baseAsset).decimals();

        vm.prank(priceAdmin);
        provider.setTokenConfig(
            token,
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: tokenDecimals,
                baseDecimals: baseDecimals,
                maxStaleness: MAX_STALENESS,
                source: accountant,
                baseAsset: baseAsset,
                pegPriceUsd: 0,
                minPriceUsd: minPrice,
                maxPriceUsd: maxPrice
            })
        );
    }

    // ========================================= STABLE =========================================

    function test_priceUsd_stable() external {
        (uint256 price, bool usable) = provider.priceUsd(address(usdc));

        assertTrue(usable);
        assertEq(price, 1e6);
    }

    function test_priceUsd_unconfiguredTokenIsUnusable() external {
        MockToken unknown = new MockToken("Unknown", "UNK", 18);

        (uint256 price, bool usable) = provider.priceUsd(address(unknown));

        assertFalse(usable);
        assertEq(price, 0);
    }

    /**
     * @dev A configured peg outside its own band is a configuration contradiction, so it is rejected at
     *      write time rather than silently reported as unusable forever afterwards.
     */
    function test_setTokenConfig_rejectsPegOutsideBand() external {
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.PegPriceOutsideBand.selector);
        provider.setTokenConfig(
            address(usdc),
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: 6,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: 2e6,
                minPriceUsd: 0.97e6,
                maxPriceUsd: 1.03e6
            })
        );
    }

    // ========================================= VEDA COMPOSITION =========================================

    function test_priceUsd_soUsdComposesThroughUsdc() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        (uint256 price, bool usable) = provider.priceUsd(address(soUSD));

        assertTrue(usable);
        // rate 1.075637 USDC x $1.00 = $1.075637
        assertEq(price, 1_075_637);
    }

    /**
     * @dev The regression test for the decimal bug. soETH's accountant is denominated in WETH — 18
     *      decimals, ~$3000 — not dollars. Dividing by the *base* asset's decimals rather than the
     *      share's is what makes this land on ~$3025 instead of ~$1.
     */
    function test_priceUsd_soEthComposesThroughWeth() external {
        _configureVeda(address(soETH), address(soEthAccountant), address(weth), 100e6, 20_000e6);

        (uint256 price, bool usable) = provider.priceUsd(address(soETH));

        assertTrue(usable);

        // 1.008413248843674606 WETH x $3000 = $3025.239746...
        uint256 expected = (uint256(SOETH_RATE) * WETH_PRICE_USD) / 1e18;
        assertEq(price, expected);
        assertEq(price, 3_025_239_746);

        // The bug this pins: had the base been assumed dollar-like, the price would have been ~1.008e6.
        assertGt(price, 3_000e6, "soETH must be priced in thousands, not ~1 dollar");
    }

    function test_priceUsd_composedPriceTracksBaseAssetPrice() external {
        _configureVeda(address(soETH), address(soEthAccountant), address(weth), 100e6, 20_000e6);

        (uint256 before,) = provider.priceUsd(address(soETH));

        // ETH halves; soETH must halve with it, because the base asset is priced rather than assumed.
        _configureStable(address(weth), 1_500e6, 100e6, 20_000e6);

        (uint256 after_,) = provider.priceUsd(address(soETH));
        assertApproxEqRel(after_, before / 2, 1e12);
    }

    // ========================================= VEDA FAILURE MODES =========================================

    function test_priceUsd_unusableWhenAccountantPaused() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);
        soUsdAccountant.setIsPaused(true);

        (uint256 price, bool usable) = provider.priceUsd(address(soUSD));

        assertFalse(usable);
        assertEq(price, 0);
    }

    function test_priceUsd_unusableWhenRateStale() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        skip(MAX_STALENESS + 1);

        (, bool usable) = provider.priceUsd(address(soUSD));
        assertFalse(usable);
    }

    function test_priceUsd_usableExactlyAtStalenessBoundary() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        skip(MAX_STALENESS);

        (, bool usable) = provider.priceUsd(address(soUSD));
        assertTrue(usable);
    }

    function test_priceUsd_unusableWhenRateZero() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);
        soUsdAccountant.setRate(0);

        (, bool usable) = provider.priceUsd(address(soUSD));
        assertFalse(usable);
    }

    /**
     * @dev A composed price is only as good as its base, so an unusable base must not be silently
     *      skipped. Note this branch is currently **unreachable** through a `STABLE` base: a stable's
     *      computed price *is* its configured peg, and `setTokenConfig` refuses a peg outside its own
     *      band, so a configured stable can never report unusable. The guard exists for the moment a
     *      market-price feed kind is added by upgrade, at which point a base like WETH genuinely can go
     *      stale at runtime. Asserted here as the invariant that makes it unreachable, rather than left
     *      as an untested branch nobody can explain.
     */
    function test_priceUsd_stableBaseCannotBecomeUnusable() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        (, bool baseUsable) = provider.priceUsd(address(usdc));
        assertTrue(baseUsable);

        // The peg-within-band check is what guarantees that, so a contradictory update is rejected.
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.PegPriceOutsideBand.selector);
        provider.setTokenConfig(
            address(usdc),
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: 6,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: 1e6,
                minPriceUsd: 1.5e6,
                maxPriceUsd: 2e6
            })
        );

        (, bool usable) = provider.priceUsd(address(soUSD));
        assertTrue(usable, "composed price stays usable because its stable base cannot fail");
    }

    /**
     * @dev The one-hop rule has to hold in both directions. Checking only that a new feed's own base is
     *      uncomposed leaves a gap: a token already serving as someone else's base could later be
     *      converted into a composed feed, lengthening that chain to two hops and, by repetition, to
     *      arbitrarily many. Each hop is a recursive call on the authorize path's single read, so the
     *      failure mode would be a gas-exhausted decline.
     */
    function test_setTokenConfig_refusesToComposeATokenAlreadyUsedAsABase() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);
        assertTrue(provider.isUsedAsBase(address(usdc)));

        // USDC now backs soUSD, so it may not itself become a composed feed - even though its own
        // proposed base (WETH) is a plain stable and would satisfy the downward check alone.
        MockAccountant usdcAccountant = new MockAccountant(address(usdc), 6, 1e6, address(weth));

        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.TokenIsUsedAsABase.selector);
        provider.setTokenConfig(
            address(usdc),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 6,
                baseDecimals: 18,
                maxStaleness: MAX_STALENESS,
                source: address(usdcAccountant),
                baseAsset: address(weth),
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 3e6
            })
        );
    }

    /// @dev A token not used as a base may still be freely reconfigured, including into a composed feed.
    function test_setTokenConfig_allowsComposingAnUnusedToken() external {
        assertFalse(provider.isUsedAsBase(address(soUSD)));

        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        (, bool usable) = provider.priceUsd(address(soUSD));
        assertTrue(usable);
    }

    /**
     * @dev The band is the backstop against a compromised rate updater walking the exchange rate to an
     *      absurd value.
     */
    function test_priceUsd_unusableWhenOutsideBand() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 1.2e6);

        soUsdAccountant.setRate(5e6); // 1 soUSD suddenly "worth" $5

        (, bool usable) = provider.priceUsd(address(soUSD));
        assertFalse(usable);
    }

    // ========================================= CONFIG VALIDATION =========================================

    function test_setTokenConfig_rejectsAccountantForDifferentVault() external {
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.AccountantVaultMismatch.selector);
        provider.setTokenConfig(
            address(soETH),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 18,
                baseDecimals: 6,
                maxStaleness: MAX_STALENESS,
                source: address(soUsdAccountant), // prices soUSD, not soETH
                baseAsset: address(usdc),
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 20_000e6
            })
        );
    }

    /// @dev Declaring the wrong base asset is the mistake that produced the soETH mispricing.
    function test_setTokenConfig_rejectsWrongBaseAsset() external {
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.AccountantBaseMismatch.selector);
        provider.setTokenConfig(
            address(soETH),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 18,
                baseDecimals: 6,
                maxStaleness: MAX_STALENESS,
                source: address(soEthAccountant),
                baseAsset: address(usdc), // really WETH
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 20_000e6
            })
        );
    }

    function test_setTokenConfig_rejectsWrongBaseDecimals() external {
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.TokenDecimalsMismatch.selector);
        provider.setTokenConfig(
            address(soETH),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 18,
                baseDecimals: 6, // WETH is 18
                maxStaleness: MAX_STALENESS,
                source: address(soEthAccountant),
                baseAsset: address(weth),
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 20_000e6
            })
        );
    }

    function test_setTokenConfig_rejectsUnpricedBaseAsset() external {
        MockToken orphanBase = new MockToken("Orphan", "ORPH", 18);
        MockToken share = new MockToken("Share", "SHR", 18);
        MockAccountant orphanAccountant = new MockAccountant(address(share), 18, 1e18, address(orphanBase));

        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.BaseAssetNotConfigured.selector);
        provider.setTokenConfig(
            address(share),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 18,
                baseDecimals: 18,
                maxStaleness: MAX_STALENESS,
                source: address(orphanAccountant),
                baseAsset: address(orphanBase),
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 20_000e6
            })
        );
    }

    /// @dev The one-hop rule: it makes a pricing cycle structurally impossible without recursion guards.
    function test_setTokenConfig_rejectsComposedBaseAsset() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        MockToken nested = new MockToken("Nested", "NST", 6);
        MockAccountant nestedAccountant = new MockAccountant(address(nested), 6, 1e6, address(soUSD));

        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.BaseAssetMustNotBeComposed.selector);
        provider.setTokenConfig(
            address(nested),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 6,
                baseDecimals: 6,
                maxStaleness: MAX_STALENESS,
                source: address(nestedAccountant),
                baseAsset: address(soUSD),
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 3e6
            })
        );
    }

    function test_setTokenConfig_rejectsInvalidBand() external {
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.InvalidPriceBand.selector);
        provider.setTokenConfig(
            address(usdc),
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: 6,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: 1e6,
                minPriceUsd: 0, // must be non-zero
                maxPriceUsd: 2e6
            })
        );
    }

    function test_setTokenConfig_rejectsNoneKind() external {
        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.UnsupportedFeedKind.selector);
        provider.setTokenConfig(
            address(usdc),
            PriceFeedConfig({
                kind: PriceFeedKind.NONE,
                tokenDecimals: 6,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: 1e6,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 1.1e6
            })
        );
    }

    // ========================================= REMOVAL & ENUMERATION =========================================

    function test_configuredTokens_enumerates() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        address[] memory tokens = provider.configuredTokens();
        assertEq(tokens.length, 3); // usdc, weth, soUSD
    }

    function test_removeTokenConfig_makesTokenUnpriceable() external {
        vm.prank(priceAdmin);
        provider.removeTokenConfig(address(weth));

        (, bool usable) = provider.priceUsd(address(weth));
        assertFalse(usable);
        assertEq(provider.configuredTokens().length, 1);
    }

    /// @dev Removing a base asset out from under a composed token would break it as a side effect.
    function test_removeTokenConfig_refusesWhileUsedAsABase() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        vm.prank(priceAdmin);
        vm.expectRevert(SolidPriceProvider.TokenIsUsedAsABase.selector);
        provider.removeTokenConfig(address(usdc));
    }

    // ========================================= CONVERSIONS =========================================

    function test_tokenAmountForUsd_roundsUp() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        (uint256 amount, bool usable) = provider.tokenAmountForUsd(address(soUSD), 100e6);

        assertTrue(usable);
        // $100 / $1.075637 = 92.968... soUSD, rounded up
        assertEq(amount, (100e6 * 1e6 + SOUSD_RATE - 1) / SOUSD_RATE);
    }

    function test_tokenAmountForUsd_handlesEighteenDecimalToken() external {
        _configureVeda(address(soETH), address(soEthAccountant), address(weth), 100e6, 20_000e6);

        (uint256 amount, bool usable) = provider.tokenAmountForUsd(address(soETH), 100e6);

        assertTrue(usable);
        // ~$100 of a ~$3025 asset is ~0.033 soETH — an 18-decimal quantity, not a 6-decimal one.
        assertApproxEqRel(amount, 0.033055e18, 1e15);
    }

    function test_usdValueOfToken() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);

        (uint256 value, bool usable) = provider.usdValueOfToken(address(soUSD), 100e6);

        assertTrue(usable);
        assertEq(value, 107_563_700); // 100 soUSD x $1.075637
    }

    function test_conversions_reportUnusableRatherThanReverting() external {
        MockToken unknown = new MockToken("Unknown", "UNK", 18);

        (uint256 amount, bool usable) = provider.tokenAmountForUsd(address(unknown), 100e6);
        assertFalse(usable);
        assertEq(amount, 0);
    }

    // ========================================= ACCESS CONTROL & UPGRADE =========================================

    function test_setTokenConfig_isPriceAdminOnly() external {
        vm.prank(attacker);
        vm.expectRevert();
        provider.setTokenConfig(
            address(usdc),
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: 6,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: 1e6,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 1.1e6
            })
        );
    }

    function test_upgrade_requiresUpgraderRole() external {
        SolidPriceProvider newImplementation = new SolidPriceProvider();

        vm.prank(attacker);
        vm.expectRevert();
        provider.upgradeToAndCall(address(newImplementation), "");

        vm.prank(upgrader);
        provider.upgradeToAndCall(address(newImplementation), "");
    }

    /// @dev Configuration must survive an upgrade, or every token would need re-onboarding.
    function test_upgrade_preservesConfiguration() external {
        _configureVeda(address(soUSD), address(soUsdAccountant), address(usdc), 0.9e6, 3e6);
        (uint256 priceBefore,) = provider.priceUsd(address(soUSD));

        SolidPriceProvider newImplementation = new SolidPriceProvider();
        vm.prank(upgrader);
        provider.upgradeToAndCall(address(newImplementation), "");

        (uint256 priceAfter, bool usable) = provider.priceUsd(address(soUSD));
        assertTrue(usable);
        assertEq(priceAfter, priceBefore);
        assertEq(provider.configuredTokens().length, 3);
    }

    /**
     * @dev The price admin must not be able to replace the implementation: day-to-day feed management
     *      and the power to rewrite pricing logic are separate keys by design.
     */
    function test_priceAdminCannotUpgrade() external {
        SolidPriceProvider newImplementation = new SolidPriceProvider();

        vm.prank(priceAdmin);
        vm.expectRevert();
        provider.upgradeToAndCall(address(newImplementation), "");
    }

    function test_initialize_cannotBeCalledTwice() external {
        vm.expectRevert();
        provider.initialize(attacker);
    }
}
