// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISafe} from "../interfaces/ISafe.sol";
import {SpendingLimit} from "../libraries/SpendingLimitLib.sol";
import {SpendingLimitLibV2} from "./libraries/SpendingLimitLibV2.sol";
import {ISolidPriceProviderV2} from "./interfaces/ISolidPriceProviderV2.sol";
import {
    BookedSpend,
    LiquidationSizing,
    Mode,
    Params,
    PendingTokenConfig,
    PendingWithdrawal,
    SafeConfig,
    TokenConfig
} from "./SolidCashTypes.sol";

import {LiquidationInput, SolidCreditMathLib} from "./libraries/SolidCreditMathLib.sol";
import {SolidCashConfigLib} from "./libraries/SolidCashConfigLib.sol";
import {SolidCashStorageV2} from "./SolidCashStorageV2.sol";

/**
 * @title SolidCashModuleV2
 * @notice One Safe module serving every card funding mode: Debit sells the user's assets to the
 *         settlement treasury, Credit locks them as collateral and books USD debt against Solid's
 *         float. Replaces `SolidCashModule` per-user and opt-in; v1 stays live for everyone who has
 *         not switched.
 *
 * @dev **Why one module and not two.** Collateral is locked *inside* the spend — the user never
 *      deposits deliberately — so a credit contract needs standing authority over the Safe either
 *      way, which means an enabled Safe module either way. Once that is true a second module buys
 *      nothing and costs real safety: mode could only be enforced off-chain on the debit side, and
 *      two independent `SpendingLimit` sets would let one user consume two daily limits in a day.
 *
 *      **`Smart` mode, and why it is only a permission.** `Smart` permits both funding paths on one
 *      Safe and lets the backend choose per transaction. It adds no value path, no destination and
 *      no arithmetic — it is exactly `Debit` union `Credit` at the `_requirePath` check, and
 *      everything downstream is the code that already ran. The two properties that make that safe
 *      are the same two that justify one module rather than two: `_bookOperation` charges ONE
 *      `SpendingLimit` from both paths, so a Smart Safe cannot consume two daily windows; and it
 *      writes ONE `booked[safe][txId]` marker, so a settlement id cannot be charged once on each
 *      path. `nonReentrant` is a single shared guard, so a token hook inside `spend` cannot
 *      re-enter `spendCredit` either.
 *
 *      What `Smart` genuinely widens is which keys are live against one Safe: both `SPENDER_ROLE`
 *      and `CREDIT_SPENDER_ROLE` can act on it. That is the feature, it is what the `modeDelay` on
 *      entering `Smart` is for, and the shared limit is what bounds it.
 *
 *      **Security model — the destination is never a parameter.** `spend` can only reach the
 *      immutable `settlementTreasury`; `spendCredit` can only reach `address(this)`. Neither
 *      spender key can redirect a single wei to an attacker. The worst a fully compromised credit
 *      spender can do is lock a user's own collateral and book debt against it, bounded by every cap
 *      and unwindable by `reverseSpend`.
 *
 *      **Non-upgradeable, deliberately.** It moves and custodies user funds. Upgradeability would
 *      force every value check to be duplicated defensively against a hostile future
 *      implementation. Parameters are all owner-settable; only mechanics changes need a new
 *      deployment, and the migration pattern below is then already built and rehearsed.
 *
 *      **Coexistence with v1.** A Safe must never be operated by both modules, or it would hold two
 *      independent cap sets. `registerSafe` asserts v1 is disabled, and every value-moving function
 *      re-checks it — so a user who later re-enables v1 by hand makes THIS module inert while v1
 *      keeps working, and the state self-heals the moment v1 is disabled again. The fallback is
 *      always toward the working module, never toward two.
 *
 *      **Rounding discipline.** Every rounding decision favours the protocol, so no sequence of
 *      operations can extract value through precision:
 *        - value taken from a user (settlement, collateral lock, collateral repay) rounds UP
 *        - value credited to a user (repayment value, liquidation collateral out) rounds DOWN
 *        - debt rounds UP on read and on borrow; debt reduction rounds DOWN
 *        - collateral value, borrowing power and liquidation capacity all round DOWN
 *      A full repayment is handled as an explicit zeroing rather than a subtraction, so no dust
 *      remainder can survive it.
 *
 *      **Pricing — understate, never revert.** v1 reverted outside its band, which on an
 *      appreciating asset is a scheduled outage: soUSD's ceiling is eventually crossed by legitimate
 *      yield. Here a price above the ceiling is CAPPED. Capping reduces debit spending power and
 *      reduces borrowing power alike, so conservatism points the same way for both uses and an
 *      expired ceiling degrades to "power stops growing" instead of breaking the card.
 *
 *      Access control reuses the repo's solmate `Auth` / `FuseRolesAuthority` pattern, so
 *      `requiresAuth` gates per selector. Intended role map, with four separate keys:
 *
 *        SPENDER_ROLE        -> spend                       (the SAME key also holds v1's role)
 *        CREDIT_SPENDER_ROLE -> spendCredit and the credit ledger operations
 *        GUARDIAN_ROLE       -> pause / unpause / setSafePaused / setTokenPaused
 *        owner (timelocked)  -> every configuration function
 *
 *      Denomination: every USD amount is 6-decimal, matching `SolidPriceProviderV2.PRICE_DECIMALS`.
 *      LTV, liquidation threshold, health factor and the interest index are WAD (1e18).
 */
contract SolidCashModuleV2 is SolidCashStorageV2 {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SpendingLimitLibV2 for SpendingLimit;

    // ========================================= CONSTRUCTOR =========================================

    /**
     * @param _owner Timelocked multisig that owns configuration
     * @param _authority `FuseRolesAuthority` granting the spender and guardian roles
     * @param _settlementTreasury Immutable, and the only possible destination of user value
     * @param _v1Module The deployed `SolidCashModule`, for the both-enabled fail-closed check
     * @param _priceProvider Initial `SolidPriceProviderV2`
     */
    constructor(
        address _owner,
        address _authority,
        address _settlementTreasury,
        address _v1Module,
        address _priceProvider
    ) Auth(_owner, Authority(_authority)) {
        if (
            _owner == address(0) || _settlementTreasury == address(0) || _v1Module == address(0)
                || _priceProvider == address(0)
        ) revert InvalidInput();

        settlementTreasury = _settlementTreasury;
        v1Module = _v1Module;
        priceProvider = ISolidPriceProviderV2(_priceProvider);

        // Both must be non-zero before any debt can exist. `getCurrentIndex`-style forward reads
        // compute `block.timestamp - lastAccrualTimestamp`, so a zero timestamp would produce an
        // absurd index on the very first accrual.
        interestIndex = WAD;
        lastAccrualTimestamp = uint64(block.timestamp);
    }

    // ========================================= DEBIT SPEND =========================================

    /**
     * @notice Sells `amountsUsd` of value from `safe` across `tokens`, to the settlement treasury.
     * @dev Permitted in `Debit` and `Smart`. Limit accounting happens once, against the total,
     *      before any token moves. Replay state and the limit are written before every external call, so a hostile
     *      token hook cannot re-enter into a second debit for the same `txId`.
     * @param safe Safe to debit
     * @param txId Settlement identifier, derived from Wirex's `unique_operation_id`
     * @param tokens Spendable tokens to draw from, no duplicates
     * @param amountsUsd USD to draw from each corresponding token (6 decimals), each non-zero
     * @return tokenAmounts Token units actually moved, positionally matching `tokens`
     */
    function spend(address safe, bytes32 txId, address[] calldata tokens, uint256[] calldata amountsUsd)
        external
        requiresAuth
        nonReentrant
        returns (uint256[] memory tokenAmounts)
    {
        SafeConfig storage $ = _requireSpendable(safe);
        _requirePath($, Mode.Debit);

        uint256 length = tokens.length;
        if (length == 0) revert InvalidInput();
        if (length != amountsUsd.length) revert ArrayLengthMismatch();
        if (length > MAX_TOKENS) revert TooManyTokens();
        _requireNoDuplicates(tokens);

        uint256 totalUsd;
        for (uint256 i = 0; i < length; ++i) {
            if (amountsUsd[i] == 0) revert AmountZero();
            totalUsd += amountsUsd[i];
        }

        _bookOperation(safe, txId, totalUsd, false);

        tokenAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            tokenAmounts[i] = _settleDebitToken(safe, txId, tokens[i], amountsUsd[i]);
        }

        emit Spend(safe, txId, totalUsd);
    }

    /**
     * @dev Moves one token's share of a debit spend and proves it arrived.
     *
     *      `execTransactionFromModule` returns `false` instead of bubbling an inner revert, and a
     *      non-reverting ERC20 could return `false` from `transfer` without the Safe noticing, so
     *      success is confirmed by the treasury's observed balance delta rather than trusted from
     *      the return value.
     */
    function _settleDebitToken(address safe, bytes32 txId, address token, uint256 amountUsd)
        private
        returns (uint256 tokenAmount)
    {
        TokenConfig storage cfg = _tokenConfig[token];
        if (!cfg.spendable) revert TokenNotSpendable();
        if (tokenPaused[token]) revert TokenIsPaused();

        uint256 price = _settlementPrice(token, cfg);

        // Round up so a rounding remainder can never leave the treasury short of the USD it owes
        // the card network. Worst case the user pays one token unit more than the exact quote.
        tokenAmount = amountUsd.mulDiv(10 ** cfg.tokenDecimals, price, Math.Rounding.Ceil);
        if (tokenAmount == 0) revert AmountZero();

        uint256 balanceBefore = IERC20(token).balanceOf(settlementTreasury);

        _execFromSafe(safe, token, abi.encodeWithSelector(IERC20.transfer.selector, settlementTreasury, tokenAmount));

        if (IERC20(token).balanceOf(settlementTreasury) - balanceBefore < tokenAmount) revert SettlementShortfall();

        emit SpendToken(safe, txId, token, amountUsd, tokenAmount, price);
    }

    // ========================================= CREDIT SPEND =========================================

    /**
     * @notice Books `amountUsd` of USD debt against `safe`, locking only the shortfall of collateral
     *         needed to back it.
     * @dev Permitted in `Credit` and `Smart`, and the whole feature. The user signs nothing here
     *      and never deposits collateral deliberately.
     *
     *      **Nothing reaches the treasury.** Solid's float already paid the card network, so the
     *      "borrow" is a ledger entry; the user's asset moves Safe -> escrow and is not sold.
     *
     *      **Ordering is load-bearing.** Replay state, the limit and the debt are all written before
     *      the first collateral pull, because a collateral token's transfer hook is an external call
     *      and a hostile hook must not be able to re-enter into a second spend on the same `txId`.
     *      Booking before pulling is safe because a shortfall reverts the whole transaction.
     * @param safe Safe to charge
     * @param txId Settlement identifier
     * @param amountUsd USD to book (6 decimals)
     * @param collateralPreference Tokens to lock from, in order. Least volatile first
     */
    function spendCredit(address safe, bytes32 txId, uint256 amountUsd, address[] calldata collateralPreference)
        external
        requiresAuth
        nonReentrant
    {
        SafeConfig storage $ = _requireSpendable(safe);
        _requirePath($, Mode.Credit);
        if (amountUsd == 0) revert AmountZero();
        if (collateralPreference.length == 0) revert InvalidInput();
        if (collateralPreference.length > MAX_TOKENS) revert TooManyTokens();
        _requireNoDuplicates(collateralPreference);

        _accrue();
        _bookOperation(safe, txId, amountUsd, true);
        _addDebt($, amountUsd);

        _requireDebtCaps($, safe);
        _lockForShortfall(safe, $, collateralPreference, true);

        // The hard bound, at each token's real LTV. `_lockForShortfall` sizes to a buffered LTV, so
        // this passes with margin whenever it locked anything at all.
        (uint256 power,,) = _positionValue(safe);
        if (_debtOf($) > power) revert ExceedsBorrowingPower();

        _refreshHealthStamp(safe, $);
        emit CreditSpend(safe, txId, amountUsd, interestIndex);
    }

    /**
     * @notice Records a spend Wirex processed regardless of our answer (`is_mandatory`).
     * @dev **Exempt from the borrowing-power check, and from nothing else.** Refusing to record the
     *      liability would leave it invisible on-chain while the Master Account still went negative,
     *      so this path cannot decline for want of collateral. Every other control still applies,
     *      and each is here for a reason this function used to ignore:
     *
     *        - **Both pauses.** The guardian's switch is the response to a suspected spender-key
     *          compromise. A path that outlives it is a path the compromise is aimed at.
     *        - **`maxForcedSpendUsd`.** A mandatory authorization is a real card transaction, and
     *          bounded like one. Without it the only bound was the `uint72` field width.
     *        - **`maxGlobalDebtUsd`.** Solid's float solvency, never a per-user allowance, and
     *          therefore never waivable — which cannot be true if one path skips it.
     *        - **The rolling window is recorded** (not enforced), so forced volume is visible in the
     *          figure that claims to describe a Safe's spending.
     *
     *      The collateral pull is genuinely best-effort now: it locks whatever the Safe can cover
     *      and keeps it, rather than rolling the whole loop back on a shortfall. A forced spend
     *      remains the one path that can leave debt above borrowing power.
     */
    function bookForcedSpend(address safe, bytes32 txId, uint256 amountUsd, address[] calldata collateralPreference)
        external
        requiresAuth
        nonReentrant
    {
        SafeConfig storage $ = _safeConfig[safe];
        if (!$.registered) revert NotRegistered();
        _requireNotPaused(safe);
        // A Safe that has not opted into credit has not agreed to carry debt or to have its assets
        // escrowed, and this path does both. Deliberately checked against the effective mode, so a
        // Safe mid-switch is treated exactly as `spendCredit` would treat it. The module's enabled
        // state is NOT re-checked here: a mandatory authorization must stay recordable for a user
        // who has revoked the module, which is the whole reason this function exists.
        _requirePath($, Mode.Credit);
        if (amountUsd == 0) revert AmountZero();
        if (amountUsd > _params.maxForcedSpendUsd) revert ExceedsForcedSpendCap();
        if (booked[safe][txId].exists) revert TransactionAlreadyBooked();
        if (collateralPreference.length > MAX_TOKENS) revert TooManyTokens();
        _requireNoDuplicates(collateralPreference);

        _accrue();
        uint72 amount = _toU72(amountUsd);
        booked[safe][txId] = BookedSpend(amount, amount, 0, true, true, true);
        _addDebt($, amountUsd);
        $.forcedDebtUsd += amountUsd;
        _safeLimit[safe].recordSpend(amountUsd);

        // Both caps, not just the global one — which is what the docstring above already claimed.
        // The per-Safe cap is waivable (`requestWaiveSafeLimits`), so an account that legitimately
        // needs more headroom has a route that leaves an event and a delay behind it; a compromised
        // key does not.
        _requireDebtCaps($, safe);

        _lockForShortfall(safe, $, collateralPreference, false);

        _refreshHealthStamp(safe, $);
        emit ForcedSpendBooked(safe, txId, amountUsd, true);
    }

    /**
     * @notice Reconciles a booked spend against the settled amount (tip, FX, partial capture).
     * @dev An increase re-runs the full capacity and cap checks and may lock more collateral; a
     *      decrease is a plain debt reduction, and never below what has already been reversed.
     *
     *      **The bound is measured against the ORIGINAL authorization, not the running total.**
     *      Bounding each call against the previous call's result compounds: at 10%,
     *      100 -> 110 -> 121 -> 133, without limit. `originalUsd` is written once and never
     *      rewritten, so `maxAdjustmentBps` means what it says over the life of the record.
     *
     *      Setting `newAmountUsd` to zero is a legitimate full cancellation and is safe here: the
     *      replay marker is `exists`, a dedicated bit no amount can reach.
     */
    function adjustBookedSpend(
        address safe,
        bytes32 txId,
        uint256 newAmountUsd,
        address[] calldata collateralPreference
    ) external requiresAuth nonReentrant {
        SafeConfig storage $ = _safeConfig[safe];
        BookedSpend memory record = booked[safe][txId];
        if (!record.exists) revert TransactionNotBooked();
        if (!record.isCredit) revert WrongMode();

        uint256 from = record.bookedUsd;
        uint256 original = record.originalUsd;
        uint256 ceiling = original + original.mulDiv(_params.maxAdjustmentBps, MAX_BPS, Math.Rounding.Floor);
        if (newAmountUsd > ceiling || newAmountUsd < record.reversedUsd) revert InvalidInput();

        _accrue();
        booked[safe][txId].bookedUsd = _toU72(newAmountUsd);

        if (newAmountUsd > from) {
            // An increase adds debt and can lock collateral, so it is a risk-increasing operation
            // and honours the guardian's switches exactly as the two spend paths do. A decrease is
            // de-risking and stays open while paused, like every other unwind here.
            _requireNotPaused(safe);

            uint256 delta = newAmountUsd - from;
            _addDebt($, delta);
            if (record.isForced) $.forcedDebtUsd += delta;
            _requireDebtCaps($, safe);
            if (collateralPreference.length > MAX_TOKENS) revert TooManyTokens();
            _requireNoDuplicates(collateralPreference);
            _lockForShortfall(safe, $, collateralPreference, true);
            (uint256 power,,) = _positionValue(safe);
            if (_debtOf($) > power) revert ExceedsBorrowingPower();
        } else if (newAmountUsd < from) {
            uint256 delta = from - newAmountUsd;
            _reduceDebt($, delta);
            if (record.isForced) _reduceForcedDebt($, delta);
        }

        _refreshHealthStamp(safe, $);
        emit BookedSpendAdjusted(safe, txId, from, newAmountUsd);
    }

    /**
     * @notice Undoes part or all of a credit spend: a refund, a reversal, a settle rejection, or an
     *         authorization that expired unsettled.
     * @dev **Reduces debt and moves no token.** A refund is not a repayment — routing one through
     *      `repay` would pay the user out of treasury funds. Bounded by the original booking so a
     *      reversal cannot manufacture credit, and `reversalId` is consumable once so a refund
     *      cannot be replayed. Partial reversals are supported because Wirex sends them.
     *
     *      The freed borrowing power makes collateral withdrawable; it is deliberately not
     *      auto-returned, since the user may want it backing the next spend.
     */
    function reverseSpend(address safe, bytes32 txId, bytes32 reversalId, uint256 amountUsd)
        external
        requiresAuth
        nonReentrant
    {
        if (amountUsd == 0) revert AmountZero();
        if (reversalConsumed[safe][reversalId]) revert ReversalAlreadyConsumed();

        BookedSpend memory record = booked[safe][txId];
        if (!record.exists) revert TransactionNotBooked();
        if (!record.isCredit) revert WrongMode();
        if (uint256(record.reversedUsd) + amountUsd > record.bookedUsd) revert ReversalExceedsBooked();

        _accrue();
        reversalConsumed[safe][reversalId] = true;
        booked[safe][txId].reversedUsd = _toU72(uint256(record.reversedUsd) + amountUsd);

        SafeConfig storage $ = _safeConfig[safe];
        _reduceDebt($, amountUsd);
        if (record.isForced) _reduceForcedDebt($, amountUsd);
        _refreshHealthStamp(safe, $);

        emit SpendReversed(safe, txId, reversalId, amountUsd);
    }

    // ========================================= LIQUIDATION =========================================

    /**
     * @notice Re-evaluates a Safe's liquidation grace stamp. Permissionless, moves no value.
     * @dev Replaces the `markUnhealthy` / `markHealthy` pair that used to sit here: both directions
     *      run through the one `_refreshHealthStamp`, so they cannot disagree, and — unlike the pair
     *      they replace — they refuse to stamp a position this module cannot fully price.
     *
     *      **Without this, a position that drifts unhealthy while idle can never be liquidated.**
     *      `_requireLiquidatable` rejects `unhealthySince == 0` before it looks at anything else —
     *      before even the `graceFloorHf` escape — and every other call site of
     *      `_refreshHealthStamp` sits inside a function that moves value. A Safe nobody touches
     *      therefore keeps a zero stamp no matter how far its health falls.
     *
     *      That gap is not theoretical once interest is on: debt grows continuously at
     *      `borrowApyPerSecond` with no user action at all, so idle Credit positions drift unhealthy
     *      on their own and would sit un-liquidatable, accruing bad debt, until something unrelated
     *      happened to touch them.
     *
     *      Permissionless on purpose, even though `liquidate` no longer is. The stamp starts a
     *      clock; it never authorises a seizure, and keeping it open means the grace period begins
     *      when the position actually went bad rather than when Solid got round to looking.
     *
     *      There is no griefing surface here, in either direction. The stamp is only SET when health
     *      is genuinely below 1 **and every held token is priced**, and only CLEARED when health is
     *      genuinely at or above 1, so a caller can neither manufacture a liquidation nor postpone
     *      one; the most an attacker achieves is paying gas to write a value the position had
     *      already earned.
     */
    function pokeHealth(address safe) external {
        _refreshHealthStamp(safe, _safeConfig[safe]);
    }

    /**
     * @notice Liquidates an unhealthy position: the caller retires debt and receives collateral plus
     *         a bonus. **Whitelisted callers only**, atomic, never blocked by any pause.
     * @dev Atomicity is the point — there is never a state where collateral left without repayment
     *      arriving.
     *
     *      **Why this is not permissionless.** A liquidation is the only path in this module that
     *      hands a user's escrowed collateral to an address other than that user or the immutable
     *      treasury, and its size is driven by debt — which `bookForcedSpend` can create without
     *      collateral backing it, because a mandatory card authorization has already happened and
     *      refusing to record it is worse than recording it. Those two facts together were a route:
     *      a compromised `CREDIT_SPENDER_ROLE` key books unbacked debt against any registered Safe,
     *      and then *the same actor* liquidates the position it just manufactured and walks away
     *      with the collateral plus `liquidationBonusBps`.
     *
     *      Closing that at the debt end would mean capping what one mandatory authorization may be,
     *      which the card flow cannot accept. So it is closed at the extraction end instead:
     *      `requiresAuth` restricts this to `LIQUIDATOR_ROLE`, granted to exactly one address —
     *      `SolidLiquidator`, which forwards every token it receives to `settlementTreasury` in the
     *      same transaction and is operated by a key that is deliberately neither spender key.
     *      Manufacturing a liquidation therefore requires two independent compromises, and even then
     *      the proceeds land in Solid's own treasury, where `reverseSpend` plus a refund make the
     *      user whole. There is no longer a sequence of calls that pays an attacker.
     *
     *      **What this gives up:** third-party liquidators. On Fuse none were expected, and Solid
     *      was always the realistic liquidator of last resort (see the deploy script's note on why
     *      `repayFromCollateral` is not granted to the backend). The cost is that a position with no
     *      one to liquidate it is Solid's problem, which it already was.
     *
     *      **The grace period, and the floor that makes it safe.** Solid holds the soUSD
     *      accountant's rate-update role, so Solid controls the collateral price of its own users'
     *      collateral, and a single wrong print must not cascade liquidations. Grace therefore
     *      applies in a shallow band below 1.0, where a bad print lands. Below `graceFloorHf` — where
     *      a real crash lands — liquidation is immediate, because thirty minutes of grace during a
     *      crash is thirty minutes of bad debt Solid absorbs.
     *
     *      **A position holding any unpriceable collateral cannot be liquidated at all.** Otherwise a
     *      dead feed on one asset would understate capacity, tank the reported health factor, and
     *      let a liquidator seize a *different*, perfectly healthy asset at a bonus.
     *
     *      **`liquidationsPaused` is the one thing that does block it,** and it exists because
     *      nothing else could. A price wrong in the LOW direction manufactures liquidations, and
     *      `setTokenPaused` is capacity-preserving precisely so a guardian action cannot manufacture
     *      them — which leaves it unable to stop one either. Tightening `minPriceUsd` is
     *      risk-increasing and waits out `paramChangeDelay`. Repay, deleverage and withdrawal all
     *      stay open while it is on, so a position can still be rescued rather than only frozen.
     * @param safe The position to liquidate
     * @param repayToken Token the liquidator pays with
     * @param repayAmountUsd USD of debt to retire, clamped by the close factor
     * @param collateralToken Collateral to seize
     */
    function liquidate(address safe, address repayToken, uint256 repayAmountUsd, address collateralToken)
        external
        requiresAuth
        nonReentrant
    {
        if (liquidationsPaused) revert LiquidationsArePaused();

        SafeConfig storage $ = _safeConfig[safe];
        _accrue();

        uint256 debt = _debtOf($);
        if (debt == 0) revert NoDebt();

        _requireLiquidatable(safe, $, debt);

        LiquidationSizing memory z = _sizeLiquidation(safe, repayToken, collateralToken, repayAmountUsd, debt);

        // State first, then value movement, so a token transfer hook cannot re-enter into a second
        // seizure priced off the pre-seizure position.
        _debitCollateral(safe, collateralToken, z.seized);
        _reduceDebt($, z.repaidUsd);

        IERC20(repayToken).safeTransferFrom(msg.sender, settlementTreasury, z.repayTokenAmount);
        IERC20(collateralToken).safeTransfer(msg.sender, z.seized);

        _refreshHealthStamp(safe, $);
        emit Liquidated(safe, msg.sender, collateralToken, z.repaidUsd, z.seized);
    }

    /**
     * @dev The eligibility half of `liquidate`, split out to keep both halves inside the EVM's
     *      addressable stack depth.
     *
     *      **A position holding any collateral this module cannot strictly price cannot be
     *      liquidated at all.** Otherwise one dead or out-of-band feed would understate capacity,
     *      drop the reported health factor, and let a liquidator seize a *different*, perfectly
     *      healthy asset at a bonus.
     *
     *      **The zero-stamp rejection is first, and deliberately absolute.** A Safe nobody has
     *      touched since it went unhealthy has `unhealthySince == 0` and is not liquidatable at any
     *      health factor, because the grace period it is owed has not started. `pokeHealth` is the
     *      permissionless way to start it; a liquidator calls that before this.
     */
    function _requireLiquidatable(address safe, SafeConfig storage $, uint256 debt) private view {
        (, uint256 capacity, bool fullyPriced) = _positionValue(safe);
        if (!fullyPriced) revert PositionNotFullyPriced();
        if (capacity >= debt) revert NotLiquidatable();

        uint64 stamp = $.unhealthySince;
        if (stamp == 0) revert LiquidationGraceNotElapsed();

        if (block.timestamp >= uint256(stamp) + _params.liquidationGracePeriod) return;

        // Grace protects against a single wrong rate print, which lands in a shallow band below 1.0.
        // A real crash blows through `graceFloorHf`, where waiting would only accrue bad debt — so
        // that case skips the wait.
        //
        // **Forced debt never takes that shortcut.** The shortcut reads a deep shortfall as evidence
        // of a market crash, and that inference only holds when debt moves because a price moved.
        // `bookForcedSpend` is the one path that creates debt with no price movement and no
        // collateral check, so a large forced booking looks exactly like a crash to this test and
        // would otherwise be seizable in the same block it was created. Making such a position wait
        // out the full grace period is what leaves room for the `ForcedSpendBooked` event to be seen
        // and `reverseSpend` to unwind it — and, for an honest mandatory charge, for the user to be
        // told and to repay.
        if ($.forcedDebtUsd == 0 && capacity.mulDiv(WAD, debt, Math.Rounding.Floor) < _params.graceFloorHf) return;

        revert LiquidationGraceNotElapsed();
    }

    /// @dev Reads and validates every input the arithmetic needs, then hands off to the library.
    function _sizeLiquidation(
        address safe,
        address repayToken,
        address collateralToken,
        uint256 repayAmountUsd,
        uint256 debt
    ) private view returns (LiquidationSizing memory) {
        TokenConfig storage cCfg = _tokenConfig[collateralToken];
        if (cCfg.tokenDecimals == 0) revert TokenNotAllowed();
        TokenConfig storage rCfg = _tokenConfig[repayToken];
        if (rCfg.tokenDecimals == 0) revert TokenNotAllowed();
        // The collateral leg deliberately ignores the pause — a paused token still counts toward
        // capacity, and refusing to seize it would trap the position. The REPAY leg is the opposite
        // case: accepting a token the guardian has just declared suspect, at its suspect price, is
        // a pure loss with no user-protection argument on the other side.
        if (tokenPaused[repayToken]) revert TokenIsPaused();

        return SolidCreditMathLib.sizeLiquidation(
            LiquidationInput({
                debt: debt,
                requestedUsd: repayAmountUsd,
                // A dust position is fully clearable in one call, so it never becomes permanently
                // unprofitable to liquidate and strand as bad debt.
                closeBps: debt <= _params.minPositionUsd ? MAX_BPS : _params.closeFactorBps,
                // Strict, never capped: a capped (understated) collateral price would hand the
                // liquidator more tokens for the same dollar figure, out of the borrower's position.
                cPrice: _settlementPrice(collateralToken, cCfg),
                cUnit: 10 ** cCfg.tokenDecimals,
                bonusNum: uint256(MAX_BPS) + cCfg.liquidationBonusBps,
                available: collateralOf[safe][collateralToken],
                rPrice: _settlementPrice(repayToken, rCfg),
                rUnit: 10 ** rCfg.tokenDecimals
            })
        );
    }

    // ========================================= SAFE-OWNER ACTIONS =========================================

    /**
     * @notice Opts a Safe into card spending. Must be called **by the Safe itself**.
     * @dev Safe 1.4.1 has no module-setup callback, so onboarding is a batched owner-signed user
     *      operation. Because `msg.sender` is the Safe, owner consent is structural rather than
     *      something this contract has to verify.
     *
     *      The v1 assert is what makes migration atomic-or-nothing: the batch must disable v1 in the
     *      same transaction, so a Safe can never end up registered on both modules with two
     *      independent cap sets.
     */
    function registerSafe(uint256 dailyLimitUsd, uint256 monthlyLimitUsd, int256 timezoneOffset) external {
        SafeConfig storage $ = _safeConfig[msg.sender];
        if ($.registered) revert AlreadyRegistered();

        // The treasury receives every settlement, so letting it register would make the
        // balance-delta check in `_settleDebitToken` trivially satisfiable.
        if (msg.sender == settlementTreasury) revert TreasuryCannotRegister();
        if (!ISafe(msg.sender).isModuleEnabled(address(this))) revert ModuleNotEnabled();
        if (ISafe(msg.sender).isModuleEnabled(v1Module)) revert LegacyModuleStillEnabled();

        if (dailyLimitUsd == 0) dailyLimitUsd = _params.defaultDailyLimitUsd;
        if (monthlyLimitUsd == 0) monthlyLimitUsd = _params.defaultMonthlyLimitUsd;
        if (dailyLimitUsd > _params.maxDailyLimitUsd) revert ExceedsOrgDailyCeiling();
        if (monthlyLimitUsd > _params.maxMonthlyLimitUsd) revert ExceedsOrgMonthlyCeiling();

        $.registered = true;
        $.mode = Mode.Debit;

        // A Safe that has been here before keeps what it has already spent, and re-registering
        // clamps down to the cap it left with rather than seeding a new one. Otherwise deregister
        // plus register is a fresh daily window and an instant jump to the org ceiling, which is
        // exactly what `limitRaiseDelay` exists to prevent.
        _safeLimit[msg.sender].seedForRegistration(dailyLimitUsd, monthlyLimitUsd, timezoneOffset);

        emit SafeRegistered(msg.sender, dailyLimitUsd, monthlyLimitUsd, timezoneOffset);
    }

    /**
     * @notice Clears a leaving Safe's state. Must be called by the Safe, at zero debt and zero escrow.
     * @dev v1 had no deregister, so a Safe that registered could never clean up. Refusing while debt
     *      or collateral remains is what stops it being an exit from an obligation.
     *
     *      It deliberately does not clear `_safeLimit`. The rolling window is what a returning Safe
     *      must not be able to wipe, so it is the one piece of per-Safe state that survives.
     */
    function deregisterSafe() external {
        SafeConfig storage $ = _safeConfig[msg.sender];
        if (!$.registered) revert NotRegistered();
        if ($.normalizedDebt != 0) revert HasDebt();

        uint256 length = _allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            if (collateralOf[msg.sender][_allowedTokens[i]] != 0) revert TokenStillEscrowed();
        }

        delete _safeConfig[msg.sender];
        delete _pendingWithdrawal[msg.sender];

        emit SafeDeregistered(msg.sender);
    }

    /**
     * @notice Switches the calling Safe's funding mode.
     * @dev Asymmetric, matching every other risk-direction decision in this contract: a switch that
     *      LOWERS `_modeRank` is de-risking and immediate, one that RAISES it widens what a
     *      compromised spender key could do and is therefore delayed — with the delay doubling as
     *      the window to cancel a switch the user did not intend.
     *
     *      That rule is the generalisation of the original "into `Debit` immediate, into `Credit`
     *      delayed", and reproduces it exactly. With `Smart` in the enum it also gives:
     *
     *        Debit  -> Smart   delayed   (gains the credit path)
     *        Credit -> Smart   delayed   (gains the ability to sell the loose balance)
     *        Smart  -> Debit   immediate (strictly narrower)
     *        Smart  -> Credit  immediate (strictly narrower)
     *
     *      Cancelling is that same call with the mode you are currently in: `setMode(Debit)` while a
     *      switch to `Credit` is armed disarms it, immediately, like every other de-risking action
     *      here. Re-arming restarts the delay from scratch, and re-arming with a DIFFERENT
     *      higher-ranked mode overwrites the pending one at a fresh full delay rather than
     *      inheriting the elapsed part of the old one.
     */
    function setMode(Mode mode) external onlyRegisteredSafe {
        SafeConfig storage $ = _safeConfig[msg.sender];

        // Cancelling an armed switch. `_currentMode` still reports the STORED mode until the switch
        // matures, so asking for the mode you are already in used to be the one call that reverted —
        // which left the documented cancellation window with nothing in it.
        uint64 armedAt = $.incomingModeStartTime;
        if (armedAt != 0 && block.timestamp < armedAt && mode == $.mode) {
            emit ModeSet(msg.sender, $.incomingMode, mode, uint64(block.timestamp));
            $.incomingMode = mode;
            $.incomingModeStartTime = 0;
            return;
        }

        Mode from = _currentMode($);
        if (mode == from) revert InvalidInput();

        _settleMode($);

        // Down-rank is de-risking and immediate; up-rank widens the blast radius and waits.
        // `mode == from` already reverted above, so this is a strict comparison.
        if (_modeRank(mode) < _modeRank(from)) {
            $.mode = mode;
            $.incomingMode = mode;
            $.incomingModeStartTime = 0;
            emit ModeSet(msg.sender, from, mode, uint64(block.timestamp));
        } else {
            uint64 effectiveAt = uint64(block.timestamp) + _params.modeDelay;
            $.incomingMode = mode;
            $.incomingModeStartTime = effectiveAt;
            emit ModeSet(msg.sender, from, mode, effectiveAt);
        }
    }

    /**
     * @notice Withdraws collateral immediately. Only valid at zero debt.
     * @dev **Requires no price at all**, which is the escape hatch that stops an oracle outage from
     *      ever trapping a debt-free user's collateral. Never blocked by any pause, and works even
     *      after the user has revoked this module on their Safe.
     */
    function withdrawCollateral(address token, uint256 amount) external nonReentrant {
        SafeConfig storage $ = _safeConfig[msg.sender];
        _accrue();
        if ($.normalizedDebt != 0) revert HasDebt();
        if (amount == 0) revert AmountZero();

        uint256 available = collateralOf[msg.sender][token];
        if (amount > available) amount = available;
        if (amount == 0) revert AmountZero();

        _debitCollateral(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /**
     * @notice Arms a collateral withdrawal for a Safe that still carries debt.
     * @dev The delay's only job is stopping a withdrawal of already-escrowed collateral from racing
     *      an in-flight `spendCredit` that counted it — a window of seconds, not the days an
     *      authorize-to-settle window would need. One armed request per Safe.
     */
    function requestCollateralWithdrawal(address token, uint256 amount) external onlyRegisteredSafe {
        if (amount == 0) revert AmountZero();
        if (amount > collateralOf[msg.sender][token]) revert InvalidInput();
        if (_pendingWithdrawal[msg.sender].readyAt != 0) revert WithdrawalPending();

        uint64 readyAt = uint64(block.timestamp) + _params.collateralWithdrawDelay;
        _pendingWithdrawal[msg.sender] = PendingWithdrawal(token, readyAt, amount);

        emit CollateralWithdrawRequested(msg.sender, token, amount, readyAt);
    }

    /// @notice Disarms an armed withdrawal.
    function cancelCollateralWithdrawal() external {
        if (_pendingWithdrawal[msg.sender].readyAt == 0) revert NoPendingWithdrawal();
        delete _pendingWithdrawal[msg.sender];
        emit CollateralWithdrawCancelled(msg.sender);
    }

    /**
     * @notice Executes a matured withdrawal. Permissionless once ready.
     * @dev The LTV bound is re-checked **after** the release rather than at request time, because
     *      debt and prices both move in between. Withdrawal is gated on LTV, never on having zero
     *      debt: a partially drawn position can always pull its excess.
     */
    function processCollateralWithdrawal(address safe) external nonReentrant {
        PendingWithdrawal memory req = _pendingWithdrawal[safe];
        if (req.readyAt == 0) revert NoPendingWithdrawal();
        if (block.timestamp < req.readyAt) revert WithdrawalNotReady();

        _accrue();
        delete _pendingWithdrawal[safe];

        uint256 available = collateralOf[safe][req.token];
        uint256 amount = req.amount > available ? available : req.amount;
        if (amount == 0) revert AmountZero();

        _debitCollateral(safe, req.token, amount);
        IERC20(req.token).safeTransfer(safe, amount);

        SafeConfig storage $ = _safeConfig[safe];
        uint256 debt = _debtOf($);
        if (debt != 0) {
            (uint256 power,,) = _positionValue(safe);
            if (debt > power) revert ExceedsBorrowingPower();
        }

        _refreshHealthStamp(safe, $);
        emit CollateralWithdrawn(safe, req.token, amount);
    }

    /// @notice Lowers the caller Safe's caps, effective immediately. Cancels any pending increase.
    function decreaseSpendingLimit(uint256 dailyLimitUsd, uint256 monthlyLimitUsd) external onlyRegisteredSafe {
        _safeLimit[msg.sender].decrease(dailyLimitUsd, monthlyLimitUsd);
        emit SpendingLimitDecreased(msg.sender, dailyLimitUsd, monthlyLimitUsd);
    }

    /// @notice Requests higher caps, effective after `limitRaiseDelay`.
    function requestSpendingLimitIncrease(uint256 dailyLimitUsd, uint256 monthlyLimitUsd) external onlyRegisteredSafe {
        if (dailyLimitUsd > _params.maxDailyLimitUsd) revert ExceedsOrgDailyCeiling();
        if (monthlyLimitUsd > _params.maxMonthlyLimitUsd) revert ExceedsOrgMonthlyCeiling();

        uint64 delay = _params.limitRaiseDelay;
        _safeLimit[msg.sender].requestIncrease(dailyLimitUsd, monthlyLimitUsd, delay);

        emit SpendingLimitIncreaseRequested(msg.sender, dailyLimitUsd, monthlyLimitUsd, uint64(block.timestamp) + delay);
    }

    /// @notice Disarms a pending limit increase.
    function cancelPendingSpendingLimitIncrease() external onlyRegisteredSafe {
        _safeLimit[msg.sender].cancelPendingIncrease();
        emit SpendingLimitIncreaseCancelled(msg.sender);
    }

    // ========================================= VIEWS =========================================

    /**
     * @notice Whether this module is enabled on `safe`, reported as `false` for any address that
     *         cannot answer the question.
     * @dev Deliberately a raw `staticcall` rather than `try/catch`. Solidity's `try/catch` catches
     *      reverts but not failures decoding the *return data*, so a call to an address with no code
     *      — which succeeds and returns nothing — propagates a decode revert straight past the
     *      `catch`. Solid Safes are ERC-4337 accounts that may be counterfactual, so this is a live
     *      case, and reverting here would take down the lens' single authorize read instead of
     *      producing a clean decline.
     *
     *      The write paths intentionally do not use this: there, an unanswerable Safe must abort
     *      rather than be silently treated as revoked.
     */
    function isModuleEnabledOn(address safe) public view returns (bool) {
        return SolidCashConfigLib.tolerantIsModuleEnabled(safe, address(this));
    }

    /// @notice Whether v1 is still enabled on `safe`, tolerant of an unanswerable address.
    function isLegacyEnabledOn(address safe) public view returns (bool) {
        return SolidCashConfigLib.tolerantIsModuleEnabled(safe, v1Module);
    }

    /**
     * @notice The buffered LTV `spendCredit` sizes collateral at, for one token.
     * @dev Exposed so the lens can quote prospective collateral at exactly the ratio execution will
     *      lock at — a quote computed against the raw `ltv` would advertise more power than
     *      `_lockOne` would actually back.
     */
    function effectiveTargetLtv(address token) external view returns (uint256) {
        return uint256(_tokenConfig[token].ltv).mulDiv(_params.targetLtvBps, MAX_BPS, Math.Rounding.Floor);
    }

    function getPendingWithdrawal(address safe) external view returns (PendingWithdrawal memory) {
        return _pendingWithdrawal[safe];
    }

    function allowedTokens() external view returns (address[] memory) {
        return _allowedTokens;
    }

    function isRegistered(address safe) external view returns (bool) {
        return _safeConfig[safe].registered;
    }

    function forcedDebtUsd(address safe) external view returns (uint256) {
        return _safeConfig[safe].forcedDebtUsd;
    }

    function incomingModeStartTime(address safe) external view returns (uint64) {
        return _safeConfig[safe].incomingModeStartTime;
    }

    function unhealthySince(address safe) external view returns (uint64) {
        return _safeConfig[safe].unhealthySince;
    }

    /// @notice The Safe's effective mode, honouring a matured pending switch.
    function getMode(address safe) public view returns (Mode) {
        return _currentMode(_safeConfig[safe]);
    }

    /**
     * @notice The mode a Safe has armed a switch to, or its current mode when none is armed.
     * @dev Exists because `incomingModeStartTime` alone tells a client WHEN a switch matures but not
     *      what it matures INTO — so a user who armed a switch could be shown a countdown to an
     *      unnamed mode. Every armed switch is an up-rank by construction, but with three modes that
     *      is no longer enough to infer the target.
     */
    function getIncomingMode(address safe) external view returns (Mode) {
        SafeConfig storage $ = _safeConfig[safe];
        return $.incomingModeStartTime == 0 ? $.mode : $.incomingMode;
    }

    /**
     * @notice The price this module would use for `token`, and whether it is acceptable.
     * @dev Reports what the write path would actually do, not merely what the provider thinks: the
     *      provider's answer is capped at the module's own ceiling and rejected below its own floor,
     *      and the module's own staleness bound is applied on top of the provider's.
     * @return price The price quoting uses: capped at this module's ceiling. Zero when unusable
     * @return usable False when the feed is down, stale by this module's bound, or below the floor
     * @return inBand False when the provider's price exceeded this module's ceiling, in which case
     *         every value-moving path refuses while quoting continues on the capped figure
     */
    function getPriceUsd(address token) public view returns (uint256 price, bool usable, bool inBand) {
        return _price(token, _tokenConfig[token]);
    }

    /**
     * @notice A Safe's position, valued by this module's own rules.
     * @return powerUsd Borrowing power: collateral eligible for NEW debt, weighted by each token's ltv
     * @return capacityUsd Liquidation capacity: ALL escrowed collateral, weighted by each threshold
     * @return fullyPriced False when any token with a non-zero escrowed balance cannot be priced
     */
    function positionValue(address safe)
        public
        view
        returns (uint256 powerUsd, uint256 capacityUsd, bool fullyPriced)
    {
        return _positionValue(safe);
    }

    /**
     * @notice WAD health factor. `type(uint256).max` when the Safe carries no debt.
     * @dev Reads low rather than failing when a held token cannot be priced, because an unpriced
     *      token is dropped from capacity. Use `positionValue`'s `fullyPriced` to tell an
     *      underwater position from an unreadable one — the liquidation path and the health stamp
     *      both do.
     */
    function healthFactor(address safe) public view returns (uint256) {
        (uint256 hf,) = _healthFactor(safe, _safeConfig[safe]);
        return hf;
    }

    /// @notice Remaining headroom under the Safe's caps and the live org ceilings.
    function maxCanSpendUsd(address safe) public view returns (uint256) {
        return _maxCanSpendUsd(safe);
    }

    // ========================================= SETTERS DISPATCH =========================================

    /**
     * @notice Points the core at its configuration implementation.
     * @dev **This is the one selector that must never be grantable.** The fallback `delegatecall`s
     *      into whatever this names, with this contract's storage and its escrowed collateral, so
     *      the ability to set it is the ability to replace the module — in a contract whose header
     *      states it is deliberately not upgradeable. Under `requiresAuth` that ability was a
     *      property of the external authority's configuration rather than of this contract, and the
     *      role map did not even list it. So it is checked against `owner` directly.
     *
     *      The equality checks keep an honestly-constructed implementation from weakening the
     *      core's invariants: one built with a different treasury or legacy module would read its
     *      own immutables during `delegatecall` and could reintroduce a parameterised destination.
     *      They are not a defence against a hostile implementation — anything can return two
     *      addresses — which is what `sealSetters` is for.
     */
    function setSettersImpl(address impl) external {
        _requireOwner();
        if (settersSealed) revert SettersAreSealed();
        if (impl == address(0)) revert InvalidInput();
        // Self-reference would make the fallback delegatecall into itself, forever.
        if (impl == address(this)) revert InvalidInput();
        if (SolidCashStorageV2(impl).settlementTreasury() != settlementTreasury) revert InvalidInput();
        if (SolidCashStorageV2(impl).v1Module() != v1Module) revert InvalidInput();
        settersImpl = impl;
        emit SettersImplSet(impl);
    }

    /**
     * @notice Closes the upgrade hatch permanently. One way, owner only.
     * @dev Deployment step 6b, and the point at which "non-upgradeable, deliberately" becomes true
     *      rather than aspirational. The split exists to fit EIP-170, not because the configuration
     *      half is expected to change; a mechanics change was always going to be a new deployment
     *      plus the documented migration, and this makes that the only option.
     */
    function sealSetters() external {
        _requireOwner();
        if (settersImpl == address(0)) revert InvalidInput();
        settersSealed = true;
        emit SettersSealed();
    }

    /**
     * @dev Forwards anything the core does not implement to the configuration half.
     *
     *      Deliberately `delegatecall`: the setters must operate on this contract's storage, and
     *      `msg.sender` must survive so `requiresAuth` over there gates the real caller. A missing
     *      implementation address reverts rather than silently succeeding, which matters because a
     *      no-op configuration call would look like it had applied.
     */
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address impl = settersImpl;
        if (impl == address(0)) revert InvalidInput();

        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
