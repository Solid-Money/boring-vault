// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {Authority} from "@solmate/auth/Auth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashLens} from "src/spend-module/SolidCashLens.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";
import {PriceFeedConfig, PriceFeedKind} from "src/spend-module/interfaces/ISolidPriceProvider.sol";
import {SpendingLimit, SpendingLimitLib} from "src/spend-module/libraries/SpendingLimitLib.sol";

import {MockAccountant} from "./mocks/MockAccountant.sol";
import {MockSafe} from "./mocks/MockSafe.sol";
import {MockToken} from "./mocks/MockToken.sol";

/**
 * @notice Unit, fuzz and invariant coverage for the Solid Cash spend module.
 * @dev Organised around the module's stated invariants rather than its functions, because the
 *      invariants are what an auditor and a compromised-key scenario actually care about: funds can
 *      only reach the treasury, only allowlisted assets can move, caps hold on-chain, a `txId` is
 *      single-use, and every degraded input fails closed.
 */
contract SolidCashModuleTest is Test {
    uint8 internal constant SOUSD_DECIMALS = 6;

    /// @dev Live soUSD-on-Fuse rate at time of writing: 1 soUSD = 1.075637 USDC.
    uint96 internal constant SOUSD_RATE = 1_075_637;

    uint8 internal constant SPENDER_ROLE = 1;
    uint8 internal constant GUARDIAN_ROLE = 2;

    address internal owner = makeAddr("owner");
    address internal spender = makeAddr("spender");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal attacker = makeAddr("attacker");

    FuseRolesAuthority internal authority;
    SolidPriceProvider internal provider;
    SolidCashModule internal module;
    SolidCashLens internal lens;
    MockSafe internal safe;

    MockToken internal usdc;
    MockToken internal soUSD;
    MockAccountant internal soUsdAccountant;

    uint256 internal constant DEFAULT_DAILY = 1_000e6;
    uint256 internal constant DEFAULT_MONTHLY = 10_000e6;
    uint256 internal constant MAX_PER_TX = 500e6;

    uint64 internal constant MAX_STALENESS = 7 days;

    function setUp() external {
        // Anchor to a fixed, mid-month, mid-day timestamp so daily/monthly rollover assertions are
        // deterministic rather than dependent on whatever `block.timestamp` the runner starts at.
        vm.warp(1_750_000_000);

        usdc = new MockToken("USD Coin", "USDC", 6);
        soUSD = new MockToken("Solid USD", "soUSD", SOUSD_DECIMALS);
        soUsdAccountant = new MockAccountant(address(soUSD), SOUSD_DECIMALS, SOUSD_RATE, address(usdc));

        SolidPriceProvider implementation = new SolidPriceProvider();
        provider = SolidPriceProvider(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(SolidPriceProvider.initialize, (owner))
                )
            )
        );

        vm.startPrank(owner);
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
                minPriceUsd: 0.97e6,
                maxPriceUsd: 1.03e6
            })
        );
        provider.setTokenConfig(
            address(soUSD),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: SOUSD_DECIMALS,
                baseDecimals: 6,
                maxStaleness: MAX_STALENESS,
                source: address(soUsdAccountant),
                baseAsset: address(usdc),
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 3e6
            })
        );
        vm.stopPrank();

        authority = new FuseRolesAuthority(owner, Authority(address(0)));
        module = new SolidCashModule(owner, address(authority), treasury, address(provider));
        lens = new SolidCashLens(address(module));

        vm.startPrank(owner);
        authority.setRoleCapability(SPENDER_ROLE, address(module), SolidCashModule.spend.selector, true);
        authority.setRoleCapability(GUARDIAN_ROLE, address(module), SolidCashModule.pause.selector, true);
        authority.setRoleCapability(GUARDIAN_ROLE, address(module), SolidCashModule.unpause.selector, true);
        authority.setRoleCapability(GUARDIAN_ROLE, address(module), SolidCashModule.setSafePaused.selector, true);
        authority.setUserRole(spender, SPENDER_ROLE, true);
        authority.setUserRole(guardian, GUARDIAN_ROLE, true);

        module.setOrgCaps(MAX_PER_TX, DEFAULT_DAILY, DEFAULT_MONTHLY);
        module.setDefaultLimits(DEFAULT_DAILY, DEFAULT_MONTHLY);
        module.setLimitRaiseDelay(1 days);
        module.setDustFloor(0);
        // Phase 1 launches with exactly one allowlisted asset; the shape supports more.
        module.allowSpendToken(address(soUSD), 0, 0.9e6, 3e6);
        vm.stopPrank();

        safe = new MockSafe();
        safe.enableModule(address(module));
        soUSD.mint(address(safe), 100_000e6);

        vm.prank(address(safe));
        module.registerSafe(0, 0, 0);
    }

    // ========================================= HELPERS =========================================

    function _tokens(address token) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = token;
    }

    function _tokens(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = amount;
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    /// @dev Single-token spend, the phase-1 shape.
    function _spend(bytes32 txId, uint256 amountUsd) internal returns (uint256) {
        vm.prank(spender);
        return module.spend(address(safe), txId, _tokens(address(soUSD)), _amounts(amountUsd))[0];
    }

    /// @dev Allowlists USDC as a second spend asset and funds the Safe with it.
    function _enableUsdcAsSpendAsset(uint256 mintAmount) internal {
        vm.prank(owner);
        module.allowSpendToken(address(usdc), 0, 0.97e6, 1.03e6);
        usdc.mint(address(safe), mintAmount);
    }

    /**
     * @dev Advances time and refreshes the accountant, mirroring the real Fuse accountant which is
     *      updated at least daily. Tests that deliberately exercise staleness use the raw `skip`.
     */
    function _skip(uint256 duration) internal {
        skip(duration);
        soUsdAccountant.setRate(soUsdAccountant.exchangeRate());
    }

    // ========================================= REGISTRATION =========================================

    function test_registerSafe_appliesOrgDefaults() external {
        SpendingLimit memory limit = module.applicableSpendingLimit(address(safe));
        assertEq(limit.dailyLimit, DEFAULT_DAILY);
        assertEq(limit.monthlyLimit, DEFAULT_MONTHLY);
        assertTrue(module.isRegistered(address(safe)));
    }

    function test_registerSafe_revertsWhenModuleNotEnabled() external {
        MockSafe fresh = new MockSafe();
        vm.prank(address(fresh));
        vm.expectRevert(SolidCashModule.ModuleNotEnabled.selector);
        module.registerSafe(0, 0, 0);
    }

    function test_registerSafe_revertsOnSecondCall() external {
        vm.prank(address(safe));
        vm.expectRevert(SolidCashModule.AlreadyRegistered.selector);
        module.registerSafe(0, 0, 0);
    }

    /// @dev The treasury receives every settlement, so registering it would make the balance-delta
    ///      check in `_settleToken` self-satisfying.
    function test_registerSafe_revertsForTreasury() external {
        vm.prank(treasury);
        vm.expectRevert(SolidCashModule.TreasuryCannotRegister.selector);
        module.registerSafe(0, 0, 0);
    }

    function test_registerSafe_cannotExceedOrgCeilings() external {
        MockSafe fresh = new MockSafe();
        fresh.enableModule(address(module));

        vm.prank(address(fresh));
        vm.expectRevert(SolidCashModule.ExceedsOrgDailyCeiling.selector);
        module.registerSafe(DEFAULT_DAILY + 1, DEFAULT_MONTHLY, 0);
    }

    function test_registerSafe_allowsSafeToChooseLowerLimits() external {
        MockSafe fresh = new MockSafe();
        fresh.enableModule(address(module));

        vm.prank(address(fresh));
        module.registerSafe(50e6, 400e6, 0);

        SpendingLimit memory limit = module.applicableSpendingLimit(address(fresh));
        assertEq(limit.dailyLimit, 50e6);
        assertEq(limit.monthlyLimit, 400e6);
    }

    // ========================================= SPEND =========================================

    function test_spend_movesSharesToTreasuryAtProviderPrice() external {
        uint256 amountUsd = 100e6;
        uint256 expectedShares = (amountUsd * 1e6 + SOUSD_RATE - 1) / SOUSD_RATE;

        uint256 safeBefore = soUSD.balanceOf(address(safe));
        uint256 moved = _spend(bytes32("tx-1"), amountUsd);

        assertEq(moved, expectedShares);
        assertEq(soUSD.balanceOf(treasury), expectedShares);
        assertEq(soUSD.balanceOf(address(safe)), safeBefore - expectedShares);
        assertTrue(module.transactionCleared(address(safe), bytes32("tx-1")));
    }

    /// @dev Rounding must never leave the treasury short of the USD it owes the card network.
    function test_spend_roundsSharesUp() external {
        uint256 moved = _spend(bytes32("tx-dust"), 1);

        assertEq(moved, 1);
        assertGe(module.quoteUsdForToken(address(soUSD), moved), 1);
    }

    function test_spend_revertsForUnauthorizedCaller() external {
        vm.prank(attacker);
        vm.expectRevert("UNAUTHORIZED");
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsOnTxIdReplay() external {
        _spend(bytes32("tx-1"), 100e6);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.TransactionAlreadyCleared.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsAfterUserRevokesModule() external {
        safe.disableModule(address(module));

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ModuleNotEnabled.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsWhenGloballyPaused() external {
        vm.prank(guardian);
        module.pause();

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.Paused.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));

        vm.prank(guardian);
        module.unpause();
        _spend(bytes32("tx-1"), 100e6);
    }

    function test_spend_revertsWhenSafePaused() external {
        vm.prank(guardian);
        module.setSafePaused(address(safe), true);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.SafeIsPaused.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsAbovePerTxCap() external {
        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ExceedsPerTxLimit.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(MAX_PER_TX + 1));
    }

    function test_spend_revertsForUnregisteredSafe() external {
        MockSafe fresh = new MockSafe();
        fresh.enableModule(address(module));

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.NotRegistered.selector);
        module.spend(address(fresh), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(10e6));
    }

    function test_spend_revertsOnZeroAmount() external {
        vm.prank(spender);
        vm.expectRevert(SolidCashModule.AmountZero.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(0));
    }

    /// @dev A Safe that reports success without actually transferring must not be booked as spent.
    ///      This is the `execTransactionFromModule` return-value trap the balance delta guards.
    function test_spend_revertsWhenSafeLiesAboutSuccess() external {
        safe.setExecLiesAboutSuccess(true);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.SettlementShortfall.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsWhenSafeExecutionFails() external {
        safe.setExecAlwaysFails(true);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.SafeExecutionFailed.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsWhenSafeHasInsufficientBalance() external {
        soUSD.burn(address(safe), soUSD.balanceOf(address(safe)));

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.SafeExecutionFailed.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    // ========================================= MULTI-TOKEN =========================================

    function test_spend_drawsFromMultipleTokens() external {
        _enableUsdcAsSpendAsset(1_000e6);

        vm.prank(spender);
        uint256[] memory moved = module.spend(
            address(safe), bytes32("tx-multi"), _tokens(address(soUSD), address(usdc)), _amounts(100e6, 50e6)
        );

        // soUSD at $1.075637, USDC at $1.00 — different prices, same USD interface.
        assertEq(moved[0], (100e6 * 1e6 + SOUSD_RATE - 1) / SOUSD_RATE);
        assertEq(moved[1], 50e6);

        assertEq(soUSD.balanceOf(treasury), moved[0]);
        assertEq(usdc.balanceOf(treasury), moved[1]);
    }

    /// @dev Limits are USD-denominated, so the cap applies to the summed value across assets rather
    ///      than per asset — which is what lets the allowlist grow without multiplying the cap system.
    function test_spend_capsApplyToSummedUsdAcrossTokens() external {
        _enableUsdcAsSpendAsset(1_000e6);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ExceedsPerTxLimit.selector);
        module.spend(
            address(safe),
            bytes32("tx-multi"),
            _tokens(address(soUSD), address(usdc)),
            _amounts(MAX_PER_TX, 1)
        );
    }

    function test_spend_revertsForNonAllowlistedToken() external {
        MockToken rogue = new MockToken("Rogue", "RGE", 18);
        rogue.mint(address(safe), 1_000e18);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.TokenNotAllowed.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(rogue)), _amounts(10e6));
    }

    /**
     * @dev A duplicated token would be double-counted by the per-token balance-delta check: the second
     *      transfer's "before" balance already includes the first, so both could look satisfied while
     *      less value moved than was booked against the limits.
     */
    function test_spend_revertsOnDuplicateToken() external {
        vm.prank(spender);
        vm.expectRevert(SolidCashModule.DuplicateToken.selector);
        module.spend(
            address(safe), bytes32("tx-1"), _tokens(address(soUSD), address(soUSD)), _amounts(10e6, 10e6)
        );
    }

    function test_spend_revertsOnArrayLengthMismatch() external {
        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ArrayLengthMismatch.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD), address(usdc)), _amounts(10e6));
    }

    function test_spend_revertsOnEmptyTokenList() external {
        vm.prank(spender);
        vm.expectRevert(SolidCashModule.InvalidInput.selector);
        module.spend(address(safe), bytes32("tx-1"), new address[](0), new uint256[](0));
    }

    function test_spend_revertsAboveMaxSpendTokens() external {
        address[] memory tokens = new address[](9);
        uint256[] memory amounts = new uint256[](9);
        for (uint256 i = 0; i < 9; ++i) {
            tokens[i] = address(uint160(i + 1));
            amounts[i] = 1e6;
        }

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.TooManyTokens.selector);
        module.spend(address(safe), bytes32("tx-1"), tokens, amounts);
    }

    /// @dev Removing a token is risk-reducing and takes effect immediately.
    function test_disallowSpendToken_stopsSpendingImmediately() external {
        vm.prank(owner);
        module.disallowSpendToken(address(soUSD));

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.TokenNotAllowed.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));

        assertEq(module.spendableUsd(address(safe)), 0);
    }

    function test_allowSpendToken_readsDecimalsFromTheToken() external {
        MockToken eighteen = new MockToken("Eighteen", "EGT", 18);

        vm.prank(owner);
        module.allowSpendToken(address(eighteen), 0, 0.9e6, 1.1e6);

        (, uint8 decimals,,,) = module.spendTokenConfig(address(eighteen));
        assertEq(decimals, 18);
    }

    function test_allowSpendToken_rejectsDuplicateAllowlisting() external {
        vm.prank(owner);
        vm.expectRevert(SolidCashModule.TokenAlreadyAllowed.selector);
        module.allowSpendToken(address(soUSD), 0, 0.9e6, 3e6);
    }

    // ========================================= PRICE BOUNDS =========================================

    /**
     * @dev The central safety property of the upgradeable-provider design: the module refuses a price
     *      it considers absurd even when the provider is perfectly happy to report it. Without this,
     *      an upgrade to the provider could convert a fixed USD debit into an arbitrary token amount.
     */
    function test_spend_revertsWhenProviderPriceOutsideModuleBand() external {
        // Widen the provider's band so it happily reports a price the module must still refuse.
        vm.prank(owner);
        provider.setTokenConfig(
            address(soUSD),
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: SOUSD_DECIMALS,
                baseDecimals: 6,
                maxStaleness: MAX_STALENESS,
                source: address(soUsdAccountant),
                baseAsset: address(usdc),
                pegPriceUsd: 0,
                minPriceUsd: 0.01e6,
                maxPriceUsd: 100e6
            })
        );
        soUsdAccountant.setRate(50e6); // 1 soUSD "worth" $50

        (uint256 providerPrice, bool providerUsable) = provider.priceUsd(address(soUSD));
        assertTrue(providerUsable, "provider accepts it");
        assertEq(providerPrice, 50e6);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.PriceOutOfBounds.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));

        (, bool moduleUsable) = module.getPriceUsd(address(soUSD));
        assertFalse(moduleUsable, "module refuses it");
    }

    function test_spend_revertsWhenPriceUnusable() external {
        soUsdAccountant.setIsPaused(true);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.PriceUnusable.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_spend_revertsOnStalePrice() external {
        skip(MAX_STALENESS + 1);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.PriceUnusable.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
    }

    function test_getPriceUsd_reportsUnusableRatherThanReverting() external {
        skip(MAX_STALENESS + 1);

        (uint256 price, bool usable) = module.getPriceUsd(address(soUSD));
        assertEq(price, 0);
        assertFalse(usable);
        assertEq(module.spendableUsd(address(safe)), 0);
    }

    /// @dev Tightening a band is the fast response to a suspect feed: it disables one asset without
    ///      pausing the whole module.
    function test_updateSpendToken_bandTighteningDisablesOneAsset() external {
        _enableUsdcAsSpendAsset(1_000e6);

        vm.prank(owner);
        module.updateSpendToken(address(soUSD), 0, 2e6, 3e6); // soUSD is $1.0756, now out of band

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.PriceOutOfBounds.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));

        // USDC still works — the module is not paused.
        vm.prank(spender);
        module.spend(address(safe), bytes32("tx-2"), _tokens(address(usdc)), _amounts(100e6));
    }

    function test_setPriceProvider_isOwnerOnly() external {
        vm.prank(attacker);
        vm.expectRevert("UNAUTHORIZED");
        module.setPriceProvider(address(0xdead));
    }

    // ========================================= LIMITS =========================================

    function test_spend_enforcesDailyLimit() external {
        for (uint256 i = 0; i < 2; ++i) {
            _spend(keccak256(abi.encode("day", i)), MAX_PER_TX);
        }

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ExceedsAvailableLimit.selector);
        module.spend(address(safe), bytes32("over"), _tokens(address(soUSD)), _amounts(1));
    }

    function test_spend_dailyLimitRenewsAtLocalMidnight() external {
        _spend(bytes32("a"), MAX_PER_TX);
        _spend(bytes32("b"), MAX_PER_TX);

        assertEq(module.maxCanSpendUsd(address(safe)), 0);

        _skip(1 days);

        assertEq(module.maxCanSpendUsd(address(safe)), DEFAULT_DAILY);
        _spend(bytes32("c"), MAX_PER_TX);
    }

    function test_spend_enforcesMonthlyLimit() external {
        vm.prank(owner);
        module.setOrgCaps(DEFAULT_DAILY, DEFAULT_DAILY, 2_000e6);

        _spend(bytes32("d1"), 1_000e6);
        _skip(1 days);
        _spend(bytes32("d2"), 1_000e6);
        _skip(1 days);

        assertEq(module.maxCanSpendUsd(address(safe)), 0);
        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ExceedsAvailableLimit.selector);
        module.spend(address(safe), bytes32("d3"), _tokens(address(soUSD)), _amounts(1));
    }

    function test_decreaseSpendingLimit_isImmediate() external {
        vm.prank(address(safe));
        module.decreaseSpendingLimit(10e6, 100e6);

        assertEq(module.maxCanSpendUsd(address(safe)), 10e6);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ExceedsAvailableLimit.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(11e6));
    }

    function test_requestSpendingLimitIncrease_isDelayed() external {
        vm.startPrank(address(safe));
        module.decreaseSpendingLimit(10e6, 100e6);
        module.requestSpendingLimitIncrease(DEFAULT_DAILY, DEFAULT_MONTHLY);
        vm.stopPrank();

        assertEq(module.maxCanSpendUsd(address(safe)), 10e6);

        _skip(1 days - 1);
        assertEq(module.maxCanSpendUsd(address(safe)), 10e6);

        _skip(2);
        assertEq(module.maxCanSpendUsd(address(safe)), DEFAULT_DAILY);
    }

    function test_cancelPendingSpendingLimitIncrease() external {
        vm.startPrank(address(safe));
        module.decreaseSpendingLimit(10e6, 100e6);
        module.requestSpendingLimitIncrease(DEFAULT_DAILY, DEFAULT_MONTHLY);
        module.cancelPendingSpendingLimitIncrease();
        vm.stopPrank();

        _skip(30 days);
        assertEq(module.maxCanSpendUsd(address(safe)), 10e6);
    }

    /// @dev A pending increase left armed through a decrease would silently restore the headroom the
    ///      user just revoked.
    function test_decreaseSpendingLimit_disarmsPendingIncrease() external {
        vm.startPrank(address(safe));
        module.decreaseSpendingLimit(500e6, 5_000e6);
        module.requestSpendingLimitIncrease(DEFAULT_DAILY, DEFAULT_MONTHLY);
        module.decreaseSpendingLimit(10e6, 100e6);
        vm.stopPrank();

        _skip(30 days);
        assertEq(module.maxCanSpendUsd(address(safe)), 10e6);
    }

    function test_decreaseSpendingLimit_rejectsAnIncrease() external {
        vm.prank(address(safe));
        vm.expectRevert(SpendingLimitLib.NotADecrease.selector);
        module.decreaseSpendingLimit(DEFAULT_DAILY + 1, DEFAULT_MONTHLY);
    }

    function test_requestSpendingLimitIncrease_rejectsADecrease() external {
        vm.prank(address(safe));
        vm.expectRevert(SpendingLimitLib.NotAnIncrease.selector);
        module.requestSpendingLimitIncrease(10e6, 100e6);
    }

    function test_limitFunctions_onlyCallableByRegisteredSafe() external {
        vm.prank(attacker);
        vm.expectRevert(SolidCashModule.OnlyRegisteredSafe.selector);
        module.decreaseSpendingLimit(1e6, 1e6);
    }

    /// @dev Lowering an org ceiling must bite immediately for Safes that registered under a looser one.
    function test_loweringOrgCeilingAppliesToAlreadyRegisteredSafes() external {
        assertEq(module.maxCanSpendUsd(address(safe)), DEFAULT_DAILY);

        vm.prank(owner);
        module.setOrgCaps(MAX_PER_TX, 25e6, 250e6);

        assertEq(module.maxCanSpendUsd(address(safe)), 25e6);

        vm.prank(spender);
        vm.expectRevert(SolidCashModule.ExceedsAvailableLimit.selector);
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(26e6));
    }

    // ========================================= VALUATION =========================================

    function test_spendableUsd_sumsAcrossAllowlistedTokens() external {
        soUSD.burn(address(safe), soUSD.balanceOf(address(safe)));
        soUSD.mint(address(safe), 100e6); // 100 soUSD -> $107.5637
        _enableUsdcAsSpendAsset(50e6); // 50 USDC -> $50

        assertEq(module.spendableUsd(address(safe)), 107_563_700 + 50e6);
    }

    function test_spendableUsd_appliesPerTokenHaircutAndDustFloor() external {
        soUSD.burn(address(safe), soUSD.balanceOf(address(safe)));
        soUSD.mint(address(safe), 100e6);

        assertEq(module.spendableUsd(address(safe)), 107_563_700);

        vm.startPrank(owner);
        module.updateSpendToken(address(soUSD), 1_000, 0.9e6, 3e6); // 10% haircut
        module.setDustFloor(5e6);
        vm.stopPrank();

        assertEq(module.spendableUsd(address(safe)), 96_807_330 - 5e6);
    }

    /// @dev Per-asset haircuts are the point of moving the haircut into the token config: a volatile
    ///      asset can be discounted without touching a stable one.
    function test_spendableUsd_haircutsAreIndependentPerToken() external {
        soUSD.burn(address(safe), soUSD.balanceOf(address(safe)));
        soUSD.mint(address(safe), 100e6);
        _enableUsdcAsSpendAsset(100e6);

        vm.prank(owner);
        module.updateSpendToken(address(soUSD), 2_000, 0.9e6, 3e6); // 20% on soUSD only

        uint256 expected = (107_563_700 * 8_000) / 10_000 + 100e6;
        assertEq(module.spendableUsd(address(safe)), expected);
    }

    /// @dev The haircut is quote-only: it must never change what a settlement charges, otherwise
    ///      authorize and settle would disagree.
    function test_haircutDoesNotAffectSettlementAmount() external {
        uint256 quoteBefore = module.quoteTokenForUsd(address(soUSD), 100e6);

        vm.prank(owner);
        module.updateSpendToken(address(soUSD), 2_000, 0.9e6, 3e6);

        assertEq(module.quoteTokenForUsd(address(soUSD), 100e6), quoteBefore);
        assertEq(_spend(bytes32("tx-1"), 100e6), quoteBefore);
    }

    /// @dev An unpriceable asset contributes zero rather than an assumed value, so quoted power is
    ///      understated instead of wrong.
    function test_spendableUsd_unpriceableTokenContributesZero() external {
        _enableUsdcAsSpendAsset(100e6);
        soUSD.burn(address(safe), soUSD.balanceOf(address(safe)));
        soUSD.mint(address(safe), 100e6);

        soUsdAccountant.setIsPaused(true);

        assertEq(module.spendableUsd(address(safe)), 100e6); // only the USDC counts
    }

    function test_spendableUsd_zeroOnEveryFailedGate() external {
        vm.prank(guardian);
        module.pause();
        assertEq(module.spendableUsd(address(safe)), 0);

        vm.prank(guardian);
        module.unpause();
        vm.prank(guardian);
        module.setSafePaused(address(safe), true);
        assertEq(module.spendableUsd(address(safe)), 0);

        vm.prank(guardian);
        module.setSafePaused(address(safe), false);
        safe.disableModule(address(module));
        assertEq(module.spendableUsd(address(safe)), 0);
    }

    // ========================================= LENS =========================================

    function test_lens_reportsFullState() external {
        SolidCashLens.SpendAvailability memory data = lens.availableToSpend(address(safe));

        assertTrue(data.moduleEnabled);
        assertTrue(data.registered);
        assertFalse(data.modulePaused);
        assertFalse(data.safePausedFlag);
        assertFalse(data.anyPriceUnusable);
        assertEq(data.spendableUsd, DEFAULT_DAILY); // balance is ample, so the cap binds
        assertEq(data.limitRemainingUsd, DEFAULT_DAILY);
        assertEq(data.maxPerTxUsd, MAX_PER_TX);
        assertEq(data.limit.dailyLimit, DEFAULT_DAILY);
        assertEq(data.blockNumber, block.number);
        assertEq(data.blockTimestamp, block.timestamp);
    }

    /// @dev The breakdown is what lets the backend choose which asset to draw from, and lets a decline
    ///      name the asset that fell short, without a second round trip.
    function test_lens_reportsPerTokenBreakdown() external {
        _enableUsdcAsSpendAsset(250e6);

        SolidCashLens.SpendAvailability memory data = lens.availableToSpend(address(safe));

        assertEq(data.perTokenBreakdown.length, 2);

        assertEq(data.perTokenBreakdown[0].token, address(soUSD));
        assertEq(data.perTokenBreakdown[0].balance, 100_000e6);
        assertEq(data.perTokenBreakdown[0].priceUsd, SOUSD_RATE);
        assertTrue(data.perTokenBreakdown[0].priceUsable);

        assertEq(data.perTokenBreakdown[1].token, address(usdc));
        assertEq(data.perTokenBreakdown[1].balance, 250e6);
        assertEq(data.perTokenBreakdown[1].priceUsd, 1e6);
        assertEq(data.perTokenBreakdown[1].valueUsd, 250e6);
    }

    /**
     * @dev A held asset we cannot price looks like "insufficient funds" to the user and like nothing at
     *      all to us, so the lens flags it explicitly.
     */
    function test_lens_flagsUnpriceableHeldAsset() external {
        soUsdAccountant.setIsPaused(true);

        SolidCashLens.SpendAvailability memory data = lens.availableToSpend(address(safe));

        assertTrue(data.anyPriceUnusable);
        assertFalse(data.perTokenBreakdown[0].priceUsable);
        assertEq(data.perTokenBreakdown[0].valueUsd, 0);
        assertGt(data.perTokenBreakdown[0].balance, 0, "the Safe does hold it");
    }

    /// @dev The authorize path has exactly one read; a Safe that is not deployed yet must produce a
    ///      clean decline rather than reverting that read.
    function test_lens_doesNotRevertForNonSafeAddress() external {
        SolidCashLens.SpendAvailability memory data = lens.availableToSpend(makeAddr("not-a-safe"));

        assertFalse(data.moduleEnabled);
        assertFalse(data.registered);
        assertEq(data.spendableUsd, 0);
    }

    function test_lens_canSpendMatchesModule() external {
        (bool ok, string memory reason) =
            lens.canSpend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
        assertTrue(ok);
        assertEq(reason, "");

        _spend(bytes32("tx-1"), 100e6);

        (ok, reason) = lens.canSpend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(100e6));
        assertFalse(ok);
        assertEq(reason, "Transaction already cleared");
    }

    /// @dev `canSpend` approving something `spend` then rejects is the failure mode that costs real
    ///      money, so the two must agree across the whole grid of gates.
    function test_canSpendAgreesWithSpend(uint256 amountUsd, uint256 balance, bool paused) external {
        amountUsd = bound(amountUsd, 0, 2 * MAX_PER_TX);
        balance = bound(balance, 0, 5_000e6);

        soUSD.burn(address(safe), soUSD.balanceOf(address(safe)));
        soUSD.mint(address(safe), balance);

        if (paused) {
            vm.prank(guardian);
            module.setSafePaused(address(safe), true);
        }

        (bool predicted,) =
            module.canSpend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(amountUsd));

        vm.prank(spender);
        try module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(amountUsd)) {
            assertTrue(predicted, "spend succeeded where canSpend predicted a decline");
        } catch {
            assertFalse(predicted, "canSpend approved an amount spend rejected");
        }
    }

    function test_canSpendAgreesWithSpend_multiToken(uint256 soUsdUsd, uint256 usdcUsd) external {
        soUsdUsd = bound(soUsdUsd, 0, MAX_PER_TX);
        usdcUsd = bound(usdcUsd, 0, MAX_PER_TX);
        _enableUsdcAsSpendAsset(200e6);

        address[] memory tokens = _tokens(address(soUSD), address(usdc));
        uint256[] memory amounts = _amounts(soUsdUsd, usdcUsd);

        (bool predicted,) = module.canSpend(address(safe), bytes32("tx-1"), tokens, amounts);

        vm.prank(spender);
        try module.spend(address(safe), bytes32("tx-1"), tokens, amounts) {
            assertTrue(predicted, "spend succeeded where canSpend predicted a decline");
        } catch {
            assertFalse(predicted, "canSpend approved a spend that reverted");
        }
    }

    // ========================================= INVARIANTS =========================================

    /**
     * @dev The core invariant: no sequence of `spend` calls, in any amounts, can push a Safe past its
     *      daily cap within one window, and every unit that leaves the Safe lands on the treasury.
     */
    function test_noSequenceOfSpendsExceedsDailyCap(uint256 seed) external {
        uint256 totalUsd;
        uint256 treasuryBefore = soUSD.balanceOf(treasury);
        uint256 safeBefore = soUSD.balanceOf(address(safe));

        for (uint256 i = 0; i < 12; ++i) {
            uint256 amountUsd = bound(uint256(keccak256(abi.encode(seed, i))), 1, MAX_PER_TX);

            vm.prank(spender);
            try module.spend(
                address(safe), keccak256(abi.encode("inv", i)), _tokens(address(soUSD)), _amounts(amountUsd)
            ) {
                totalUsd += amountUsd;
            } catch {
                // A decline is always an acceptable outcome; an over-cap approval is not.
            }
        }

        assertLe(totalUsd, DEFAULT_DAILY, "daily cap breached");

        uint256 movedShares = soUSD.balanceOf(treasury) - treasuryBefore;
        assertEq(safeBefore - soUSD.balanceOf(address(safe)), movedShares, "shares leaked elsewhere");
    }

    /**
     * @dev Destination immutability, stated as a property: whatever the spender key does, the only
     *      address whose balance can grow is the treasury — across every allowlisted asset.
     */
    function test_onlyTreasuryEverReceivesFunds(uint256 amountUsd, address probe) external {
        amountUsd = bound(amountUsd, 1, MAX_PER_TX / 2);
        vm.assume(probe != treasury && probe != address(safe) && probe != address(0));
        _enableUsdcAsSpendAsset(1_000e6);

        uint256 soUsdBefore = soUSD.balanceOf(probe);
        uint256 usdcBefore = usdc.balanceOf(probe);

        vm.prank(spender);
        module.spend(
            address(safe),
            bytes32("tx-1"),
            _tokens(address(soUSD), address(usdc)),
            _amounts(amountUsd, amountUsd)
        );

        assertEq(soUSD.balanceOf(probe), soUsdBefore);
        assertEq(usdc.balanceOf(probe), usdcBefore);
    }

    // ========================================= CONFIGURATION ACCESS =========================================

    function test_configurationIsOwnerOnly() external {
        vm.startPrank(attacker);
        vm.expectRevert("UNAUTHORIZED");
        module.setOrgCaps(1, 1, 1);
        vm.expectRevert("UNAUTHORIZED");
        module.setDustFloor(0);
        vm.expectRevert("UNAUTHORIZED");
        module.setLimitRaiseDelay(0);
        vm.expectRevert("UNAUTHORIZED");
        module.allowSpendToken(address(usdc), 0, 1e6, 1e6);
        vm.expectRevert("UNAUTHORIZED");
        module.disallowSpendToken(address(soUSD));
        vm.stopPrank();
    }

    /// @dev The spender key must not be able to pause or unpause; that is the guardian's separate key,
    ///      so a single compromised key cannot both stop and restart the system.
    function test_spenderCannotUseGuardianControls() external {
        vm.prank(spender);
        vm.expectRevert("UNAUTHORIZED");
        module.pause();
    }

    function test_guardianCannotSpend() external {
        vm.prank(guardian);
        vm.expectRevert("UNAUTHORIZED");
        module.spend(address(safe), bytes32("tx-1"), _tokens(address(soUSD)), _amounts(1e6));
    }

    function test_allowSpendToken_rejectsExcessiveHaircut() external {
        vm.prank(owner);
        vm.expectRevert(SolidCashModule.InvalidInput.selector);
        module.allowSpendToken(address(usdc), 5_001, 0.9e6, 1.1e6);
    }

    function test_allowSpendToken_requiresAPriceBand() external {
        vm.prank(owner);
        vm.expectRevert(SolidCashModule.InvalidInput.selector);
        module.allowSpendToken(address(usdc), 0, 0, 1.1e6);
    }

    function test_constructor_rejectsZeroAddresses() external {
        vm.expectRevert(SolidCashModule.InvalidInput.selector);
        new SolidCashModule(owner, address(authority), address(0), address(provider));

        vm.expectRevert(SolidCashModule.InvalidInput.selector);
        new SolidCashModule(owner, address(authority), treasury, address(0));
    }
}
