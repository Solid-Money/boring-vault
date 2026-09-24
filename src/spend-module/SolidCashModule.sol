// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISafe} from "./interfaces/ISafe.sol";
import {ISolidPriceProvider} from "./interfaces/ISolidPriceProvider.sol";
import {SpendingLimit, SpendingLimitLib} from "./libraries/SpendingLimitLib.sol";

/**
 * @title SolidCashModule
 * @notice Safe module that lets Solid's card backend debit a bounded amount of a user's allowlisted
 *         assets straight from the user's Safe, so card spend is backed by productive holdings with
 *         no card pre-loading.
 * @dev Modelled on ether.fi's cash-v3 `CashModuleCore`, narrowed for Solid's needs. Solid user
 *      accounts are stock Safe 1.4.1 smart accounts, not a bespoke account type, so this is an
 *      ordinary Safe module and every movement of value goes through
 *      `ISafe.execTransactionFromModule`.
 *
 *      Security model - asymmetric authority. The backend spender key is deliberately the weakest
 *      party here. It may move value only along tightly bounded paths, and every bound is enforced
 *      on-chain rather than only in the backend:
 *
 *        1. **The destination is not a parameter.** `spend` can only ever send to the immutable
 *           `settlementTreasury`. A fully compromised spender key cannot redirect a single wei to an
 *           attacker; the worst it can do is prepay Solid's own treasury. This is deliberately
 *           stricter than ether.fi, whose destination is an enum selecting among several *mutable*
 *           dispatcher addresses.
 *        2. **The asset set is an allowlist, not a parameter.** `spend` accepts token addresses, but
 *           only tokens an admin has explicitly allowlisted can move. No arbitrary calldata, no
 *           `delegatecall`, no generic `exec` - the module exposes exactly one value-moving function
 *           with a fixed shape.
 *        3. **Caps are enforced here, not only off-chain.** Per-transaction, rolling daily and rolling
 *           monthly caps, plus live org-wide ceilings for staged rollout. All USD-denominated, which
 *           is what lets the asset set grow without multiplying the cap system.
 *        4. **`txId` is consumable exactly once per Safe,** so a replayed settlement cannot debit
 *           twice even if the backend ledger is corrupted.
 *        5. **Limit increases are delayed, decreases immediate** (see `SpendingLimitLib`).
 *        6. **Non-upgradeable.** Migration means enabling a different module, which needs the Safe
 *           owner's signature. There is no admin path to new code over a user's funds.
 *        7. **Pause is first-class,** globally and per-Safe, on a guardian role separate from the
 *           spender role.
 *        8. **Prices are bounded here, independently of the price provider.** See below.
 *
 *      **Why the module re-checks prices.** Pricing lives in `SolidPriceProvider`, which is
 *      upgradeable so new feed families can be added without forcing every user through a re-consent
 *      migration. That upgradeability is a trust vector pointed straight at this contract: for a fixed
 *      USD debit, a wrong price translates directly into over- or under-collecting a user's tokens. So
 *      this module keeps its **own** per-token `minPriceUsd`/`maxPriceUsd` band and rejects any price
 *      outside it. Delegating the bounds to the upgradeable contract would have removed exactly the
 *      check that makes an upgrade survivable.
 *
 *      Access control reuses the repo's solmate `Auth` / `FuseRolesAuthority` pattern (as
 *      `CardDepositManager` does), so `requiresAuth` gates per function selector. Intended role map,
 *      with three separate keys:
 *
 *        SPENDER_ROLE  -> spend
 *        GUARDIAN_ROLE -> pause, unpause, setSafePaused
 *        owner (timelocked multisig) -> every `set*` configuration function
 *
 *      Denomination: `amountUsd` and every limit are 6-decimal USD, matching
 *      `SolidPriceProvider.PRICE_DECIMALS`.
 */
contract SolidCashModule is Auth, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SpendingLimitLib for SpendingLimit;

    // ========================================= CONSTANTS =========================================

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Decimals every USD amount and limit in this contract is expressed in.
    uint8 public constant USD_DECIMALS = 6;

    /// @notice Ceiling on a per-token haircut; at or above this, spending power would be erased.
    uint16 public constant MAX_HAIRCUT_BPS = 5_000;

    /// @notice Ceiling on `limitRaiseDelay`, so the owner cannot make increases unreachable.
    uint64 public constant MAX_LIMIT_RAISE_DELAY = 30 days;

    /**
     * @notice Most tokens one `spend` may touch.
     * @dev Bounds gas and the duplicate scan. A single card transaction realistically draws from one
     *      or two assets; the cap exists so a malformed call cannot make the transaction unminable.
     */
    uint256 public constant MAX_SPEND_TOKENS = 8;

    // ========================================= IMMUTABLES =========================================

    /**
     * @notice The only address `spend` can ever send funds to.
     * @dev Immutable by design - see invariant 1 in the contract docs.
     */
    address public immutable settlementTreasury;

    // ========================================= CONFIGURATION =========================================

    /**
     * @notice Where prices come from.
     * @dev Mutable so a provider can be replaced without a per-user module migration, and because the
     *      provider is itself upgradeable this is the second of two ways pricing can change. Both are
     *      owner-gated and bounded by the per-token band below.
     */
    ISolidPriceProvider public priceProvider;

    /**
     * @notice Per-token spend permission and safety bounds.
     * @param allowed Whether `spend` may move this token at all
     * @param tokenDecimals Cached decimals, validated against the token at allowlist time
     * @param haircutBps Quote-only valuation buffer; higher for volatile assets
     * @param minPriceUsd Module-side sanity floor, independent of the price provider (6 decimals)
     * @param maxPriceUsd Module-side sanity ceiling, independent of the price provider (6 decimals)
     */
    struct SpendTokenConfig {
        bool allowed;
        uint8 tokenDecimals;
        uint16 haircutBps;
        uint96 minPriceUsd;
        uint96 maxPriceUsd;
    }

    mapping(address => SpendTokenConfig) public spendTokenConfig;

    /// @dev Enumeration so the lens can value a Safe's whole position in one call.
    address[] internal _allowedTokens;

    /// @notice Delay before a requested limit increase becomes effective.
    uint64 public limitRaiseDelay;

    /// @notice Hard cap on a single `spend`, summed across its tokens, in USD.
    uint256 public maxPerTxUsd;

    /// @notice Live org-wide ceiling clamping every Safe's daily cap. Lowering it takes effect
    ///         immediately for all Safes, which is what makes staged rollout controllable.
    uint256 public maxDailyLimitUsd;

    /// @notice Live org-wide ceiling clamping every Safe's monthly cap.
    uint256 public maxMonthlyLimitUsd;

    /// @notice Daily cap applied when a Safe registers without choosing one.
    uint256 public defaultDailyLimitUsd;

    /// @notice Monthly cap applied when a Safe registers without choosing one.
    uint256 public defaultMonthlyLimitUsd;

    /// @notice Dust/rounding reserve subtracted from quoted spending power only.
    uint256 public dustFloorUsd;

    /// @notice Global kill switch for `spend`.
    bool public isPaused;

    /// @notice Per-Safe kill switch for `spend`, used for arrears and fraud holds.
    mapping(address => bool) public safePaused;

    // ========================================= PER-SAFE STATE =========================================

    struct SafeCashConfig {
        bool registered;
        SpendingLimit limit;
    }

    mapping(address => SafeCashConfig) internal safeCashConfig;

    /// @notice Per-Safe consumed settlement identifiers. On-chain replay protection.
    mapping(address => mapping(bytes32 => bool)) public transactionCleared;

    // ========================================= ERRORS =========================================

    error InvalidInput();
    error Paused();
    error SafeIsPaused();
    error AlreadyRegistered();
    error NotRegistered();
    error ModuleNotEnabled();
    error TreasuryCannotRegister();
    error OnlyRegisteredSafe();
    error TransactionAlreadyCleared();
    error AmountZero();
    error ExceedsPerTxLimit();
    error ExceedsOrgDailyCeiling();
    error ExceedsOrgMonthlyCeiling();
    error ExceedsAvailableLimit();
    error SafeExecutionFailed();
    error SettlementShortfall();
    error ArrayLengthMismatch();
    error TooManyTokens();
    error DuplicateToken();
    error TokenNotAllowed();
    error TokenAlreadyAllowed();
    error PriceUnusable();
    error PriceOutOfBounds();
    error TokenDecimalsMismatch();

    // ========================================= EVENTS =========================================

    event SafeRegistered(address indexed safe, uint256 dailyLimitUsd, uint256 monthlyLimitUsd, int256 timezoneOffset);
    event Spend(address indexed safe, bytes32 indexed txId, uint256 totalAmountUsd);
    event SpendToken(
        address indexed safe,
        bytes32 indexed txId,
        address indexed token,
        uint256 amountUsd,
        uint256 tokenAmount,
        uint256 priceUsd
    );
    event SpendingLimitDecreased(address indexed safe, uint256 dailyLimitUsd, uint256 monthlyLimitUsd);
    event SpendingLimitIncreaseRequested(
        address indexed safe, uint256 dailyLimitUsd, uint256 monthlyLimitUsd, uint64 activationTime
    );
    event SpendingLimitIncreaseCancelled(address indexed safe);
    event PausedSet(bool isPaused);
    event SafePausedSet(address indexed safe, bool isPaused);
    event LimitRaiseDelaySet(uint64 delay);
    event OrgCapsSet(uint256 maxPerTxUsd, uint256 maxDailyLimitUsd, uint256 maxMonthlyLimitUsd);
    event DefaultLimitsSet(uint256 defaultDailyLimitUsd, uint256 defaultMonthlyLimitUsd);
    event DustFloorSet(uint256 dustFloorUsd);
    event PriceProviderSet(address indexed priceProvider);
    event SpendTokenAllowed(address indexed token, uint16 haircutBps, uint96 minPriceUsd, uint96 maxPriceUsd);
    event SpendTokenUpdated(address indexed token, uint16 haircutBps, uint96 minPriceUsd, uint96 maxPriceUsd);
    event SpendTokenDisallowed(address indexed token);

    // ========================================= CONSTRUCTOR =========================================

    /**
     * @param _owner Timelocked multisig that owns configuration
     * @param _authority `FuseRolesAuthority` granting SPENDER_ROLE / GUARDIAN_ROLE
     * @param _settlementTreasury Immutable, and the only possible destination of user funds
     * @param _priceProvider Initial `SolidPriceProvider`
     */
    constructor(address _owner, address _authority, address _settlementTreasury, address _priceProvider)
        Auth(_owner, Authority(_authority))
    {
        if (_owner == address(0) || _settlementTreasury == address(0) || _priceProvider == address(0)) {
            revert InvalidInput();
        }

        settlementTreasury = _settlementTreasury;
        priceProvider = ISolidPriceProvider(_priceProvider);
    }

    // ========================================= SPEND =========================================

    /**
     * @notice Debits `amountsUsd` of value from `safe` across `tokens`, to the settlement treasury.
     * @dev The single value-moving function. Callable only by SPENDER_ROLE (Solid's sweep engine),
     *      once per `txId` per Safe.
     *
     *      Amounts are USD, not token units: the backend picks which assets to draw from by policy
     *      (idle stables first, then yield-bearing positions) and this contract converts at the
     *      current price. Keeping the interface USD-denominated is what lets the allowlist grow
     *      without touching the limit system or the backend's ledger.
     *
     *      Limit accounting happens once, against the total, before any token moves. State is written
     *      before every external call, so a hostile token or Safe fallback cannot re-enter into a
     *      second debit for the same `txId`.
     * @param safe Safe to debit
     * @param txId Settlement identifier, derived by the backend from Wirex's `unique_operation_id`
     * @param tokens Allowlisted tokens to draw from, no duplicates
     * @param amountsUsd USD to draw from each corresponding token (6 decimals), each non-zero
     * @return tokenAmounts Token units actually moved, positionally matching `tokens`
     */
    function spend(address safe, bytes32 txId, address[] calldata tokens, uint256[] calldata amountsUsd)
        external
        requiresAuth
        nonReentrant
        returns (uint256[] memory tokenAmounts)
    {
        if (isPaused) revert Paused();
        if (safePaused[safe]) revert SafeIsPaused();

        SafeCashConfig storage $ = safeCashConfig[safe];
        if (!$.registered) revert NotRegistered();

        // A user revoking the module is the primary consent-withdrawal mechanism and must stop
        // spending instantly, so it is re-checked on every debit rather than cached at registration.
        if (!ISafe(safe).isModuleEnabled(address(this))) revert ModuleNotEnabled();

        uint256 length = tokens.length;
        if (length == 0) revert InvalidInput();
        if (length != amountsUsd.length) revert ArrayLengthMismatch();
        if (length > MAX_SPEND_TOKENS) revert TooManyTokens();
        _requireNoDuplicates(tokens);

        uint256 totalUsd;
        for (uint256 i = 0; i < length; ++i) {
            if (amountsUsd[i] == 0) revert AmountZero();
            totalUsd += amountsUsd[i];
        }

        if (totalUsd > maxPerTxUsd) revert ExceedsPerTxLimit();
        if (transactionCleared[safe][txId]) revert TransactionAlreadyCleared();
        if (totalUsd > _maxCanSpendUsd($)) revert ExceedsAvailableLimit();

        transactionCleared[safe][txId] = true;
        $.limit.spend(totalUsd);

        tokenAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            tokenAmounts[i] = _settleToken(safe, txId, tokens[i], amountsUsd[i]);
        }

        emit Spend(safe, txId, totalUsd);
    }

    /**
     * @dev Moves one token's share of a spend and proves it arrived.
     *
     *      `execTransactionFromModule` returns `false` instead of bubbling an inner revert, and a
     *      non-reverting ERC20 could return `false` from `transfer` without the Safe noticing, so
     *      success is confirmed by the treasury's observed balance delta rather than trusted from the
     *      return value.
     */
    function _settleToken(address safe, bytes32 txId, address token, uint256 amountUsd)
        private
        returns (uint256 tokenAmount)
    {
        SpendTokenConfig memory config = spendTokenConfig[token];
        if (!config.allowed) revert TokenNotAllowed();

        uint256 price = _boundedPrice(token, config);

        // Round up so a rounding remainder can never leave the treasury short of the USD it owes the
        // card network. Worst case the user pays one token unit more than the exact quote.
        tokenAmount = amountUsd.mulDivUp(10 ** config.tokenDecimals, price);
        if (tokenAmount == 0) revert AmountZero();

        ERC20 erc20 = ERC20(token);
        uint256 balanceBefore = erc20.balanceOf(settlementTreasury);

        bool ok = ISafe(safe).execTransactionFromModule(
            token,
            0,
            abi.encodeWithSelector(ERC20.transfer.selector, settlementTreasury, tokenAmount),
            ISafe.Operation.Call
        );
        if (!ok) revert SafeExecutionFailed();

        if (erc20.balanceOf(settlementTreasury) - balanceBefore < tokenAmount) revert SettlementShortfall();

        emit SpendToken(safe, txId, token, amountUsd, tokenAmount, price);
    }

    // ========================================= SAFE-OWNER ACTIONS =========================================

    /**
     * @notice Opts a Safe into card spending. Must be called *by the Safe itself*.
     * @dev Safe 1.4.1 has no module-setup callback, so the enable flow is a batched owner-signed user
     *      operation: `Safe.enableModule(this)` followed by `this.registerSafe(...)`. Because
     *      `msg.sender` is the Safe, owner consent is structural rather than something this contract
     *      has to verify.
     *
     *      A Safe may pick its own caps (mirroring ether.fi's per-safe limits) but never above the
     *      live org ceilings; passing 0 takes the org default. Note that the caps bound *this
     *      module's* authority over the caller's own funds, so a user choosing a higher cap only
     *      widens their own exposure, never anyone else's.
     * @param dailyLimitUsd Desired daily cap in USD, or 0 for the org default
     * @param monthlyLimitUsd Desired monthly cap in USD, or 0 for the org default
     * @param timezoneOffset Offset from UTC in seconds, so windows roll at the user's local midnight
     */
    function registerSafe(uint256 dailyLimitUsd, uint256 monthlyLimitUsd, int256 timezoneOffset) external {
        SafeCashConfig storage $ = safeCashConfig[msg.sender];
        if ($.registered) revert AlreadyRegistered();

        // The treasury receives every settlement, so letting it register would make the balance-delta
        // check in `_settleToken` trivially satisfiable.
        if (msg.sender == settlementTreasury) revert TreasuryCannotRegister();
        if (!ISafe(msg.sender).isModuleEnabled(address(this))) revert ModuleNotEnabled();

        if (dailyLimitUsd == 0) dailyLimitUsd = defaultDailyLimitUsd;
        if (monthlyLimitUsd == 0) monthlyLimitUsd = defaultMonthlyLimitUsd;
        if (dailyLimitUsd > maxDailyLimitUsd) revert ExceedsOrgDailyCeiling();
        if (monthlyLimitUsd > maxMonthlyLimitUsd) revert ExceedsOrgMonthlyCeiling();

        $.registered = true;
        $.limit.initialize(dailyLimitUsd, monthlyLimitUsd, timezoneOffset);

        emit SafeRegistered(msg.sender, dailyLimitUsd, monthlyLimitUsd, timezoneOffset);
    }

    /**
     * @notice Lowers the caller Safe's caps, effective immediately.
     * @dev Risk-reducing, so never delayed. Cancels any pending increase.
     */
    function decreaseSpendingLimit(uint256 dailyLimitUsd, uint256 monthlyLimitUsd) external onlyRegisteredSafe {
        safeCashConfig[msg.sender].limit.decrease(dailyLimitUsd, monthlyLimitUsd);
        emit SpendingLimitDecreased(msg.sender, dailyLimitUsd, monthlyLimitUsd);
    }

    /**
     * @notice Requests higher caps for the caller Safe, effective after `limitRaiseDelay`.
     * @dev Risk-increasing, so always delayed - the delay is the window in which a user (or Solid) can
     *      notice and cancel an increase they did not intend.
     */
    function requestSpendingLimitIncrease(uint256 dailyLimitUsd, uint256 monthlyLimitUsd)
        external
        onlyRegisteredSafe
    {
        if (dailyLimitUsd > maxDailyLimitUsd) revert ExceedsOrgDailyCeiling();
        if (monthlyLimitUsd > maxMonthlyLimitUsd) revert ExceedsOrgMonthlyCeiling();

        safeCashConfig[msg.sender].limit.requestIncrease(dailyLimitUsd, monthlyLimitUsd, limitRaiseDelay);

        emit SpendingLimitIncreaseRequested(
            msg.sender, dailyLimitUsd, monthlyLimitUsd, uint64(block.timestamp) + limitRaiseDelay
        );
    }

    /// @notice Disarms the caller Safe's pending limit increase.
    function cancelPendingSpendingLimitIncrease() external onlyRegisteredSafe {
        safeCashConfig[msg.sender].limit.cancelPendingIncrease();
        emit SpendingLimitIncreaseCancelled(msg.sender);
    }

    // ========================================= GUARDIAN =========================================

    /// @notice Halts all spending. GUARDIAN_ROLE.
    function pause() external requiresAuth {
        isPaused = true;
        emit PausedSet(true);
    }

    /// @notice Resumes spending. GUARDIAN_ROLE.
    function unpause() external requiresAuth {
        isPaused = false;
        emit PausedSet(false);
    }

    /// @notice Halts or resumes spending for one Safe. GUARDIAN_ROLE.
    function setSafePaused(address safe, bool paused) external requiresAuth {
        safePaused[safe] = paused;
        emit SafePausedSet(safe, paused);
    }

    // ========================================= TOKEN ALLOWLIST =========================================

    /**
     * @notice Allowlists a token for spending. Owner.
     * @dev `tokenDecimals` is read from the token rather than supplied, and the price band is
     *      mandatory: a token allowlisted without bounds would inherit whatever the upgradeable price
     *      provider said, which is precisely the dependency this band exists to break.
     * @param token Token to allow
     * @param haircutBps Quote-only valuation buffer for this asset
     * @param minPriceUsd Module-side sanity floor (6 decimals), must be non-zero
     * @param maxPriceUsd Module-side sanity ceiling (6 decimals)
     */
    function allowSpendToken(address token, uint16 haircutBps, uint96 minPriceUsd, uint96 maxPriceUsd)
        external
        requiresAuth
    {
        if (token == address(0)) revert InvalidInput();
        if (spendTokenConfig[token].allowed) revert TokenAlreadyAllowed();
        if (haircutBps > MAX_HAIRCUT_BPS) revert InvalidInput();
        if (minPriceUsd == 0 || maxPriceUsd < minPriceUsd) revert InvalidInput();

        uint8 decimals = ERC20(token).decimals();
        if (decimals == 0 || decimals > 36) revert TokenDecimalsMismatch();

        spendTokenConfig[token] = SpendTokenConfig({
            allowed: true,
            tokenDecimals: decimals,
            haircutBps: haircutBps,
            minPriceUsd: minPriceUsd,
            maxPriceUsd: maxPriceUsd
        });
        _allowedTokens.push(token);

        emit SpendTokenAllowed(token, haircutBps, minPriceUsd, maxPriceUsd);
    }

    /**
     * @notice Updates an allowlisted token's haircut and price band. Owner.
     * @dev Tightening a band is the fast response to a suspect feed: it takes effect immediately and
     *      makes the affected token unspendable without pausing the whole module.
     */
    function updateSpendToken(address token, uint16 haircutBps, uint96 minPriceUsd, uint96 maxPriceUsd)
        external
        requiresAuth
    {
        SpendTokenConfig storage config = spendTokenConfig[token];
        if (!config.allowed) revert TokenNotAllowed();
        if (haircutBps > MAX_HAIRCUT_BPS) revert InvalidInput();
        if (minPriceUsd == 0 || maxPriceUsd < minPriceUsd) revert InvalidInput();

        config.haircutBps = haircutBps;
        config.minPriceUsd = minPriceUsd;
        config.maxPriceUsd = maxPriceUsd;

        emit SpendTokenUpdated(token, haircutBps, minPriceUsd, maxPriceUsd);
    }

    /**
     * @notice Removes a token from the allowlist. Owner.
     * @dev Immediate and risk-reducing: the token stops being spendable and stops contributing to
     *      quoted spending power. It does not touch anything already settled.
     */
    function disallowSpendToken(address token) external requiresAuth {
        if (!spendTokenConfig[token].allowed) revert TokenNotAllowed();

        delete spendTokenConfig[token];

        uint256 length = _allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_allowedTokens[i] == token) {
                _allowedTokens[i] = _allowedTokens[length - 1];
                _allowedTokens.pop();
                break;
            }
        }

        emit SpendTokenDisallowed(token);
    }

    // ========================================= CONFIGURATION =========================================

    /**
     * @notice Replaces the price provider. Owner.
     * @dev Combined with the provider's own upgradeability, this is the second of two ways pricing can
     *      change - which is why every price is still band-checked per token here.
     */
    function setPriceProvider(address _priceProvider) external requiresAuth {
        if (_priceProvider == address(0)) revert InvalidInput();
        priceProvider = ISolidPriceProvider(_priceProvider);
        emit PriceProviderSet(_priceProvider);
    }

    /// @notice Sets the delay before a requested limit increase becomes effective. Owner.
    function setLimitRaiseDelay(uint64 delay) external requiresAuth {
        if (delay > MAX_LIMIT_RAISE_DELAY) revert InvalidInput();
        limitRaiseDelay = delay;
        emit LimitRaiseDelaySet(delay);
    }

    /**
     * @notice Sets the per-transaction cap and the live org-wide daily/monthly ceilings. Owner.
     * @dev Lowering a ceiling applies to already-registered Safes immediately, because
     *      `_maxCanSpendUsd` clamps against it on every read and every spend.
     */
    function setOrgCaps(uint256 _maxPerTxUsd, uint256 _maxDailyLimitUsd, uint256 _maxMonthlyLimitUsd)
        external
        requiresAuth
    {
        if (_maxDailyLimitUsd > _maxMonthlyLimitUsd) revert InvalidInput();
        maxPerTxUsd = _maxPerTxUsd;
        maxDailyLimitUsd = _maxDailyLimitUsd;
        maxMonthlyLimitUsd = _maxMonthlyLimitUsd;
        emit OrgCapsSet(_maxPerTxUsd, _maxDailyLimitUsd, _maxMonthlyLimitUsd);
    }

    /// @notice Sets the caps a Safe receives when it registers without choosing its own. Owner.
    function setDefaultLimits(uint256 _defaultDailyLimitUsd, uint256 _defaultMonthlyLimitUsd) external requiresAuth {
        if (_defaultDailyLimitUsd > _defaultMonthlyLimitUsd) revert InvalidInput();
        defaultDailyLimitUsd = _defaultDailyLimitUsd;
        defaultMonthlyLimitUsd = _defaultMonthlyLimitUsd;
        emit DefaultLimitsSet(_defaultDailyLimitUsd, _defaultMonthlyLimitUsd);
    }

    /// @notice Sets the quote-only dust reserve. Owner.
    function setDustFloor(uint256 _dustFloorUsd) external requiresAuth {
        dustFloorUsd = _dustFloorUsd;
        emit DustFloorSet(_dustFloorUsd);
    }

    // ========================================= VIEWS =========================================

    /// @notice Tokens currently allowlisted for spending.
    function allowedTokens() external view returns (address[] memory) {
        return _allowedTokens;
    }

    /**
     * @notice Price this module would use for `token`, and whether it is acceptable.
     * @dev Applies the module's own band on top of the provider's answer, so this reports what `spend`
     *      would actually do - not merely what the provider thinks. Returns a flag rather than
     *      reverting so the lens can report one bad feed in a single call.
     */
    function getPriceUsd(address token) public view returns (uint256 price, bool usable) {
        SpendTokenConfig memory config = spendTokenConfig[token];
        if (!config.allowed) return (0, false);

        (uint256 providerPrice, bool providerUsable) = priceProvider.priceUsd(token);
        if (!providerUsable) return (0, false);
        if (providerPrice < config.minPriceUsd || providerPrice > config.maxPriceUsd) return (0, false);

        return (providerPrice, true);
    }

    /// @notice Token units required to settle `amountUsd`, rounded up exactly as `spend` does.
    function quoteTokenForUsd(address token, uint256 amountUsd) public view returns (uint256) {
        SpendTokenConfig memory config = spendTokenConfig[token];
        uint256 price = _boundedPrice(token, config);

        return amountUsd.mulDivUp(10 ** config.tokenDecimals, price);
    }

    /// @notice USD value of `tokenAmount`, rounded down.
    function quoteUsdForToken(address token, uint256 tokenAmount) public view returns (uint256) {
        SpendTokenConfig memory config = spendTokenConfig[token];
        uint256 price = _boundedPrice(token, config);

        return tokenAmount.mulDivDown(price, 10 ** config.tokenDecimals);
    }

    /// @notice Whether `safe` has opted into card spending.
    function isRegistered(address safe) external view returns (bool) {
        return safeCashConfig[safe].registered;
    }

    /**
     * @notice Whether this module is enabled on `safe`, reported as `false` for any address that
     *         cannot answer the question.
     * @dev Deliberately a raw `staticcall` rather than `try ISafe(safe).isModuleEnabled(...)`.
     *      Solidity's `try/catch` only catches reverts, not failures decoding the *return data*, so a
     *      call to an address with no code - which succeeds and returns nothing - propagates a decode
     *      revert straight past the `catch`. Solid Safes are ERC-4337 accounts that may be
     *      counterfactual (address known, contract not yet deployed), so this is a live case, not a
     *      theoretical one, and reverting here would take down the lens' single authorize read
     *      instead of producing a clean decline.
     *
     *      Public so the lens shares this exact implementation rather than repeating it. `spend`
     *      intentionally does not use this: on the write path an unanswerable Safe must abort, not be
     *      silently treated as revoked.
     */
    function isModuleEnabledOn(address safe) public view returns (bool) {
        (bool ok, bytes memory returnData) =
            safe.staticcall(abi.encodeWithSelector(ISafe.isModuleEnabled.selector, address(this)));

        return ok && returnData.length == 32 && abi.decode(returnData, (bool));
    }

    /**
     * @notice `safe`'s limit state with all matured transitions applied.
     * @dev The same `getCurrentLimit` the write path uses, so quotes and settlement agree.
     */
    function applicableSpendingLimit(address safe) public view returns (SpendingLimit memory) {
        return SpendingLimitLib.getCurrentLimit(SpendingLimitLib.load(safeCashConfig[safe].limit));
    }

    /// @notice Remaining headroom under `safe`'s caps and the live org ceilings.
    function maxCanSpendUsd(address safe) public view returns (uint256) {
        return _maxCanSpendUsd(safeCashConfig[safe]);
    }

    /**
     * @notice Per-token spending power for `safe`, one entry per allowlisted token.
     * @param safe Safe to value
     * @return tokens Allowlisted tokens, positionally matching the other returns
     * @return balances Raw token balances held by the Safe
     * @return prices Module-accepted USD price of each token, 0 when unusable
     * @return valuesUsd Haircut USD value of each balance, 0 when the price is unusable
     */
    function perTokenSpendable(address safe)
        public
        view
        returns (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory prices,
            uint256[] memory valuesUsd
        )
    {
        uint256 length = _allowedTokens.length;
        tokens = new address[](length);
        balances = new uint256[](length);
        prices = new uint256[](length);
        valuesUsd = new uint256[](length);

        for (uint256 i = 0; i < length; ++i) {
            address token = _allowedTokens[i];
            SpendTokenConfig memory config = spendTokenConfig[token];

            tokens[i] = token;
            balances[i] = ERC20(token).balanceOf(safe);

            (uint256 price, bool usable) = getPriceUsd(token);
            if (!usable) continue;

            prices[i] = price;
            // Haircut is applied to the quote only, never to settlement, so a quote can only ever be
            // more conservative than what `spend` would charge.
            valuesUsd[i] = balances[i].mulDivDown(price, 10 ** config.tokenDecimals).mulDivDown(
                BPS_DENOMINATOR - config.haircutBps, BPS_DENOMINATOR
            );
        }
    }

    /**
     * @notice USD the authorize path may approve for `safe` right now, ignoring off-chain in-flight
     *         debits.
     * @dev Deliberately the conservative side of every judgement: per-token haircuts and the dust
     *      floor are applied, a pending limit increase is ignored until matured, a token with an
     *      unusable price contributes zero rather than an assumed value, and any failed gate (paused,
     *      unregistered, module revoked) yields 0. Callers must still subtract their own unmined
     *      in-flight debits - the chain cannot know about those.
     *
     *      Not clamped by `maxPerTxUsd`: this is total spending power, which is what a user's balance
     *      display should show. A single transaction is separately bounded by `maxPerTxUsd`, which the
     *      lens returns alongside this so the authorize path can take the minimum of the two.
     */
    function spendableUsd(address safe) public view returns (uint256) {
        SafeCashConfig storage $ = safeCashConfig[safe];
        if (isPaused || safePaused[safe] || !$.registered) return 0;
        if (!isModuleEnabledOn(safe)) return 0;

        (,,, uint256[] memory valuesUsd) = perTokenSpendable(safe);

        uint256 balanceUsd;
        for (uint256 i = 0; i < valuesUsd.length; ++i) {
            balanceUsd += valuesUsd[i];
        }

        if (balanceUsd <= dustFloorUsd) return 0;
        balanceUsd -= dustFloorUsd;

        uint256 limitRemaining = _maxCanSpendUsd($);

        return balanceUsd < limitRemaining ? balanceUsd : limitRemaining;
    }

    /**
     * @notice Dry-run of `spend`, returning a human-readable decline reason.
     * @dev Mirrors `spend`'s gates in the same order so an approval here cannot be followed by a
     *      rejection there. Reason strings are surfaced to ops dashboards, not to the card network.
     */
    function canSpend(address safe, bytes32 txId, address[] calldata tokens, uint256[] calldata amountsUsd)
        external
        view
        returns (bool, string memory)
    {
        (bool ok, string memory reason) = _checkSpendPreconditions(safe, txId, tokens, amountsUsd);
        if (!ok) return (false, reason);

        for (uint256 i = 0; i < tokens.length; ++i) {
            (ok, reason) = _canSettleToken(safe, tokens[i], amountsUsd[i]);
            if (!ok) return (false, reason);
        }

        return (true, "");
    }

    /**
     * @dev Everything `spend` checks before any token is touched: gates, array shape, the summed total
     *      against the per-transaction cap, replay state, and the rolling limits.
     *
     *      Split out of `canSpend` because the combined function exceeded the EVM's addressable stack
     *      depth. Keeping the split at exactly the boundary `spend` itself uses - whole-transaction
     *      checks here, per-token checks in `_canSettleToken` - means the two stay easy to compare, and
     *      the ordering that guarantees a `canSpend` approval is honoured by `spend` is preserved.
     */
    function _checkSpendPreconditions(
        address safe,
        bytes32 txId,
        address[] calldata tokens,
        uint256[] calldata amountsUsd
    ) private view returns (bool, string memory) {
        if (isPaused) return (false, "Module paused");
        if (safePaused[safe]) return (false, "Safe paused");

        SafeCashConfig storage $ = safeCashConfig[safe];
        if (!$.registered) return (false, "Safe not registered");
        if (!isModuleEnabledOn(safe)) return (false, "Module not enabled on safe");

        uint256 length = tokens.length;
        if (length == 0) return (false, "No tokens supplied");
        if (length != amountsUsd.length) return (false, "Array length mismatch");
        if (length > MAX_SPEND_TOKENS) return (false, "Too many tokens");

        uint256 totalUsd;
        for (uint256 i = 0; i < length; ++i) {
            if (amountsUsd[i] == 0) return (false, "Amount zero");
            totalUsd += amountsUsd[i];

            for (uint256 j = i + 1; j < length; ++j) {
                if (tokens[i] == tokens[j]) return (false, "Duplicate token");
            }
        }

        if (totalUsd > maxPerTxUsd) return (false, "Exceeds per transaction limit");
        if (transactionCleared[safe][txId]) return (false, "Transaction already cleared");
        if (totalUsd > _maxCanSpendUsd($)) return (false, "Exceeds available spending limit");

        return (true, "");
    }

    /// @dev The per-token half of `canSpend`, mirroring `_settleToken`'s checks without moving value.
    function _canSettleToken(address safe, address token, uint256 amountUsd)
        private
        view
        returns (bool, string memory)
    {
        SpendTokenConfig memory config = spendTokenConfig[token];
        if (!config.allowed) return (false, "Token not allowed");

        (uint256 price, bool usable) = getPriceUsd(token);
        if (!usable) return (false, "Price unavailable");

        uint256 tokenAmount = amountUsd.mulDivUp(10 ** config.tokenDecimals, price);
        if (tokenAmount == 0) return (false, "Amount zero");
        if (ERC20(token).balanceOf(safe) < tokenAmount) return (false, "Insufficient balance");

        return (true, "");
    }

    // ========================================= INTERNAL =========================================

    /**
     * @dev Price for the write path: reverts unless the provider reports a usable price *and* it sits
     *      inside this module's own band for the token.
     *
     *      The band is the whole point. `SolidPriceProvider` is upgradeable, so without an independent
     *      check here an upgrade could set any price and this contract would convert a fixed USD debit
     *      into an arbitrary token amount. Two distinct errors are raised so an operator can tell "the
     *      feed is down" from "the feed is reporting something we refuse to believe".
     */
    function _boundedPrice(address token, SpendTokenConfig memory config) private view returns (uint256) {
        if (!config.allowed) revert TokenNotAllowed();

        (uint256 price, bool usable) = priceProvider.priceUsd(token);
        if (!usable) revert PriceUnusable();
        if (price < config.minPriceUsd || price > config.maxPriceUsd) revert PriceOutOfBounds();

        return price;
    }

    /**
     * @dev Rejects duplicate tokens in a spend.
     *
     *      A duplicate would be double-counted by the per-token balance-delta check: the second
     *      transfer's "before" balance already includes the first, so both could appear satisfied
     *      while less value moved than booked. Quadratic, which is why `MAX_SPEND_TOKENS` is small.
     */
    function _requireNoDuplicates(address[] calldata tokens) private pure {
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; ++i) {
            for (uint256 j = i + 1; j < length; ++j) {
                if (tokens[i] == tokens[j]) revert DuplicateToken();
            }
        }
    }

    /**
     * @dev Headroom under the Safe's own windows, clamped by the live org ceilings.
     *      Clamping on read (rather than only at registration) is what makes lowering a ceiling a
     *      real, immediate control over Safes that registered under a looser one.
     */
    function _maxCanSpendUsd(SafeCashConfig storage $) internal view returns (uint256) {
        SpendingLimit memory limit = SpendingLimitLib.getCurrentLimit(SpendingLimitLib.load($.limit));

        if (limit.dailyLimit > maxDailyLimitUsd) limit.dailyLimit = maxDailyLimitUsd;
        if (limit.monthlyLimit > maxMonthlyLimitUsd) limit.monthlyLimit = maxMonthlyLimitUsd;

        return SpendingLimitLib.maxCanSpend(limit);
    }

    modifier onlyRegisteredSafe() {
        if (!safeCashConfig[msg.sender].registered) revert OnlyRegisteredSafe();
        _;
    }
}
