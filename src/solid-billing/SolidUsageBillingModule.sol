// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {IPausable} from "src/interfaces/IPausable.sol";
import {IRateProvider} from "src/interfaces/IRateProvider.sol";
import {ISafe} from "src/solid-rewards/interfaces/ISafe.sol";

/**
 * @title SolidUsageBillingModule
 * @notice A Safe module that collects metered usage, priced in dollars, from a
 *         short list of tokens the Safe holds — and nothing else.
 *
 * Built for the AI API: usage is charged from the user's Wallet as it accrues,
 * a few dollars at a time, under a dollar cap per day the user signs. It is
 * `SolidSubscriptionModule` with the four things that contract could not do
 * for that job, and every other bound it enforces kept as it was.
 *
 * ## What is different from `SolidSubscriptionModule`
 *
 *  - **The mandate is in dollars, not in one token.** Amounts are micro-USD
 *    (6 decimals). A charge is drawn from the billing tokens in order — idle
 *    USDC first, then soUSD — the way a card spend is, so a user is not asked
 *    to keep one particular asset topped up.
 *  - **The token list is the owner's, not fixed at deployment.** Adding soUSD,
 *    or anything after it, is a `setBillingTokens` call. No redeploy, and no
 *    user signs again: their consent is to a dollar cap, which still binds.
 *  - **The shortest period is a constructor argument.** The subscription
 *    module hard-codes seven days, which is right for an annual fee and makes
 *    a daily cap impossible. Here the deployment picks it, once.
 *  - **Many charges per period, capped in total.** The subscription module
 *    takes at most one charge a period. Here the biller may charge as often as
 *    it likes while the period's total stays within the mandate, so usage is
 *    collected every few dollars instead of a day at a time — which keeps what
 *    Solid has fronted upstream, and could lose to a Wallet emptied before the
 *    charge, to a few dollars instead of a day.
 *
 * ## What is the same, and enforced here rather than by the backend
 *
 *  - **The destination is immutable.** `revenueTreasury` has no setter.
 *  - **The user sets their own ceiling.** `subscribe` is callable only by the
 *    Safe, and its mandate caps what all charges in one period add up to.
 *  - **Each charge once.** A `billingId` clears once, so a retry after an
 *    unseen receipt cannot bill twice.
 *  - **Settlement is measured.** Every token drawn must arrive at the treasury
 *    in full, or the whole charge reverts.
 *  - **Consent is withdrawable at any time**, by `cancel()` here or
 *    `disableModule` on the Safe.
 *
 * ## The trust the owner holds, stated plainly
 *
 * The owner chooses which tokens a charge may be drawn from and what each is
 * worth. A rate provider that under-prices a token makes the user pay more
 * units of it than the dollars they owe; one that over-prices it pays the
 * treasury less than the dollars charged. Three things bound that: the owner is
 * the multisig, every change emits an event, and the dollar amount of a charge
 * — the number the user's mandate caps — is not the owner's to change.
 */
contract SolidUsageBillingModule is Auth, IPausable {
    // ========================================= CONSTANTS =========================================

    /// @notice Lowest `minPeriod` a deployment may choose: a day, so a cap can
    ///         never refill more than once a day, whatever a deployment sets.
    uint64 public constant MIN_PERIOD_FLOOR = 1 days;

    /// @notice Longest billing period a mandate may carry.
    uint64 public constant MAX_PERIOD = 1460 days;

    /// @notice Most tokens a charge may be drawn from. Bounds the gas of `charge`.
    uint256 public constant MAX_BILLING_TOKENS = 8;

    /// @notice Decimals of every dollar amount here: mandates, charges and rates.
    uint8 public constant USD_DECIMALS = 6;

    // ========================================= IMMUTABLES =========================================

    /// @notice The only address this module can move anything to.
    address public immutable revenueTreasury;

    /**
     * @notice Shortest period a mandate's cap may apply to.
     *
     * Fixed at deployment so no later change can shorten the window a signed
     * cap applies over. The cap binds each period, which starts at the first
     * charge after the last one ended — not every rolling window — so charges
     * either side of that boundary can together reach twice the cap.
     */
    uint64 public immutable minPeriod;

    // ========================================= STATE =========================================

    /**
     * @notice A token a charge may be drawn from, and how it is priced.
     *
     * `rateProvider` answers `getRate()`: the dollar value, in micro-USD, of one
     * whole token (`10 ** decimals` units). The zero address means the token is
     * a dollar at par, which is what USDC is billed at. A BoringVault share
     * such as soUSD names its accountant, whose `getRate()` is exactly that.
     */
    struct BillingToken {
        address token;
        address rateProvider;
        uint8 decimals;
    }

    /**
     * @notice One user's standing permission to be billed.
     *
     * A period starts at the first charge after the previous one ran out, and
     * everything charged until it ends counts against `maxAmountPerPeriod`.
     */
    struct Subscription {
        bool registered;
        /// @notice Per-Safe stop, for a dispute or a fraud hold. Admin-set.
        bool paused;
        /// @notice Most all charges in one period may add up to, in micro-USD.
        uint128 maxAmountPerPeriod;
        /// @notice How long one period lasts.
        uint64 periodSeconds;
        uint64 subscribedAt;
        uint64 lastChargedAt;
        /// @notice Non-zero once the user has stopped the mandate.
        uint64 cancelledAt;
        /// @notice When the current period began. Zero before the first charge.
        uint64 periodStartedAt;
        /// @notice What the current period has taken so far, in micro-USD.
        uint128 chargedInPeriod;
    }

    /// @notice One token's part of a charge.
    struct Draw {
        address token;
        /// @notice Token units moved.
        uint256 units;
        /// @notice Dollars those units settle, in micro-USD.
        uint256 amount;
    }

    /// @notice The tokens a charge is drawn from, in the order it draws them.
    BillingToken[] internal billingTokens;

    mapping(address => Subscription) internal subscriptions;

    /// @notice Charges already taken, per Safe. Makes a retry safe.
    mapping(address => mapping(bytes32 => bool)) public chargeCleared;

    /**
     * @notice Org-wide ceiling on one charge, in micro-USD.
     *
     * A second bound above the user's own. Lowering it binds existing mandates
     * immediately, which is what makes it a live throttle.
     */
    uint128 public maxChargeAmount;

    /// @notice Global stop. No charge clears while true.
    bool public isPaused;

    //============================== ERRORS ===============================

    error SolidUsageBillingModule__Paused();
    error SolidUsageBillingModule__SafePaused(address safe);
    error SolidUsageBillingModule__NotRegistered(address safe);
    error SolidUsageBillingModule__AlreadyCancelled(address safe);
    error SolidUsageBillingModule__NotCancelled(address safe);
    error SolidUsageBillingModule__Cancelled(address safe);
    error SolidUsageBillingModule__ModuleNotEnabled(address safe);
    error SolidUsageBillingModule__ZeroAmount();
    error SolidUsageBillingModule__ExceedsMandate(uint256 amount, uint128 mandate);
    error SolidUsageBillingModule__ExceedsOrgCeiling(uint256 amount, uint128 ceiling);
    error SolidUsageBillingModule__PeriodOutOfRange(uint64 period);
    /// @notice The period has no room left for this amount until `periodEndsAt`.
    error SolidUsageBillingModule__TooSoon(uint64 periodEndsAt);
    error SolidUsageBillingModule__AlreadyCharged(address safe, bytes32 billingId);
    error SolidUsageBillingModule__InsufficientBalance(uint256 amount, uint256 available);
    error SolidUsageBillingModule__TransferFailed(address safe, address token);
    error SolidUsageBillingModule__NotSettled(address token, uint256 expected, uint256 received);
    error SolidUsageBillingModule__InvalidAddress();
    error SolidUsageBillingModule__InvalidMinPeriod(uint64 minPeriod);
    error SolidUsageBillingModule__TooManyTokens(uint256 count);
    error SolidUsageBillingModule__DuplicateToken(address token);
    error SolidUsageBillingModule__InvalidToken(address token);
    error SolidUsageBillingModule__InvalidRateProvider(address token, address rateProvider);
    error SolidUsageBillingModule__LengthMismatch();

    //============================== EVENTS ===============================

    event Subscribed(address indexed safe, uint128 maxAmountPerPeriod, uint64 periodSeconds);
    event MandateChanged(address indexed safe, uint128 maxAmountPerPeriod, uint64 periodSeconds);
    event Cancelled(address indexed safe);
    event Resumed(address indexed safe);
    /// @notice One per token a charge drew from, before the charge's own event.
    event Drawn(address indexed safe, bytes32 indexed billingId, address indexed token, uint256 units, uint256 amount);
    event Charged(address indexed safe, bytes32 indexed billingId, uint256 amount, uint64 chargedAt);
    event BillingTokensSet(address[] tokens, address[] rateProviders);
    event MaxChargeAmountSet(uint128 maxChargeAmount);
    event SafePauseSet(address indexed safe, bool paused);
    event Paused();
    event Unpaused();

    //============================== CONSTRUCTOR ===============================

    constructor(
        address _owner,
        address _revenueTreasury,
        uint128 _maxChargeAmount,
        uint64 _minPeriod,
        address[] memory _tokens,
        address[] memory _rateProviders
    ) Auth(_owner, Authority(address(0))) {
        // The treasury can never be changed, so a zero value here is unfixable
        // rather than inconvenient.
        if (_owner == address(0) || _revenueTreasury == address(0)) {
            revert SolidUsageBillingModule__InvalidAddress();
        }
        if (_minPeriod < MIN_PERIOD_FLOOR || _minPeriod > MAX_PERIOD) {
            revert SolidUsageBillingModule__InvalidMinPeriod(_minPeriod);
        }

        revenueTreasury = _revenueTreasury;
        minPeriod = _minPeriod;
        maxChargeAmount = _maxChargeAmount;
        emit MaxChargeAmountSet(_maxChargeAmount);

        _setBillingTokens(_tokens, _rateProviders);
    }

    //============================== USER FUNCTIONS ===============================

    /**
     * @notice Agree to be billed up to `maxAmountPerPeriod` micro-USD in total
     *         in any one period of `periodSeconds`.
     *
     * `msg.sender` is the Safe, so the only way here is a transaction the user's
     * own account executes — batched with the `enableModule` that makes the
     * module usable at all, so one signature both grants and bounds it.
     *
     * Calling it again re-states the mandate (a raise is a new signature, which
     * is the point) and un-cancels. What the current period has already taken
     * survives, so re-subscribing never makes room the user did not sign for.
     */
    function subscribe(uint128 maxAmountPerPeriod, uint64 periodSeconds) external {
        if (maxAmountPerPeriod == 0) revert SolidUsageBillingModule__ZeroAmount();
        if (maxAmountPerPeriod > maxChargeAmount) {
            revert SolidUsageBillingModule__ExceedsOrgCeiling(maxAmountPerPeriod, maxChargeAmount);
        }
        if (periodSeconds < minPeriod || periodSeconds > MAX_PERIOD) {
            revert SolidUsageBillingModule__PeriodOutOfRange(periodSeconds);
        }

        Subscription storage subscription = subscriptions[msg.sender];
        bool isNew = !subscription.registered;

        subscription.registered = true;
        subscription.maxAmountPerPeriod = maxAmountPerPeriod;
        subscription.periodSeconds = periodSeconds;
        subscription.cancelledAt = 0;
        if (isNew) subscription.subscribedAt = uint64(block.timestamp);

        if (isNew) {
            emit Subscribed(msg.sender, maxAmountPerPeriod, periodSeconds);
        } else {
            emit MandateChanged(msg.sender, maxAmountPerPeriod, periodSeconds);
        }
    }

    /// @notice Stop the mandate. No charge clears until the user subscribes again.
    function cancel() external {
        Subscription storage subscription = subscriptions[msg.sender];
        if (!subscription.registered) revert SolidUsageBillingModule__NotRegistered(msg.sender);
        if (subscription.cancelledAt != 0) revert SolidUsageBillingModule__AlreadyCancelled(msg.sender);

        subscription.cancelledAt = uint64(block.timestamp);
        emit Cancelled(msg.sender);
    }

    /// @notice Restart a cancelled mandate on its existing terms.
    function resume() external {
        Subscription storage subscription = subscriptions[msg.sender];
        if (!subscription.registered) revert SolidUsageBillingModule__NotRegistered(msg.sender);
        if (subscription.cancelledAt == 0) revert SolidUsageBillingModule__NotCancelled(msg.sender);
        if (subscription.maxAmountPerPeriod > maxChargeAmount) {
            revert SolidUsageBillingModule__ExceedsOrgCeiling(subscription.maxAmountPerPeriod, maxChargeAmount);
        }

        subscription.cancelledAt = 0;
        emit Resumed(msg.sender);
    }

    //============================== BILLER FUNCTIONS ===============================

    /**
     * @notice Take one charge of `amount` micro-USD from `safe`.
     *
     * Restricted to the biller role, which chooses only the Safe and the dollar
     * amount. Where the money goes, which tokens it may come from and at what
     * price, and how much the period may take in total are all fixed by this
     * contract and by the user's own mandate. Charging often is the point: it
     * keeps what is owed but not yet collected small.
     *
     * Drawn from the billing tokens in order, each one in full before the next,
     * until the amount is covered. If everything the Safe holds of them cannot
     * cover it, nothing moves.
     *
     * `billingId` is the caller's idempotency key and should identify what is
     * being billed, not the attempt, so a retry after an unseen receipt lands on
     * `AlreadyCharged` instead of billing twice.
     */
    function charge(address safe, bytes32 billingId, uint256 amount) external requiresAuth {
        if (isPaused) revert SolidUsageBillingModule__Paused();
        if (amount == 0) revert SolidUsageBillingModule__ZeroAmount();
        if (chargeCleared[safe][billingId]) revert SolidUsageBillingModule__AlreadyCharged(safe, billingId);

        Subscription storage subscription = subscriptions[safe];
        if (!subscription.registered) revert SolidUsageBillingModule__NotRegistered(safe);
        if (subscription.paused) revert SolidUsageBillingModule__SafePaused(safe);
        if (subscription.cancelledAt != 0) revert SolidUsageBillingModule__Cancelled(safe);
        if (amount > subscription.maxAmountPerPeriod) {
            revert SolidUsageBillingModule__ExceedsMandate(amount, subscription.maxAmountPerPeriod);
        }
        if (amount > maxChargeAmount) revert SolidUsageBillingModule__ExceedsOrgCeiling(amount, maxChargeAmount);

        (uint64 startedAt, uint256 charged) = _period(subscription);
        if (charged + amount > subscription.maxAmountPerPeriod) {
            revert SolidUsageBillingModule__TooSoon(startedAt + subscription.periodSeconds);
        }

        if (!isModuleEnabledOn(safe)) revert SolidUsageBillingModule__ModuleNotEnabled(safe);

        (Draw[] memory draws, uint256 drawn) = _plan(safe, amount);
        if (drawn < amount) revert SolidUsageBillingModule__InsufficientBalance(amount, drawn);

        // Written before any external call. A token with a transfer hook that
        // re-entered would find the id already spent and the period's room
        // already taken, so there is no second charge to be had.
        chargeCleared[safe][billingId] = true;
        subscription.periodStartedAt = startedAt;
        // At most `maxAmountPerPeriod`, a uint128, by the check above.
        subscription.chargedInPeriod = uint128(charged + amount);
        subscription.lastChargedAt = uint64(block.timestamp);

        for (uint256 i = 0; i < draws.length; ++i) {
            if (draws[i].units == 0) break;
            _pull(safe, draws[i].token, draws[i].units);
            emit Drawn(safe, billingId, draws[i].token, draws[i].units, draws[i].amount);
        }

        emit Charged(safe, billingId, amount, uint64(block.timestamp));
    }

    //============================== VIEW FUNCTIONS ===============================

    /// @notice The stored mandate for `safe`.
    function subscriptionOf(address safe) external view returns (Subscription memory) {
        return subscriptions[safe];
    }

    /// @notice The tokens a charge is drawn from, in draw order.
    function billingTokensList() external view returns (BillingToken[] memory) {
        return billingTokens;
    }

    /// @notice Whether `safe` still has this module enabled. False if it cannot answer.
    function isModuleEnabledOn(address safe) public view returns (bool enabled) {
        if (safe.code.length == 0) return false;

        try ISafe(safe).isModuleEnabled(address(this)) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    /**
     * @notice What `safe`'s mandate still lets the current period take, in
     *         micro-USD, and when that period ends.
     *
     * `periodEndsAt` is zero when no period is running: the next charge starts
     * one, with the whole mandate available. The org ceiling, the pauses and
     * the Wallet's balance are not counted here; `canCharge` checks them all.
     */
    function allowanceOf(address safe) external view returns (uint256 remaining, uint64 periodEndsAt) {
        Subscription storage subscription = subscriptions[safe];
        (uint64 startedAt, uint256 charged) = _period(subscription);
        remaining = charged >= subscription.maxAmountPerPeriod ? 0 : subscription.maxAmountPerPeriod - charged;
        if (charged > 0) periodEndsAt = startedAt + subscription.periodSeconds;
    }

    /**
     * @notice What everything `safe` holds of the billing tokens is worth, in
     *         micro-USD — the most one charge could take from it right now.
     *
     * A token whose rate cannot be read counts as worth nothing, rather than
     * stopping the whole read: the user can still be charged from the rest.
     */
    function billableBalanceOf(address safe) external view returns (uint256 total) {
        uint256 count = billingTokens.length;
        for (uint256 i = 0; i < count; ++i) {
            BillingToken memory billingToken = billingTokens[i];
            (bool ok, uint256 rate) = _rate(billingToken);
            if (!ok) continue;
            total += _valueOf(ERC20(billingToken.token).balanceOf(safe), rate, billingToken.decimals);
        }
    }

    /**
     * @notice The draw a charge of `amount` would make from `safe` now: which
     *         tokens, how many units of each, and what each settles.
     *
     * `drawn` short of `amount` is the shortfall a charge would revert on.
     */
    function quote(address safe, uint256 amount) external view returns (Draw[] memory draws, uint256 drawn) {
        return _plan(safe, amount);
    }

    /**
     * @notice Whether a charge would go through, and why not when it would not.
     *
     * The same checks as `charge`, in the same order, and with the same words
     * as `SolidSubscriptionModule.canCharge`, so one backend reads both. Here
     * "too soon" means the period has no room left for this amount: it is
     * right again once the period ends (see `allowanceOf`).
     */
    function canCharge(address safe, uint256 amount) external view returns (bool, string memory) {
        if (isPaused) return (false, "module paused");

        Subscription storage subscription = subscriptions[safe];
        if (!subscription.registered) return (false, "not subscribed");
        if (subscription.paused) return (false, "safe paused");
        if (subscription.cancelledAt != 0) return (false, "cancelled");
        if (amount == 0) return (false, "zero amount");
        if (amount > subscription.maxAmountPerPeriod) return (false, "exceeds mandate");
        if (amount > maxChargeAmount) return (false, "exceeds org ceiling");
        (, uint256 charged) = _period(subscription);
        if (charged + amount > subscription.maxAmountPerPeriod) return (false, "too soon");
        if (!isModuleEnabledOn(safe)) return (false, "module not enabled");

        (, uint256 drawn) = _plan(safe, amount);
        if (drawn < amount) return (false, "insufficient balance");

        return (true, "");
    }

    //============================== ADMIN FUNCTIONS ===============================

    /**
     * @notice Replace the billing tokens and their draw order.
     *
     * How a token is added — soUSD on Base, or anything after it — without a
     * redeploy and without a user signing again. Replaces the whole list in one
     * call so the order is always one the owner wrote, never one left behind by
     * an add or a remove.
     */
    function setBillingTokens(address[] calldata tokens, address[] calldata rateProviders) external requiresAuth {
        _setBillingTokens(tokens, rateProviders);
    }

    /// @notice Move the org-wide ceiling on one charge. Binds existing mandates.
    function setMaxChargeAmount(uint128 amount) external requiresAuth {
        maxChargeAmount = amount;
        emit MaxChargeAmountSet(amount);
    }

    /// @notice Stop charging one Safe, for a dispute or a hold.
    function setSafePaused(address safe, bool paused) external requiresAuth {
        subscriptions[safe].paused = paused;
        emit SafePauseSet(safe, paused);
    }

    /// @notice Stop charging everybody.
    function pause() external requiresAuth {
        isPaused = true;
        emit Paused();
    }

    function unpause() external requiresAuth {
        isPaused = false;
        emit Unpaused();
    }

    //============================== INTERNAL ===============================

    function _setBillingTokens(address[] memory tokens, address[] memory rateProviders) internal {
        if (tokens.length != rateProviders.length) revert SolidUsageBillingModule__LengthMismatch();
        if (tokens.length > MAX_BILLING_TOKENS) revert SolidUsageBillingModule__TooManyTokens(tokens.length);

        delete billingTokens;

        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            address rateProvider = rateProviders[i];
            if (token == address(0) || token == revenueTreasury || token.code.length == 0) {
                revert SolidUsageBillingModule__InvalidToken(token);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (tokens[j] == token) revert SolidUsageBillingModule__DuplicateToken(token);
            }

            uint8 decimals = ERC20(token).decimals();
            BillingToken memory billingToken =
                BillingToken({token: token, rateProvider: rateProvider, decimals: decimals});

            // A provider must answer, and with a price, before any charge relies
            // on it — a wrong address found here costs a revert, found later it
            // costs a user's charge.
            if (rateProvider != address(0)) {
                if (rateProvider.code.length == 0) {
                    revert SolidUsageBillingModule__InvalidRateProvider(token, rateProvider);
                }
                (bool ok,) = _rate(billingToken);
                if (!ok) revert SolidUsageBillingModule__InvalidRateProvider(token, rateProvider);
            }

            billingTokens.push(billingToken);
        }

        emit BillingTokensSet(tokens, rateProviders);
    }

    /**
     * @dev The period a charge now would count against: when it began and what
     *      it has taken. A mandate never drawn on, or one whose last period has
     *      run out, starts a fresh period now with nothing taken.
     */
    function _period(Subscription storage subscription) internal view returns (uint64 startedAt, uint256 charged) {
        startedAt = subscription.periodStartedAt;
        if (startedAt == 0 || block.timestamp >= uint256(startedAt) + subscription.periodSeconds) {
            return (uint64(block.timestamp), 0);
        }
        return (startedAt, subscription.chargedInPeriod);
    }

    /**
     * @dev The dollar price of one whole token, in micro-USD. `ok` is false for a
     *      provider that reverts or answers zero: that token is then not drawn
     *      from, which is the safe failure — the alternative is guessing a price.
     */
    function _rate(BillingToken memory billingToken) internal view returns (bool ok, uint256 rate) {
        if (billingToken.rateProvider == address(0)) return (true, 10 ** USD_DECIMALS);

        try IRateProvider(billingToken.rateProvider).getRate() returns (uint256 answer) {
            return (answer > 0, answer);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Dollars, rounded down, that `units` of a token are worth.
    function _valueOf(uint256 units, uint256 rate, uint8 decimals) internal pure returns (uint256) {
        return (units * rate) / (10 ** decimals);
    }

    /**
     * @dev The draw for `amount`, greedy in list order: each token in full before
     *      the next. Units round up, so what a token settles is never less than
     *      the dollars it is credited with; a Safe holding exactly enough of one
     *      token pays from that token alone.
     */
    function _plan(address safe, uint256 amount) internal view returns (Draw[] memory draws, uint256 drawn) {
        uint256 count = billingTokens.length;
        draws = new Draw[](count);
        uint256 used;

        for (uint256 i = 0; i < count && drawn < amount; ++i) {
            BillingToken memory billingToken = billingTokens[i];
            (bool ok, uint256 rate) = _rate(billingToken);
            if (!ok) continue;

            uint256 balance = ERC20(billingToken.token).balanceOf(safe);
            if (balance == 0) continue;

            uint256 scale = 10 ** billingToken.decimals;
            uint256 value = _valueOf(balance, rate, billingToken.decimals);
            uint256 remaining = amount - drawn;

            uint256 units;
            uint256 settles;
            if (value >= remaining) {
                // Round up: never settle less than is owed.
                units = (remaining * scale + rate - 1) / rate;
                if (units > balance) units = balance;
                settles = remaining;
            } else {
                units = balance;
                settles = value;
            }
            if (units == 0 || settles == 0) continue;

            draws[used++] = Draw({token: billingToken.token, units: units, amount: settles});
            drawn += settles;
        }

        // Trim to the tokens actually drawn from.
        assembly {
            mstore(draws, used)
        }
    }

    /**
     * @dev Move `units` of `token` from `safe` to the treasury, and prove it
     *      arrived. A Safe can answer `true` from `execTransactionFromModule`
     *      having moved nothing, and a token can return `false` instead of
     *      reverting; the treasury's own balance is the only proof of payment.
     */
    function _pull(address safe, address token, uint256 units) internal {
        uint256 treasuryBefore = ERC20(token).balanceOf(revenueTreasury);

        bool ok = ISafe(safe).execTransactionFromModule(
            token, 0, abi.encodeWithSelector(ERC20.transfer.selector, revenueTreasury, units), ISafe.Operation.Call
        );
        if (!ok) revert SolidUsageBillingModule__TransferFailed(safe, token);

        uint256 received = ERC20(token).balanceOf(revenueTreasury) - treasuryBefore;
        if (received < units) revert SolidUsageBillingModule__NotSettled(token, units, received);
    }
}
