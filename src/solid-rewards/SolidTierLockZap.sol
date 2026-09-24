// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITeller} from "src/solid-rewards/interfaces/ITeller.sol";
import {SolidTierLock} from "src/solid-rewards/SolidTierLock.sol";

/**
 * @title SolidTierLockZap
 * @notice Deposit into the vault and lock the shares, in one transaction.
 *
 * Buying a tier with FUSE took two signatures and a wait in between: deposit
 * into Savings, come back when the shares have landed, then lock them. This
 * collapses that into one call the user's own Safe makes.
 *
 * ## Why this cannot be a batch
 *
 * A Safe can already batch `deposit` and `lock` into one user operation. What
 * it cannot do is read the shares the deposit minted before calling `lock`:
 * the amount has to be written into the calldata when the batch is signed, and
 * it depends on the vault's rate at the moment the batch executes. Quote it too
 * high and the lock reverts on a balance that never arrived; quote it low and
 * the user locks under the tier threshold, commits their FUSE for a year and
 * gets nothing for it.
 *
 * So the read happens here, between the two calls, where it is exact.
 *
 * ## What it is trusted with, and what it is not
 *
 * It holds the authority to call `SolidTierLock.lockFor`, and passes
 * `msg.sender` as the account every time — so the shares it locks are the
 * caller's own, credited to the caller, returnable only to the caller. It has
 * no owner-only path into a user's position because the lock has none to offer.
 *
 * It is stateless between calls. Everything it receives within a call is
 * locked within the same call, and the balance is measured either side of the
 * deposit rather than taken from a return value — a fee-on-transfer or
 * rebasing asset that reports one number and delivers another would otherwise
 * leave the difference stranded here.
 *
 * ## What it accepts
 *
 * The share token itself, the native token, and any ERC-20 the Teller takes as
 * a deposit asset. Anything else is a swap first: the app already swaps, and
 * the swap's output can feed this in the same user operation.
 */
contract SolidTierLockZap is Auth, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    // ========================================= CONSTANTS =========================================

    /// @notice The Teller's sentinel for "this deposit is the native token".
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========================================= IMMUTABLES =========================================

    /// @notice Where the shares end up.
    SolidTierLock public immutable lock;

    /// @notice Mints the shares. Deposits are made against this.
    ITeller public immutable teller;

    /// @notice The vault share token the lock escrows (soFUSE).
    ERC20 public immutable shareToken;

    /// @notice The address a deposit asset must be approved to — the vault, not the Teller.
    address public immutable vault;

    //============================== ERRORS ===============================

    error SolidTierLockZap__InvalidAddress();
    error SolidTierLockZap__TellerMismatch();
    error SolidTierLockZap__ZeroAmount();
    error SolidTierLockZap__NativeValueMismatch(uint256 expected, uint256 received);
    error SolidTierLockZap__UnexpectedNativeValue();
    error SolidTierLockZap__BelowMinimumShares(uint256 received, uint256 minimum);
    error SolidTierLockZap__ShareLockActive(uint64 shareLockPeriod);

    //============================== EVENTS ===============================

    event Zapped(address indexed account, address indexed asset, uint256 amount, uint256 shares);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    //============================== CONSTRUCTOR ===============================

    constructor(address _owner, address _lock, address _teller) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0) || _lock.code.length == 0 || _teller.code.length == 0) {
            revert SolidTierLockZap__InvalidAddress();
        }

        lock = SolidTierLock(_lock);
        teller = ITeller(_teller);
        shareToken = ERC20(address(SolidTierLock(_lock).lockToken()));
        vault = ITeller(_teller).vault();

        // The Teller and the lock have to be talking about the same vault. A
        // zap wired to the wrong Teller would mint a share the lock does not
        // escrow, and the failure would land on the first user rather than on
        // the deployment — deposited, un-lockable, and stuck here.
        if (vault != address(shareToken)) revert SolidTierLockZap__TellerMismatch();

        // And the Teller has to let the shares move in the transaction that
        // mints them, which is the whole premise of a zap. A non-zero share
        // lock period makes every minting path revert, so a zap deployed
        // against one is dead on arrival — better to find that out here than
        // on the first user's upgrade.
        _requireTransferableMint();
    }

    //============================== USER FUNCTIONS ===============================

    /**
     * @notice Deposit `amount` of `asset` and lock everything it mints.
     *
     * @param asset the share token (locked as-is), `NATIVE`, or any ERC-20 the
     *        Teller accepts.
     * @param amount how much to take. Ignored for `NATIVE`, which uses
     *        `msg.value` — but it must still match, so a caller cannot ask for
     *        one number and send another.
     * @param minShares the fewest shares the caller will accept, their bound on
     *        the vault's rate moving between quote and execution.
     *
     * @return shares what was locked. Every share this call receives is locked;
     *         nothing is left behind and nothing is returned to the caller.
     */
    function zapAndLock(address asset, uint256 amount, uint256 minShares)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert SolidTierLockZap__ZeroAmount();

        uint256 balanceBefore = shareToken.balanceOf(address(this));

        if (asset == address(shareToken)) {
            // Already shares: nothing to mint, and no Teller involved. This is
            // the path a user with soFUSE in Savings takes, and it exists so
            // the app has one entry point rather than two.
            if (msg.value != 0) revert SolidTierLockZap__UnexpectedNativeValue();
            shareToken.safeTransferFrom(msg.sender, address(this), amount);
        } else if (asset == NATIVE) {
            // Checked on the minting paths and only there. A share lock is
            // stamped on whoever the Teller mints to, so it is this contract's
            // onward transfer into the lock that it would block; the branch
            // above mints nothing and is unaffected.
            _requireTransferableMint();
            // The Teller ignores `amount` for a native deposit and uses
            // `msg.value`. Checking them against each other is what stops a
            // caller's slippage bound being quoted against a different number
            // from the one that is actually deposited.
            if (msg.value != amount) revert SolidTierLockZap__NativeValueMismatch(amount, msg.value);
            teller.deposit{value: amount}(ERC20(NATIVE), amount, minShares);
        } else {
            _requireTransferableMint();
            if (msg.value != 0) revert SolidTierLockZap__UnexpectedNativeValue();
            // `asset` is the one address here a caller chooses, and solmate's
            // SafeTransferLib reads a call to a codeless address as a success
            // with no return data. Without this the two transfers below would
            // both "succeed" against nothing, and the failure would surface as
            // a confusing revert inside the Teller instead of here.
            if (asset.code.length == 0) revert SolidTierLockZap__InvalidAddress();
            ERC20 depositAsset = ERC20(asset);
            depositAsset.safeTransferFrom(msg.sender, address(this), amount);
            // The vault is the spender, not the Teller: `deposit` has the vault
            // pull the asset from the Teller's caller — this contract.
            _approveExactly(depositAsset, vault, amount);
            teller.deposit(depositAsset, amount, minShares);
        }

        // Measured, not taken from the return value. What matters is what
        // arrived, and a token that reports one number and delivers another
        // would otherwise leave the difference stranded in this contract.
        shares = shareToken.balanceOf(address(this)) - balanceBefore;
        if (shares < minShares) revert SolidTierLockZap__BelowMinimumShares(shares, minShares);

        _approveExactly(shareToken, address(lock), shares);
        lock.lockFor(msg.sender, shares);

        emit Zapped(msg.sender, asset, amount, shares);
    }

    //============================== INTERNAL ===============================

    /**
     * @dev Revert unless the Teller lets freshly minted shares move immediately.
     *
     * The Teller stamps an unlock time on whoever it mints to and blocks every
     * transfer out of that address until it passes. This contract mints to
     * itself and then hands the shares to the lock in the same call, so any
     * non-zero period makes that second step revert — with the lock's
     * `TRANSFER_FROM_FAILED`, which says nothing about why.
     *
     * Read on every minting call rather than trusted from the constructor,
     * because the Teller's owner can set the period at any time.
     */
    function _requireTransferableMint() internal view {
        uint64 period = teller.shareLockPeriod();
        if (period != 0) revert SolidTierLockZap__ShareLockActive(period);
    }

    /**
     * @dev Set `spender`'s allowance to exactly `amount`, from any prior value.
     *
     * Both spenders here consume the whole allowance in the same call, so it is
     * always back to zero by the next one and this reads as a no-op. It is here
     * for the case where that stops being true: a deposit asset whose vault
     * takes less than it was offered would leave a remainder, and a token of
     * the approve-from-zero-only school would then reject every later zap.
     */
    function _approveExactly(ERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) != 0) token.safeApprove(spender, 0);
        token.safeApprove(spender, amount);
    }

    //============================== ADMIN FUNCTIONS ===============================

    /**
     * @notice Recover tokens sent here by mistake.
     *
     * Nothing a user zaps can be reached by this: every share a call receives is
     * locked inside that same call, and the balance is measured as a delta, so
     * a donation sitting here is never counted towards anyone's lock. Without
     * this, such a donation would simply be stuck.
     */
    function rescue(ERC20 token, address to, uint256 amount) external requiresAuth {
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    /// @notice Recover native sent here by mistake. Nothing in `zapAndLock` retains any.
    function rescueNative(address to, uint256 amount) external requiresAuth {
        SafeTransferLib.safeTransferETH(to, amount);
        emit Rescued(address(0), to, amount);
    }

    /// @dev The Teller refunds nothing, but a wrapper unwrapping to this address would.
    receive() external payable {}
}
