// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {IPausable} from "src/interfaces/IPausable.sol";
import {ISafe} from "src/solid-rewards/interfaces/ISafe.sol";

/**
 * @title SolidSubscriptionModule
 * @notice A Safe module that collects a recurring membership fee, and nothing else.
 *
 * ## Why a module rather than an allowance
 *
 * The alternative is an ERC-20 approval to a collector address, and its only
 * bound is the approved amount: an infinite approval is an infinite,
 * unrevocable-in-practice licence, and a finite one has to be re-signed every
 * period, which is exactly the interaction a subscription exists to avoid.
 *
 * A module moves the bounds on-chain, where the user can see them and we cannot
 * quietly exceed them. Every one of these is enforced by this contract rather
 * than by the backend that calls it:
 *
 *  - **The destination is immutable.** `revenueTreasury` is set at deployment
 *    and has no setter, so a compromised biller key cannot redirect a single
 *    cent. It can only move a user's money to the one address it was always
 *    going to move it to.
 *  - **The asset is immutable.** Only `billingToken` can be moved. The module
 *    cannot touch a user's savings, their card balance or any other asset in
 *    the Safe.
 *  - **The user sets their own ceiling.** `subscribe` is callable only by the
 *    Safe itself, and the mandate it writes caps both the amount of one charge
 *    and how often one may be taken.
 *  - **One charge per period, once each.** A `billingId` clears exactly once,
 *    so a retry after a dropped receipt cannot bill twice; and `periodSeconds`
 *    must have elapsed since the last successful charge whatever id is used.
 *  - **Consent is withdrawable at any time**, by `cancel()` here or by
 *    `disableModule` on the Safe. The Safe itself enforces the second on the
 *    very next block.
 *
 * ## What it deliberately does not do
 *
 * It does not price anything, does not know what a tier is, and does not decide
 * when a fee is owed. Those are the backend's, which is what keeps the on-chain
 * surface small enough to reason about: this contract answers only "may this
 * amount move, from this Safe, to that treasury, today".
 */
contract SolidSubscriptionModule is Auth, IPausable {
    // ========================================= CONSTANTS =========================================

    /**
     * @notice Shortest billing period a user may agree to.
     *
     * The product is an annual membership, and a floor well under a year still
     * leaves room for a monthly plan later while making "billed twice in a
     * fortnight" unreachable regardless of what the backend asks for.
     */
    uint64 public constant MIN_PERIOD = 7 days;

    /// @notice Longest billing period a mandate may carry.
    uint64 public constant MAX_PERIOD = 1460 days;

    // ========================================= IMMUTABLES =========================================

    /// @notice The only asset this module can move.
    ERC20 public immutable billingToken;

    /// @notice The only address this module can move it to.
    address public immutable revenueTreasury;

    // ========================================= STATE =========================================

    /**
     * @notice One user's standing permission to be billed.
     *
     * `cancelledAt` is kept rather than the row being deleted: a user who
     * cancels and later re-subscribes is a different story from one who never
     * subscribed, and support needs to be able to tell them apart.
     */
    struct Subscription {
        bool registered;
        /// @notice Per-Safe stop, for a dispute or a fraud hold. Admin-set.
        bool paused;
        /// @notice Most one charge may take, in `billingToken` units.
        uint128 maxAmountPerPeriod;
        /// @notice Shortest gap the user has agreed to between two charges.
        uint64 periodSeconds;
        uint64 subscribedAt;
        uint64 lastChargedAt;
        /// @notice Non-zero once the user has stopped the mandate.
        uint64 cancelledAt;
    }

    mapping(address => Subscription) internal subscriptions;

    /// @notice Charges already taken, per Safe. Makes a retry safe.
    mapping(address => mapping(bytes32 => bool)) public chargeCleared;

    /**
     * @notice Org-wide ceiling on one charge.
     *
     * A second bound above the user's own, so a mandate signed while the plan
     * cost $199 cannot be drawn against at $19,900 if the pricing config is ever
     * wrong. Lowering it binds existing mandates immediately, which is the point.
     */
    uint128 public maxChargeAmount;

    /// @notice Global stop. No charge clears while true.
    bool public isPaused;

    //============================== ERRORS ===============================

    error SolidSubscriptionModule__Paused();
    error SolidSubscriptionModule__SafePaused(address safe);
    error SolidSubscriptionModule__NotRegistered(address safe);
    error SolidSubscriptionModule__AlreadyCancelled(address safe);
    error SolidSubscriptionModule__NotCancelled(address safe);
    error SolidSubscriptionModule__Cancelled(address safe);
    error SolidSubscriptionModule__ModuleNotEnabled(address safe);
    error SolidSubscriptionModule__ZeroAmount();
    error SolidSubscriptionModule__ExceedsMandate(uint256 amount, uint128 mandate);
    error SolidSubscriptionModule__ExceedsOrgCeiling(uint256 amount, uint128 ceiling);
    error SolidSubscriptionModule__PeriodOutOfRange(uint64 period);
    error SolidSubscriptionModule__TooSoon(uint64 nextChargeDueAt);
    error SolidSubscriptionModule__AlreadyCharged(address safe, bytes32 billingId);
    error SolidSubscriptionModule__TransferFailed(address safe);
    error SolidSubscriptionModule__NotSettled(address safe, uint256 expected, uint256 received);
    error SolidSubscriptionModule__InvalidAddress();

    //============================== EVENTS ===============================

    event Subscribed(address indexed safe, uint128 maxAmountPerPeriod, uint64 periodSeconds);
    event MandateChanged(address indexed safe, uint128 maxAmountPerPeriod, uint64 periodSeconds);
    event Cancelled(address indexed safe);
    event Resumed(address indexed safe);
    event Charged(address indexed safe, bytes32 indexed billingId, uint256 amount, uint64 chargedAt);
    event MaxChargeAmountSet(uint128 maxChargeAmount);
    event SafePauseSet(address indexed safe, bool paused);
    event Paused();
    event Unpaused();

    //============================== CONSTRUCTOR ===============================

    constructor(address _owner, address _billingToken, address _revenueTreasury, uint128 _maxChargeAmount)
        Auth(_owner, Authority(address(0)))
    {
        // The treasury and the token can never be changed, so a zero or
        // codeless value here is unfixable rather than inconvenient.
        if (_owner == address(0) || _billingToken.code.length == 0 || _revenueTreasury == address(0)) {
            revert SolidSubscriptionModule__InvalidAddress();
        }

        billingToken = ERC20(_billingToken);
        revenueTreasury = _revenueTreasury;
        maxChargeAmount = _maxChargeAmount;
        emit MaxChargeAmountSet(_maxChargeAmount);
    }

    //============================== USER FUNCTIONS ===============================

    /**
     * @notice Agree to be billed up to `maxAmountPerPeriod` no more often than
     *         every `periodSeconds`.
     *
     * `msg.sender` is the Safe, so the only way to reach this is a transaction
     * the user's own account executes — batched, in practice, with the
     * `enableModule` that makes the module usable at all, so one signature both
     * grants the permission and bounds it.
     *
     * Calling it again re-states the mandate, which is how a user moves from one
     * plan to another. It also un-cancels: re-subscribing after cancelling is
     * the same decision as subscribing, and making the user cancel their cancel
     * first would be a worse way to say so. `lastChargedAt` survives, so
     * re-subscribing can never be used to escape the period gap and be billed
     * twice in one year.
     */
    function subscribe(uint128 maxAmountPerPeriod, uint64 periodSeconds) external {
        if (maxAmountPerPeriod == 0) revert SolidSubscriptionModule__ZeroAmount();
        if (maxAmountPerPeriod > maxChargeAmount) {
            revert SolidSubscriptionModule__ExceedsOrgCeiling(maxAmountPerPeriod, maxChargeAmount);
        }
        if (periodSeconds < MIN_PERIOD || periodSeconds > MAX_PERIOD) {
            revert SolidSubscriptionModule__PeriodOutOfRange(periodSeconds);
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

    /**
     * @notice Stop the mandate. No further charge clears until the user
     *         subscribes again.
     *
     * Kept alongside `disableModule` rather than instead of it. Disabling the
     * module is the stronger revocation and the one a user can make from any
     * Safe client; this one is the in-app "cancel membership", which leaves the
     * module in place for the other things it will be asked to do and keeps the
     * cancellation legible on-chain as an event rather than as an absence.
     */
    function cancel() external {
        Subscription storage subscription = subscriptions[msg.sender];
        if (!subscription.registered) revert SolidSubscriptionModule__NotRegistered(msg.sender);
        if (subscription.cancelledAt != 0) revert SolidSubscriptionModule__AlreadyCancelled(msg.sender);

        subscription.cancelledAt = uint64(block.timestamp);
        emit Cancelled(msg.sender);
    }

    /**
     * @notice Restart a cancelled mandate on its existing terms.
     *
     * The same outcome as calling `subscribe` with the stored numbers, without
     * the client having to read them back and re-send them — which is a
     * needless chance to send different ones by accident.
     */
    function resume() external {
        Subscription storage subscription = subscriptions[msg.sender];
        if (!subscription.registered) revert SolidSubscriptionModule__NotRegistered(msg.sender);
        if (subscription.cancelledAt == 0) revert SolidSubscriptionModule__NotCancelled(msg.sender);
        if (subscription.maxAmountPerPeriod > maxChargeAmount) {
            revert SolidSubscriptionModule__ExceedsOrgCeiling(subscription.maxAmountPerPeriod, maxChargeAmount);
        }

        subscription.cancelledAt = 0;
        emit Resumed(msg.sender);
    }

    //============================== BILLER FUNCTIONS ===============================

    /**
     * @notice Take one charge from `safe`.
     *
     * Restricted by `requiresAuth` to the biller role. Note how little that role
     * is worth on its own: the holder chooses the Safe and the amount, and every
     * other term — where the money goes, in what asset, how much at most, and
     * how recently the last one was taken — is fixed by the contract and by the
     * user's own mandate.
     *
     * `billingId` is the caller's idempotency key and should identify the
     * *period being billed*, not the attempt. A retry after an unobserved
     * receipt then lands on `AlreadyCharged` instead of billing a second time,
     * which is the failure this whole mechanism is most likely to meet in
     * practice.
     */
    function charge(address safe, bytes32 billingId, uint256 amount) external requiresAuth {
        if (isPaused) revert SolidSubscriptionModule__Paused();
        if (amount == 0) revert SolidSubscriptionModule__ZeroAmount();
        if (chargeCleared[safe][billingId]) revert SolidSubscriptionModule__AlreadyCharged(safe, billingId);

        Subscription storage subscription = subscriptions[safe];
        if (!subscription.registered) revert SolidSubscriptionModule__NotRegistered(safe);
        if (subscription.paused) revert SolidSubscriptionModule__SafePaused(safe);
        if (subscription.cancelledAt != 0) revert SolidSubscriptionModule__Cancelled(safe);
        if (amount > subscription.maxAmountPerPeriod) {
            revert SolidSubscriptionModule__ExceedsMandate(amount, subscription.maxAmountPerPeriod);
        }
        if (amount > maxChargeAmount) revert SolidSubscriptionModule__ExceedsOrgCeiling(amount, maxChargeAmount);

        uint64 dueAt = _nextChargeDueAt(subscription);
        if (block.timestamp < dueAt) revert SolidSubscriptionModule__TooSoon(dueAt);

        // Read rather than assumed. The Safe would reject the call anyway, but
        // its revert says only "GS104"; this one names the Safe whose owner
        // withdrew consent, which is the difference between a support ticket
        // that resolves itself and one that does not.
        //
        // Through the tolerant reader, so an address that cannot answer at all —
        // an EOA, or a mandate written by something that is not a Safe — lands
        // on the same named error rather than on a bare decode failure.
        if (!isModuleEnabledOn(safe)) {
            revert SolidSubscriptionModule__ModuleNotEnabled(safe);
        }

        // Written before the external call. A token with a transfer hook that
        // re-entered would find the id already spent and the clock already
        // moved, so there is no second charge to be had.
        chargeCleared[safe][billingId] = true;
        subscription.lastChargedAt = uint64(block.timestamp);

        uint256 treasuryBefore = billingToken.balanceOf(revenueTreasury);

        bool ok = ISafe(safe).execTransactionFromModule(
            address(billingToken),
            0,
            abi.encodeWithSelector(ERC20.transfer.selector, revenueTreasury, amount),
            ISafe.Operation.Call
        );
        if (!ok) revert SolidSubscriptionModule__TransferFailed(safe);

        // Settlement is measured, not taken on trust, because neither thing
        // read so far actually proves payment:
        //
        //  - `safe` is whatever address subscribed. Nothing here can tell a
        //    real Safe from a contract that answers `isModuleEnabled` and
        //    `execTransactionFromModule` with `true` and moves nothing — and
        //    such a contract could hold a balance so `canCharge` passed too.
        //    Without this line it would collect a `Charged` receipt and a spent
        //    billing id for free, and anything granting membership on that
        //    receipt would be giving the tier away.
        //  - `ok` is the success of the *call*, not of the transfer. An ERC-20
        //    that returns `false` instead of reverting — or returns nothing at
        //    all — leaves `ok` true with the balance untouched.
        //
        // The treasury's own balance answers both at once, and is the only
        // thing that actually means "we were paid". Deliberately `<` rather
        // than `!=`: a token that delivers more than asked is not a failure.
        uint256 received = billingToken.balanceOf(revenueTreasury) - treasuryBefore;
        if (received < amount) revert SolidSubscriptionModule__NotSettled(safe, amount, received);

        emit Charged(safe, billingId, amount, uint64(block.timestamp));
    }

    //============================== VIEW FUNCTIONS ===============================

    /// @notice The stored mandate for `safe`.
    function subscriptionOf(address safe) external view returns (Subscription memory) {
        return subscriptions[safe];
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

    /// @notice The earliest timestamp at which `safe` may next be charged.
    function nextChargeDueAt(address safe) external view returns (uint64) {
        return _nextChargeDueAt(subscriptions[safe]);
    }

    function _nextChargeDueAt(Subscription storage subscription) internal view returns (uint64) {
        // A mandate that has never been drawn on is due immediately: the first
        // charge is the one the user just signed up for.
        if (subscription.lastChargedAt == 0) return 0;
        return subscription.lastChargedAt + subscription.periodSeconds;
    }

    /**
     * @notice Whether a charge would go through, and why not when it would not.
     *
     * The same checks `charge` makes, in the same order, so the backend can
     * decide whether to even try — and so the app can tell a user their card
     * fee will fail because they revoked the module, rather than showing them a
     * failed transaction. Balance is checked here but deliberately not in
     * `charge`: the token's own transfer is the authority on that, and
     * duplicating it would only add a way for the two to disagree.
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
        if (block.timestamp < _nextChargeDueAt(subscription)) return (false, "too soon");
        if (!isModuleEnabledOn(safe)) return (false, "module not enabled");
        if (billingToken.balanceOf(safe) < amount) return (false, "insufficient balance");

        return (true, "");
    }

    //============================== ADMIN FUNCTIONS ===============================

    /**
     * @notice Move the org-wide ceiling on one charge.
     *
     * Binds existing mandates as well as new ones, so lowering it is a live
     * throttle. Raising it does not raise anybody's mandate — each user's own
     * cap still applies — so this can only ever be the tighter of the two.
     */
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
}
