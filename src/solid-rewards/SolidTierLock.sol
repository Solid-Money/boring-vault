// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPausable} from "src/interfaces/IPausable.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {AccountantWithRateProviders} from "src/base/Roles/AccountantWithRateProviders.sol";

/**
 * @title SolidTierLock
 * @notice Fixed-term escrow for BoringVault shares, used to buy a membership tier.
 *
 * A user commits a position for a fixed term and keeps earning on it: the shares
 * sit here rather than being redeemed, so the vault's rate carries them exactly
 * as it would in the user's own account. Nothing is minted in return — the lock
 * IS the receipt, readable by anyone at `lockedSharesOf`.
 *
 * ## Why an escrow, and not a lock in place
 *
 * Locking the shares where they already sit would be better, and on this stack
 * it cannot be made to hold:
 *
 *  - A Safe **transaction guard** is not consulted by `execTransactionFromModule`
 *    on Safe 1.4.1 (module guards arrived in 1.5.0). Solid's accounts execute
 *    every user operation through the 4337 module, so a guard would be bypassed
 *    by the ordinary path, not merely by an exotic one.
 *  - The vault's own `beforeTransfer` hook is a `view` that receives `from`, `to`
 *    and the operator and **no amount**, so it can only refuse a holder's every
 *    transfer, never a part of one — and `Teller.bulkWithdraw` burns through
 *    `vault.exit` without calling it at all.
 *
 * So the commitment is held here, where it can be enforced and audited. The
 * design then owes the user two things in exchange, and both are structural
 * rather than promised:
 *
 * 1. **Nothing can send shares anywhere but back to the account that locked
 *    them.** There is no admin transfer, no sweep, no upgrade hook, and
 *    `rescue` is barred from the locked balance. A compromised owner key cannot
 *    take a user's position; the worst it can do is stop new locks.
 * 2. **Withdrawal is permissionless once the term is up.** Anyone may call
 *    `withdrawFor`, which is what lets Solid return matured positions on the
 *    user's behalf and makes "unlocked automatically" true rather than a promise
 *    to press a button. Since the destination is fixed to the owner, a caller
 *    other than the owner gains nothing by calling it.
 *
 * ## Terms are snapshotted
 *
 * Each lock stores its own `unlocksAt`, computed from `lockDuration` at the
 * moment it was taken. Lengthening the configured duration therefore cannot
 * reach back and extend a commitment a user already made, which is the one thing
 * an admin key must never be able to do to money it does not hold.
 */
contract SolidTierLock is Auth, IPausable, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // ========================================= CONSTANTS =========================================

    /**
     * @notice Ceiling on the configurable lock term.
     *
     * A term nobody would knowingly accept is indistinguishable from a
     * confiscation, so the contract refuses to be configured into one.
     */
    uint64 public constant MAX_LOCK_DURATION = 1460 days;

    /**
     * @notice Most open locks one account may hold at once.
     *
     * `withdrawFor` walks the account's locks, so an unbounded list is an
     * account that can be made too expensive to unlock. Four years of top-ups at
     * one a month still fits.
     */
    uint256 public constant MAX_LOCKS_PER_ACCOUNT = 64;

    // ========================================= IMMUTABLES =========================================

    /// @notice The vault share token this contract escrows (e.g. soFUSE).
    ERC20 public immutable lockToken;

    /// @notice Prices `lockToken` in the vault's base asset, for display only.
    AccountantWithRateProviders public immutable accountant;

    /// @notice One whole share, the denominator of the rate.
    uint256 internal immutable ONE_SHARE;

    // ========================================= STATE =========================================

    /**
     * @notice One commitment: how many shares, and when they are free again.
     *
     * Packed into a single slot. `uint128` holds more shares than any 18-decimal
     * vault will ever issue, and `uint64` seconds outlives the contract.
     */
    struct Lock {
        uint128 shares;
        uint64 lockedAt;
        uint64 unlocksAt;
    }

    /// @notice Open locks per account, in the order they were taken.
    mapping(address => Lock[]) internal accountLocks;

    /// @notice Shares held for an account across all of its open locks.
    mapping(address => uint256) public lockedSharesOf;

    /// @notice Shares held for every account. The floor `rescue` may not touch.
    uint256 public totalLockedShares;

    /// @notice Term applied to a new lock, in seconds.
    uint64 public lockDuration;

    /// @notice Smallest lock worth taking, in shares. Keeps the list meaningful.
    uint256 public minLockShares;

    /// @notice When true, no new locks are taken. Withdrawals are never paused.
    bool public isPaused;

    //============================== ERRORS ===============================

    error SolidTierLock__Paused();
    error SolidTierLock__ZeroAmount();
    error SolidTierLock__BelowMinimum(uint256 shares, uint256 minimum);
    error SolidTierLock__TooManyLocks();
    error SolidTierLock__NothingMatured();
    error SolidTierLock__DurationTooLong(uint64 duration, uint64 maximum);
    error SolidTierLock__ZeroDuration();
    error SolidTierLock__CannotRescueLockedShares();
    error SolidTierLock__AmountTooLarge(uint256 shares);
    error SolidTierLock__TransferAmountMismatch(uint256 expected, uint256 received);
    error SolidTierLock__InvalidAddress();

    //============================== EVENTS ===============================

    event Locked(address indexed account, uint256 indexed index, uint256 shares, uint64 unlocksAt);
    event Withdrawn(address indexed account, address indexed caller, uint256 shares, uint256 locksClosed);
    event LockDurationSet(uint64 duration);
    event MinLockSharesSet(uint256 minLockShares);
    event Paused();
    event Unpaused();
    event Rescued(address indexed token, address indexed to, uint256 amount);

    //============================== CONSTRUCTOR ===============================

    constructor(
        address _owner,
        address _lockToken,
        address _accountant,
        uint64 _lockDuration,
        uint256 _minLockShares
    ) Auth(_owner, Authority(address(0))) {
        // Both must be contracts. `decimals()` below already rejects a codeless
        // lock token — a high-level call to an address with no code reverts —
        // but the accountant is only ever read from a view, so nothing else
        // would catch it until a user saw their position priced at zero.
        if (_owner == address(0) || _lockToken.code.length == 0 || _accountant.code.length == 0) {
            revert SolidTierLock__InvalidAddress();
        }

        lockToken = ERC20(_lockToken);
        accountant = AccountantWithRateProviders(_accountant);
        ONE_SHARE = 10 ** BoringVault(payable(_lockToken)).decimals();

        _setLockDuration(_lockDuration);
        minLockShares = _minLockShares;
        emit MinLockSharesSet(_minLockShares);
    }

    //============================== USER FUNCTIONS ===============================

    /**
     * @notice Commit `shares` for the configured term.
     *
     * The caller is the account the shares are held for and the only address
     * they can ever return to, so this is called by the user's own account —
     * their Safe — with an `approve` of the same amount batched in front of it.
     *
     * A second call is a second lock rather than an extension of the first: a
     * user topping up from Prime to Ultra is making a new commitment on the day
     * they make it, and rolling it into the earlier one would silently push out
     * the date the earlier shares come back.
     */
    function lock(uint256 shares) external returns (uint256 index) {
        return _lock(msg.sender, msg.sender, shares);
    }

    /**
     * @notice Commit `shares` pulled from the caller, held for `account`.
     *
     * For a periphery contract that has just minted shares on a user's behalf
     * and cannot hand them over without the user signing a second time — see
     * `SolidTierLockZap`, which turns "deposit into Savings, then lock" into one
     * transaction the user's own Safe sends.
     *
     * Restricted, and that is the whole of the trust it asks for. The shares
     * still go nowhere but back to `account`: `lockFor` writes exactly the same
     * record `lock` does, and withdrawal is still fixed to the account the
     * record names, so an authorised caller can give shares away and can never
     * take them. What it could do unrestricted is fill a stranger's lock list —
     * `MAX_LOCKS_PER_ACCOUNT` of dust, blocking the upgrade they were trying to
     * make — which is why it is not.
     */
    function lockFor(address account, uint256 shares) external requiresAuth returns (uint256 index) {
        if (account == address(0)) revert SolidTierLock__InvalidAddress();
        return _lock(account, msg.sender, shares);
    }

    /**
     * @dev Writes one lock for `account`, paid for by `payer`.
     *
     * The two are the same address for a user locking their own position and
     * differ only for `lockFor`. Everything else — the term, the minimum, the
     * bookkeeping — is identical, because a lock taken on someone's behalf that
     * behaved differently from one they took themselves would be a second set
     * of rules to audit.
     */
    function _lock(address account, address payer, uint256 shares) internal nonReentrant returns (uint256 index) {
        if (isPaused) revert SolidTierLock__Paused();
        if (shares == 0) revert SolidTierLock__ZeroAmount();
        if (shares < minLockShares) revert SolidTierLock__BelowMinimum(shares, minLockShares);
        // The Lock record stores shares in a uint128. An explicit downcast does
        // not revert on overflow, so without this an oversized deposit would be
        // pulled and counted in full by the uint256 totals while the position
        // itself recorded the truncated remainder — the difference becoming
        // rescuable and the account's own locks unable to return it. No supply
        // reaches 2^128, which is exactly why this has to be a check rather
        // than a comment.
        if (shares > type(uint128).max) revert SolidTierLock__AmountTooLarge(shares);

        Lock[] storage locks = accountLocks[account];
        if (locks.length >= MAX_LOCKS_PER_ACCOUNT) revert SolidTierLock__TooManyLocks();

        // Pulled before the accounting is written, so a share token that lies
        // about its transfer cannot leave a lock standing against shares that
        // never arrived. `safeTransferFrom` rejects a silent `false`, and the
        // balance is measured either side of it because a return value is not
        // an amount: a fee-on-transfer or rebasing token can report success
        // having delivered less, which would leave `totalLockedShares` claiming
        // more than the contract holds and the last withdrawal of the day
        // reverting on a balance that was never there. This contract is
        // deployed against a BoringVault share, which does none of that — so
        // the check costs two SLOADs to make the assumption enforced instead of
        // documented.
        uint256 balanceBefore = lockToken.balanceOf(address(this));
        lockToken.safeTransferFrom(payer, address(this), shares);
        uint256 received = lockToken.balanceOf(address(this)) - balanceBefore;
        if (received != shares) revert SolidTierLock__TransferAmountMismatch(shares, received);

        uint64 unlocksAt = uint64(block.timestamp) + lockDuration;
        index = locks.length;
        locks.push(Lock({shares: uint128(shares), lockedAt: uint64(block.timestamp), unlocksAt: unlocksAt}));

        lockedSharesOf[account] += shares;
        totalLockedShares += shares;

        emit Locked(account, index, shares, unlocksAt);
    }

    /// @notice Return every matured lock of the caller's.
    function withdraw() external returns (uint256 shares) {
        return _withdrawFor(msg.sender);
    }

    /**
     * @notice Return every matured lock of `account`'s, to `account`.
     *
     * Permissionless on purpose. The shares can only go to the account that
     * locked them, so there is nothing for a stranger to gain and nothing for
     * the owner to lose — and it is what lets Solid hand matured positions back
     * without the user having to come and ask for them.
     */
    function withdrawFor(address account) external returns (uint256 shares) {
        return _withdrawFor(account);
    }

    /**
     * @dev Closes matured locks by swapping the last entry into the closed slot.
     *
     * Order is not preserved, which costs nothing: every consumer reads the set,
     * not the sequence, and the alternative — shifting the tail down — turns an
     * account's oldest lock into its most expensive one to close.
     */
    function _withdrawFor(address account) internal nonReentrant returns (uint256 shares) {
        Lock[] storage locks = accountLocks[account];
        uint256 closed;

        for (uint256 i = locks.length; i > 0;) {
            unchecked {
                --i;
            }

            if (locks[i].unlocksAt > block.timestamp) continue;

            shares += locks[i].shares;
            unchecked {
                ++closed;
            }

            uint256 last = locks.length - 1;
            if (i != last) locks[i] = locks[last];
            locks.pop();
        }

        if (shares == 0) revert SolidTierLock__NothingMatured();

        lockedSharesOf[account] -= shares;
        totalLockedShares -= shares;

        lockToken.safeTransfer(account, shares);

        emit Withdrawn(account, msg.sender, shares, closed);
    }

    //============================== VIEW FUNCTIONS ===============================

    /// @notice Every open lock of `account`'s.
    function getLocks(address account) external view returns (Lock[] memory) {
        return accountLocks[account];
    }

    /// @notice How many open locks `account` holds.
    function lockCountOf(address account) external view returns (uint256) {
        return accountLocks[account].length;
    }

    /// @notice Shares of `account`'s that have matured and can be returned now.
    function maturedSharesOf(address account) external view returns (uint256 shares) {
        Lock[] storage locks = accountLocks[account];

        for (uint256 i = 0; i < locks.length;) {
            if (locks[i].unlocksAt <= block.timestamp) shares += locks[i].shares;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice When the account's next tranche comes free, and how much.
     *
     * The soonest unlock among the locks still running, so the app can say
     * "unlocks on <date>" without pulling the whole list. Reports `(0, 0)` when
     * nothing is still running.
     */
    function nextUnlockOf(address account) external view returns (uint64 unlocksAt, uint256 shares) {
        Lock[] storage locks = accountLocks[account];

        for (uint256 i = 0; i < locks.length;) {
            Lock storage entry = locks[i];
            if (entry.unlocksAt > block.timestamp) {
                if (unlocksAt == 0 || entry.unlocksAt < unlocksAt) {
                    unlocksAt = entry.unlocksAt;
                    shares = entry.shares;
                } else if (entry.unlocksAt == unlocksAt) {
                    shares += entry.shares;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice `account`'s locked position valued in the vault's base asset.
     *
     * Display only, and deliberately forgiving: a paused or unreachable
     * accountant reports 0 rather than reverting, because this is read by the
     * same screen that has to draw the unlock date, and a rate outage must not
     * take the whole card down with it. Nothing about a withdrawal depends on it.
     */
    function lockedAssetsOf(address account) external view returns (uint256) {
        uint256 shares = lockedSharesOf[account];
        if (shares == 0) return 0;

        try accountant.getRate() returns (uint256 rate) {
            return shares.mulDivDown(rate, ONE_SHARE);
        } catch {
            return 0;
        }
    }

    //============================== ADMIN FUNCTIONS ===============================

    /**
     * @notice Set the term applied to locks taken from now on.
     *
     * Existing locks keep the date they were written with — see the contract
     * comment. This only decides what a new commitment costs in time.
     */
    function setLockDuration(uint64 duration) external requiresAuth {
        _setLockDuration(duration);
    }

    function _setLockDuration(uint64 duration) internal {
        if (duration == 0) revert SolidTierLock__ZeroDuration();
        if (duration > MAX_LOCK_DURATION) revert SolidTierLock__DurationTooLong(duration, MAX_LOCK_DURATION);

        lockDuration = duration;
        emit LockDurationSet(duration);
    }

    /// @notice Set the smallest lock the contract will accept.
    function setMinLockShares(uint256 shares) external requiresAuth {
        minLockShares = shares;
        emit MinLockSharesSet(shares);
    }

    /**
     * @notice Stop new locks being taken.
     *
     * Withdrawals are deliberately left running. A pause is for a problem on our
     * side, and the correct response to one is to stop taking on new
     * commitments — never to hold on to commitments already made.
     */
    function pause() external requiresAuth {
        isPaused = true;
        emit Paused();
    }

    function unpause() external requiresAuth {
        isPaused = false;
        emit Unpaused();
    }

    /**
     * @notice Recover tokens that were sent here by mistake.
     *
     * Barred from the locked balance: only share tokens held in excess of
     * `totalLockedShares` — a donation or a stray transfer — can be moved, so
     * there is no configuration of this function that reaches a user's lock.
     */
    function rescue(ERC20 token, address to, uint256 amount) external requiresAuth {
        if (address(token) == address(lockToken)) {
            uint256 free = token.balanceOf(address(this)) - totalLockedShares;
            if (amount > free) revert SolidTierLock__CannotRescueLockedShares();
        }

        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }
}
