// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SpendingLimit} from "../libraries/SpendingLimitLib.sol";
import {SolidCashConfigLib} from "./libraries/SolidCashConfigLib.sol";
import {SpendingLimitLibV2} from "./libraries/SpendingLimitLibV2.sol";
import {ISafe} from "../interfaces/ISafe.sol";
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

/**
 * @title SolidCashStorageV2
 * @notice The single declaration of `SolidCashModuleV2`'s constants, immutables and storage.
 * @dev Both `SolidCashModuleV2` and `SolidCashModuleV2Setters` inherit this, which is what makes
 *      the core's `delegatecall` into the setters safe: the two contracts cannot disagree about a
 *      slot, because there is only one place a slot is ever declared.
 *
 *      The whole feature set does not fit one contract under EIP-170 — the configuration surface
 *      alone is ~8.6KB — so it is split the way ether.fi splits `CashModuleCore` from
 *      `CashModuleSetters`. Everything that moves value stays in the core; everything that only
 *      configures lives in the setters and is reached through the core's fallback.
 *
 *      **Immutables and delegatecall.** Immutables are baked into each contract's own bytecode, so a
 *      `delegatecall` into the setters reads the *setters'* copies, not the core's. Both are
 *      therefore constructed with the same values and `setSettersImpl` refuses an implementation
 *      whose copies differ — which is what preserves "the destination is not a parameter" across the
 *      split without demoting `settlementTreasury` to mutable storage.
 */
abstract contract SolidCashStorageV2 is Auth, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SpendingLimitLibV2 for SpendingLimit;

    // ========================================= CONSTANTS =========================================

    uint256 public constant WAD = 1e18;
    uint16 public constant MAX_BPS = 10_000;

    // The bounds every configuration change is checked against — `MAX_HAIRCUT_BPS`, `MAX_DELAY`,
    // `MAX_TARGET_LTV_BPS` and the two delay floors — are `public constant` on `SolidCashConfigLib`,
    // which is where they are enforced. One copy, readable at the library's address.

    /// @notice Decimals every USD amount and limit in this contract is expressed in.
    uint8 public constant USD_DECIMALS = 6;

    /// @notice Health factor reported for a position carrying no debt.
    uint256 public constant HF_INFINITE = type(uint256).max;

    /**
     * @notice Ceiling on the borrow rate, expressed per second in WAD.
     * @dev `100% EFFECTIVE per year, not 100% simple.` `_accrue` multiplies the *current* index by
     *      `1 + r*dt`, so successive accruals compound and the realised annual figure is
     *      `e^(r * 365 days) - 1`, not `r * 365 days`. The ceiling is therefore `ln(2)` per year
     *      rather than 1: at this rate a position exactly doubles over a year however often the
     *      contract happens to be touched. `WAD / 365 days` would have been ~171% effective while
     *      documenting itself as 100%.
     */
    uint64 public constant MAX_BORROW_APY_PER_SECOND = uint64(693_147_180_559_945_309 / uint256(365 days));

    /**
     * @notice Most tokens the allowlist may hold.
     * @dev `_positionValue` walks the whole allowlist with an external price read per token, twice
     *      per credit spend, and the lens walks it twice more per authorize read — against a 500ms
     *      hard timeout where a timeout is a decline. Unbounded growth is therefore an unbounded
     *      latency budget, and it also prices a Safe out of `deregisterSafe` and `writeOffBadDebt`.
     */
    uint256 public constant MAX_ALLOWED_TOKENS = 24;

    /**
     * @notice Most tokens one operation may touch.
     * @dev Bounds gas and the quadratic duplicate scan. A single card transaction realistically
     *      draws from one or two assets; the cap exists so a malformed call cannot make the
     *      transaction unminable.
     */
    uint256 public constant MAX_TOKENS = 8;

    // ========================================= IMMUTABLES =========================================

    /// @notice The only address `spend` and the repay paths can ever send value to.
    address public immutable settlementTreasury;

    /// @notice `SolidCashModule` v1. A Safe registered here must not have v1 enabled.
    address public immutable v1Module;

    // ========================================= STORAGE =========================================

    /// @notice The configuration implementation the core forwards unknown selectors to.
    address public settersImpl;

    /// @notice Where prices come from. Replaceable, and band-checked here regardless.
    ISolidPriceProviderV2 public priceProvider;

    mapping(address token => TokenConfig) internal _tokenConfig;
    mapping(address token => PendingTokenConfig) internal _pendingTokenConfig;

    /**
     * @notice The guardian's immediate circuit breaker, per token.
     * @dev Deliberately outside `TokenConfig`. `updateToken` and the permissionless
     *      `commitTokenConfig` both write that struct wholesale, so a `paused` field inside it was
     *      cleared by any configuration authored before the incident that caused the pause — a
     *      guardian action undone by a stranger calling a commit. Kept here it is writable by
     *      exactly one function.
     *
     *      Capacity-preserving by design: a paused token stops being sellable, lockable and
     *      acceptable as repayment, and stops contributing to borrowing power, but still counts
     *      toward liquidation capacity. Dropping it from capacity would let a guardian action tank
     *      a health factor and manufacture liquidations.
     */
    mapping(address token => bool) public tokenPaused;

    /**
     * @notice Tokens this module will accept as INCOMING payment against debt.
     * @dev Separate from `spendable`, and deliberately outside `TokenConfig` for the same reason
     *      `tokenPaused` is: every function that rewrites a token's configuration writes the whole
     *      struct, so a field inside it would be cleared by any config authored earlier — including
     *      by the permissionless `commitTokenConfig`.
     *
     *      **Why a separate list at all.** A bare `STABLE` peg is the one price no band and no
     *      staleness bound can filter (see `SolidPriceProviderV2`), and the argument that this is
     *      sound rests on such a token only ever valuing a single settlement bounded by
     *      `maxPerTxUsd`. That argument does not extend to *tender*: `repay` and `repayFromSafe`
     *      value the incoming token to decide how much debt it retires, so an uncorroborated peg
     *      accepted as tender lets a borrower settle a dollar of debt with a token that is no
     *      longer worth a dollar. Restricting tender to soUSD and the accountant's own base asset
     *      keeps the peg assumption confined to the one place it was argued for.
     *
     *      `repayFromCollateral` is deliberately NOT gated on this: it spends the borrower's own
     *      escrowed balance and prices it as collateral rather than accepting it as payment.
     */
    mapping(address token => bool) public repayTender;

    /// @dev Enumeration so the lens can value a whole position in one call.
    address[] internal _allowedTokens;

    mapping(address safe => SafeConfig) internal _safeConfig;

    /**
     * @notice Rolling daily and monthly caps, per Safe.
     * @dev Deliberately NOT inside `SafeConfig`. `deregisterSafe` deletes that struct, and a limit
     *      reachable by that `delete` would make the rolling window resettable at will: deregister,
     *      register again, and both `spentToday` and `limitRaiseDelay` are gone. Keeping it here
     *      means a returning Safe keeps what it has already spent, and `reinitialize` refuses to
     *      hand it a cap higher than the one it left with.
     */
    mapping(address safe => SpendingLimit) internal _safeLimit;

    /**
     * @notice Escrowed collateral, per Safe per token.
     * @dev **Never derived from `balanceOf(address(this))`.** All users' collateral is pooled in one
     *      contract balance; attribution lives only here. A direct transfer into this contract is
     *      therefore unattributable and unclaimable by anyone, and the invariant
     *      `sum(collateralOf) <= balanceOf(this)` holds by construction.
     */
    mapping(address safe => mapping(address token => uint256)) public collateralOf;

    /**
     * @notice Total escrowed per token, summed over every Safe.
     * @dev Maintained in lockstep with `collateralOf` through the only two functions that mutate it,
     *      so the two cannot drift. It exists solely to bound `rescueUnaccounted`: without it, a
     *      per-token accounted total would have to be recomputed by iterating every Safe, which is
     *      unbounded, and guessing it from the contract balance would make user collateral rescuable.
     */
    mapping(address token => uint256) public totalCollateral;

    /// @notice Per-Safe consumed settlement identifiers, with reversal accounting.
    mapping(address safe => mapping(bytes32 txId => BookedSpend)) public booked;

    /// @notice Per-Safe consumed reversal identifiers, so a refund cannot be replayed.
    mapping(address safe => mapping(bytes32 reversalId => bool)) public reversalConsumed;

    mapping(address safe => PendingWithdrawal) internal _pendingWithdrawal;

    /// @notice Interest index in WAD. Monotonically non-decreasing; starts at `WAD`.
    uint256 public interestIndex;

    /// @notice Last time `interestIndex` was advanced. Set in the constructor, never zero.
    uint64 public lastAccrualTimestamp;

    /// @notice Fixed borrow rate per second in WAD. Not utilization-driven.
    uint64 public borrowApyPerSecond;

    /// @notice Sum of every Safe's `normalizedDebt`, for the global exposure cap.
    uint256 public totalNormalizedDebt;

    Params internal _params;

    /**
     * @notice A reduction of `paramChangeDelay` waiting out the CURRENT `paramChangeDelay`.
     * @dev `setParams` has no delay of its own, so a delay it could shorten freely was not a delay:
     *      one transaction to zero it, the next to apply any risk-increasing change. Raising it
     *      stays immediate — that direction only ever adds objection time.
     */
    uint64 public pendingParamChangeDelay;
    uint64 public paramChangeDelayReadyAt;

    /// @notice Global kill switch for both spend paths.
    bool public isPaused;

    /**
     * @notice Guardian kill switch for `liquidate` alone.
     * @dev The missing brake. `setTokenPaused` is capacity-preserving by design, so it cannot stop
     *      a seizure driven by a price that is wrong in the LOW direction — which is exactly the
     *      direction that manufactures liquidations — and tightening `minPriceUsd` is classified
     *      risk-increasing and waits out `paramChangeDelay`. Without this there is no immediate
     *      response to a bad low print that does not go through the timelock.
     *
     *      Held deliberately narrow: it stops seizures and nothing else. Repay, deleverage and
     *      collateral withdrawal all stay open, so a position can still be rescued while it is on.
     */
    bool public liquidationsPaused;

    /**
     * @notice Once true, `settersImpl` can never change again.
     * @dev The core's fallback `delegatecall`s every unknown selector into `settersImpl`, which runs
     *      with this contract's storage and its escrowed collateral — so the setter for it is an
     *      upgrade hatch in a contract that documents itself as non-upgradeable. Sealing closes it
     *      permanently. The split exists for EIP-170 reasons, not because the configuration half is
     *      expected to change, so sealing after deployment costs nothing that was planned for.
     */
    bool public settersSealed;

    /// @notice Per-Safe kill switch for both spend paths. Used for arrears and fraud holds.
    mapping(address safe => bool) public safePaused;

    /**
     * @notice When the org-wide spending-limit waiver takes effect. 0 means never.
     * @dev Stored as an activation timestamp rather than a boolean so the delay is inherent to the
     *      representation: there is no way to express "waived right now", because waiving is the
     *      single most risk-increasing change this contract permits. Restoring is a `delete`, which
     *      takes effect immediately — the same asymmetry every other risk direction here follows.
     */
    uint64 public limitsWaiveAt;

    /// @notice Per-Safe spending-limit waiver, same representation and same asymmetry.
    mapping(address safe => uint64 waiveAt) public safeLimitsWaiveAt;

    /**
     * @notice Fee `repayFromCollateral` charges on top of the collateral it spends, per token, in bps.
     *         Unset is zero, which is repayment at par.
     * @dev Outside `TokenConfig` for the same reason `repayTender` is: `commitTokenConfig` writes that
     *      struct wholesale. `internal`, with its getter in the setters, because an auto-generated
     *      getter here would be compiled into the core too, and the core has no EIP-170 room for it.
     *      Declared last so no existing slot moves.
     */
    mapping(address token => uint16 feeBps) internal _collateralRepayFeeBps;

    // ========================================= ERRORS =========================================

    error InvalidInput();
    error Unauthorized();
    error PriceOutOfBand();
    error Paused();
    error SafeIsPaused();
    error TokenIsPaused();
    error AlreadyRegistered();
    error NotRegistered();
    error ModuleNotEnabled();
    error LegacyModuleStillEnabled();
    error TreasuryCannotRegister();
    error OnlyRegisteredSafe();
    error WrongMode();
    error TransactionAlreadyBooked();
    error TransactionNotBooked();
    error ReversalAlreadyConsumed();
    error ReversalExceedsBooked();
    error AmountZero();
    error ExceedsPerTxLimit();
    error ExceedsOrgDailyCeiling();
    error ExceedsOrgMonthlyCeiling();
    error ExceedsAvailableLimit();
    error ExceedsSafeDebtCap();
    error ExceedsGlobalDebtCap();
    error ExceedsBorrowingPower();
    error SafeExecutionFailed();
    error SettlementShortfall();
    error CollateralShortfall();
    error ArrayLengthMismatch();
    error TooManyTokens();
    error DuplicateToken();
    error TokenNotSpendable();
    error TokenNotCollateral();
    error TokenNotTender();
    error TokenAlreadyAllowed();
    error TokenNotAllowed();
    error TokenStillEscrowed();
    error PriceUnusable();
    error TokenDecimalsMismatch();
    error NoDebt();
    error HasDebt();
    error HealthWorsened();
    error NotLiquidatable();
    error LiquidationGraceNotElapsed();
    error PositionNotFullyPriced();
    error NoPendingWithdrawal();
    error WithdrawalNotReady();
    error WithdrawalPending();
    error NoPendingConfig();
    error ConfigNotReady();
    error InvalidRiskParams();
    error ExceedsForcedSpendCap();
    error LiquidationsArePaused();
    error SettersAreSealed();
    error TooManyAllowedTokens();

    // ========================================= EVENTS =========================================

    event SafeRegistered(address indexed safe, uint256 dailyLimitUsd, uint256 monthlyLimitUsd, int256 timezoneOffset);
    event SafeDeregistered(address indexed safe);
    event ModeSet(address indexed safe, Mode from, Mode to, uint64 effectiveAt);

    event Spend(address indexed safe, bytes32 indexed txId, uint256 totalAmountUsd);
    event SpendToken(
        address indexed safe,
        bytes32 indexed txId,
        address indexed token,
        uint256 amountUsd,
        uint256 tokenAmount,
        uint256 priceUsd
    );
    event CreditSpend(address indexed safe, bytes32 indexed txId, uint256 amountUsd, uint256 interestIndexAt);
    event CollateralLocked(address indexed safe, address indexed token, uint256 tokenAmount, uint256 valueUsd);
    event ForcedSpendBooked(address indexed safe, bytes32 indexed txId, uint256 amountUsd, bool isCredit);
    event BookedSpendAdjusted(address indexed safe, bytes32 indexed txId, uint256 fromUsd, uint256 toUsd);
    event SpendReversed(address indexed safe, bytes32 indexed txId, bytes32 indexed reversalId, uint256 amountUsd);

    event Repaid(address indexed safe, address indexed token, uint256 tokenAmount, uint256 amountUsd, address payer);
    event RepaidFromCollateral(address indexed safe, address indexed token, uint256 tokenAmount, uint256 amountUsd);
    /// @dev Emitted beside `RepaidFromCollateral`, whose `tokenAmount` includes this fee, when the fee is non-zero.
    event CollateralRepayFeeCharged(address indexed safe, address indexed token, uint256 feeTokenAmount);
    event CollateralWithdrawRequested(address indexed safe, address indexed token, uint256 amount, uint64 readyAt);
    event CollateralWithdrawCancelled(address indexed safe);
    event CollateralWithdrawn(address indexed safe, address indexed token, uint256 amount);

    event HealthStampSet(address indexed safe, uint64 unhealthySince);
    event Liquidated(
        address indexed safe,
        address indexed liquidator,
        address indexed collateralToken,
        uint256 repaidUsd,
        uint256 collateralSeized
    );
    event BadDebtWrittenOff(address indexed safe, uint256 amountUsd);

    event InterestAccrued(uint256 indexed newIndex, uint64 at);
    event BorrowApySet(uint64 previous, uint64 current);
    event SpendingLimitDecreased(address indexed safe, uint256 dailyLimitUsd, uint256 monthlyLimitUsd);
    event SpendingLimitIncreaseRequested(
        address indexed safe, uint256 dailyLimitUsd, uint256 monthlyLimitUsd, uint64 activationTime
    );
    event SpendingLimitIncreaseCancelled(address indexed safe);

    event PausedSet(bool isPaused);
    event SafePausedSet(address indexed safe, bool isPaused);
    event TokenPausedSet(address indexed token, bool isPaused);
    event RepayTenderSet(address indexed token, bool allowed);
    event CollateralRepayFeeSet(address indexed token, uint16 feeBps);
    event PriceProviderSet(address indexed priceProvider);
    event ParamsSet(Params params);
    event TokenAllowed(address indexed token, TokenConfig config);
    event TokenConfigScheduled(address indexed token, TokenConfig config, uint64 activationTime);
    event TokenConfigApplied(address indexed token, TokenConfig config);
    event TokenConfigCancelled(address indexed token);
    event TokenDisallowed(address indexed token);
    event UnaccountedRescued(address indexed token, uint256 amount);
    event SettersImplSet(address indexed impl);
    event SettersSealed();
    event LiquidationsPausedSet(bool isPaused);
    event ParamChangeDelayReductionRequested(uint64 newDelay, uint64 activationTime);
    event ParamChangeDelayReductionCancelled();
    event ParamChangeDelaySet(uint64 paramChangeDelay);
    event LimitsWaiveRequested(uint64 activationTime);
    event LimitsRestored();
    event SafeLimitsWaiveRequested(address indexed safe, uint64 activationTime);
    event SafeLimitsRestored(address indexed safe);

    // ========================================= SHARED ACCRUAL =========================================
    // Lives here rather than in the core because the setters' rate change must accrue before it
    // writes: without that, a new rate would retroactively reprice every second already elapsed.

    /// @notice The interest index as of now, without writing it.
    function currentIndex() public view returns (uint256) {
        uint256 idx = interestIndex;
        uint64 last = lastAccrualTimestamp;
        if (block.timestamp <= last || borrowApyPerSecond == 0 || totalNormalizedDebt == 0) return idx;
        return idx + idx.mulDiv(uint256(borrowApyPerSecond) * (block.timestamp - last), WAD, Math.Rounding.Floor);
    }

    /**
     * @dev Advances the interest index to now.
     *
     *      Skipped entirely while no debt exists, so an idle protocol does not inflate the index for
     *      nothing — the timestamp still advances, so no interest is lost or double-counted.
     */
    function _accrue() internal {
        uint64 last = lastAccrualTimestamp;
        if (block.timestamp == last) return;

        uint256 idx = interestIndex;
        uint64 apy = borrowApyPerSecond;
        if (apy != 0 && totalNormalizedDebt != 0) {
            uint256 grown = idx + idx.mulDiv(uint256(apy) * (block.timestamp - last), WAD, Math.Rounding.Floor);
            interestIndex = grown;
            emit InterestAccrued(grown, uint64(block.timestamp));
        }
        lastAccrualTimestamp = uint64(block.timestamp);
    }

    /// @notice The Safe's debt in 6-decimal USD, including accrued interest. Rounds UP.
    function debtUsd(address safe) public view returns (uint256) {
        return _safeConfig[safe].normalizedDebt.mulDiv(currentIndex(), WAD, Math.Rounding.Ceil);
    }

    /// @notice Total outstanding debt across every Safe, in 6-decimal USD.
    function totalDebtUsd() public view returns (uint256) {
        return totalNormalizedDebt.mulDiv(currentIndex(), WAD, Math.Rounding.Ceil);
    }

    // ========================================= INTERNAL: BOOKKEEPING =========================================

    /**
     * @dev The pause gates on their own.
     *
     *      Split out because `bookForcedSpend` must honour them without taking the rest of
     *      `_requireSpendable`: a mandatory spend has to be recordable even for a Safe that has
     *      revoked the module, but "the guardian has pulled the switch" is never a state in which
     *      new debt should appear. Skipping these was what made the global pause useless against
     *      the one path a compromised credit-spender key least needs.
     */
    function _requireNotPaused(address safe) internal view {
        if (isPaused) revert Paused();
        if (safePaused[safe]) revert SafeIsPaused();
    }

    /// @dev The gate set shared by both spend paths, in a fixed order the dry-runs mirror.
    function _requireSpendable(address safe) internal view returns (SafeConfig storage $) {
        _requireNotPaused(safe);

        $ = _safeConfig[safe];
        if (!$.registered) revert NotRegistered();

        // Re-checked on every debit because revoking the module is the user's instant
        // consent-withdrawal mechanism, not something to cache at registration.
        if (!ISafe(safe).isModuleEnabled(address(this))) revert ModuleNotEnabled();
        // Fail closed toward working v1 if a migrated Safe ever re-enables it: this module goes
        // inert rather than running a second, independent cap set alongside v1's.
        if (ISafe(safe).isModuleEnabled(v1Module)) revert LegacyModuleStillEnabled();
    }

    /**
     * @notice Whether `safe`'s *policy* limits are currently waived.
     * @dev Covers the per-transaction cap, the rolling daily and monthly windows, and the per-Safe
     *      debt cap — the bounds that express how much Solid is willing to let one user spend.
     *
     *      It deliberately does **not** cover two things, because they are not policy:
     *        - the **borrowing-power / collateral requirement**, which is the user's own solvency. A
     *          credit spend with limits waived still has to be backed by locked collateral.
     *        - **`maxGlobalDebtUsd`**, which is Solid's total float solvency rather than a
     *          per-user allowance. Waiving one user's limits must not let them consume the treasury.
     *
     *      Without that boundary the waiver would not be "let this user spend more", it would be
     *      "remove the contract as a line of defence against a compromised backend" — which is the
     *      one thing every cap in this module exists to prevent.
     */
    function limitsWaived(address safe) public view returns (bool) {
        uint64 org = limitsWaiveAt;
        if (org != 0 && block.timestamp >= org) return true;
        uint64 own = safeLimitsWaiveAt[safe];
        return own != 0 && block.timestamp >= own;
    }

    /// @dev Consumes `txId`, charges the shared rolling limit, and enforces the per-transaction cap.
    function _bookOperation(address safe, bytes32 txId, uint256 totalUsd, bool isCredit) internal {
        // Replay protection is never waivable: it is correctness, not policy. Keyed on `exists`
        // rather than on a non-zero amount, because an amount is writable and a marker must not be.
        if (booked[safe][txId].exists) revert TransactionAlreadyBooked();
        uint72 amount = _toU72(totalUsd);
        booked[safe][txId] = BookedSpend(amount, amount, 0, isCredit, false, true);

        if (limitsWaived(safe)) {
            // Still accumulated, so restoring limits does not hand the user a fresh window and ops
            // keeps a true picture of volume while the waiver is in force.
            _safeLimit[safe].recordSpend(totalUsd);
            return;
        }

        if (totalUsd > _params.maxPerTxUsd) revert ExceedsPerTxLimit();
        if (totalUsd > _maxCanSpendUsd(safe)) revert ExceedsAvailableLimit();
        _safeLimit[safe].spend(totalUsd);
    }

    /**
     * @dev Reduces a Safe's outstanding forced-spend figure when a forced booking is unwound.
     *
     *      `forcedDebtUsd` is the ops signal for liability booked without our approval. It used to
     *      only ever grow — a reversal, a downward adjustment or a write-off all left it standing —
     *      so it drifted away from the truth in the one direction that matters.
     */
    function _reduceForcedDebt(SafeConfig storage $, uint256 amountUsd) internal {
        uint256 forced = $.forcedDebtUsd;
        $.forcedDebtUsd = forced > amountUsd ? forced - amountUsd : 0;
    }

    function _requireDebtCaps(SafeConfig storage $, address safe) internal view {
        if (!limitsWaived(safe) && _debtOf($) > _params.maxDebtPerSafeUsd) revert ExceedsSafeDebtCap();
        // Never waivable: this is Solid's float solvency, not one user's allowance.
        if (totalDebtUsd() > _params.maxGlobalDebtUsd) revert ExceedsGlobalDebtCap();
    }

    /// @dev Debt in USD from a storage pointer, using the already-accrued index. Rounds UP.
    function _debtOf(SafeConfig storage $) internal view returns (uint256) {
        return $.normalizedDebt.mulDiv(currentIndex(), WAD, Math.Rounding.Ceil);
    }

    /// @dev Adds debt, normalising UP so the recorded obligation is never understated.
    function _addDebt(SafeConfig storage $, uint256 amountUsd) internal {
        uint256 norm = amountUsd.mulDiv(WAD, interestIndex, Math.Rounding.Ceil);
        if (norm == 0) revert AmountZero();
        $.normalizedDebt += norm;
        totalNormalizedDebt += norm;
    }

    /**
     * @dev Reduces debt, normalising DOWN so a payer is never over-credited.
     *
     *      A payment covering the whole (ceil-rounded) debt zeroes the position outright rather than
     *      subtracting, which is what stops a one-wei dust remainder surviving a "full" repayment —
     *      the artefact `DebtManagerCore._liquidateUser` has to patch after the fact.
     */
    function _reduceDebt(SafeConfig storage $, uint256 amountUsd) internal {
        uint256 norm = $.normalizedDebt;
        if (norm == 0) return;

        if (amountUsd >= norm.mulDiv(interestIndex, WAD, Math.Rounding.Ceil)) {
            $.normalizedDebt = 0;
            totalNormalizedDebt -= norm;
            return;
        }

        uint256 reduction = amountUsd.mulDiv(WAD, interestIndex, Math.Rounding.Floor);
        if (reduction > norm) reduction = norm;
        $.normalizedDebt = norm - reduction;
        totalNormalizedDebt -= reduction;
    }

    /**
     * @dev Keeps the liquidation grace stamp self-maintaining on every path that moves health.
     *
     *      **The stamp is only SET when the position is fully priced.** `_positionValue` drops a
     *      token it cannot price from capacity rather than failing, so during a feed outage every
     *      credit position reads at health 0 — and a stamp written from that reading is not an
     *      observation that the position went bad, it is an observation that the oracle went down.
     *      Nothing can be liquidated during the outage (`_requireLiquidatable` refuses on
     *      `!fullyPriced`), but the grace clock would have run out meanwhile, so the first block
     *      after recovery would find every marginal position immediately seizable with no grace at
     *      all. That is precisely the bad-print cascade the grace period exists to prevent.
     *
     *      CLEARING stays unconditional. An understated position that still reads at or above 1 is
     *      healthy by a stricter measure than the real one, so acting on it is always safe, and a
     *      user must never be left stamped because a feed they do not control is down.
     */
    function _refreshHealthStamp(address safe, SafeConfig storage $) internal {
        (uint256 hf, bool fullyPriced) = _healthFactor(safe, $);
        uint64 stamp = $.unhealthySince;

        if (hf >= WAD) {
            if (stamp != 0) {
                $.unhealthySince = 0;
                emit HealthStampSet(safe, 0);
            }
        } else if (stamp == 0 && fullyPriced) {
            $.unhealthySince = uint64(block.timestamp);
            emit HealthStampSet(safe, uint64(block.timestamp));
        }
    }

    // ========================================= INTERNAL: COLLATERAL =========================================

    /**
     * @dev Locks only the collateral the position is short of, at a buffered LTV.
     *
     *      Sizing uses each token's own ltv scaled by `targetLtvBps`, so one global parameter serves
     *      an 85% asset and a 60% one correctly. The gain is then credited at the token's REAL ltv,
     *      which is what leaves the position below its bound rather than exactly at it: sizing at the
     *      bound would open every position at maximum leverage.
     *
     *      Locks nothing when existing collateral already covers the debt — appreciation, a repay or
     *      a reversal can all make a later spend free.
     *
     *      **`requireFull` is the difference between the two callers.** `spendCredit` and
     *      `adjustBookedSpend` must abort on a shortfall, so they pass true. `bookForcedSpend` must
     *      not: the liability is already real. It passes false, which locks whatever the Safe can
     *      actually cover and keeps it. Reverting the whole loop instead — which is what an
     *      all-or-nothing lock behind a `try/catch` did — meant a Safe holding $90 against a $100
     *      forced spend ended up with ZERO locked, when $90 was strictly better for Solid.
     */
    function _lockForShortfall(address safe, SafeConfig storage $, address[] calldata preference, bool requireFull)
        internal
    {
        uint256 debt = _debtOf($);
        (uint256 power,,) = _positionValue(safe);
        if (power >= debt) return;

        uint256 needed = debt - power;

        for (uint256 i = 0; i < preference.length && needed != 0; ++i) {
            uint256 gained = _lockOne(safe, preference[i], needed, requireFull);
            needed = needed > gained ? needed - gained : 0;
        }

        if (requireFull && needed != 0) revert CollateralShortfall();
    }

    /**
     * @dev Locks at most enough of one token to produce `needed` USD of borrowing power, and reports
     *      the power actually gained.
     *
     *      Sizing uses the token's own `ltv` scaled by `targetLtvBps`, so one global parameter serves
     *      an 85% asset and a 60% one correctly. The gain is then credited at the token's **real**
     *      `ltv`, which is what leaves the position below its bound rather than exactly at it —
     *      sizing at the bound would open every position at maximum leverage, with the deleverage
     *      cron relevant from the very first spend.
     */
    function _lockOne(address safe, address token, uint256 needed, bool strict)
        internal
        returns (uint256 gainedPower)
    {
        TokenConfig storage cfg = _tokenConfig[token];
        if (!cfg.collateral || tokenPaused[token] || cfg.ltv == 0) return 0;

        uint256 price;
        {
            // Strict, never capped: an understated price would lock MORE of the user's balance than
            // the shortfall warrants, so an out-of-band token is skipped rather than over-drawn.
            (uint256 p, bool usable, bool inBand) = _price(token, cfg);
            if (!usable || !inBand) return 0;
            price = p;
        }

        uint256 unit = 10 ** cfg.tokenDecimals;
        uint256 amount;
        {
            uint256 ltvEff = uint256(cfg.ltv).mulDiv(_params.targetLtvBps, MAX_BPS, Math.Rounding.Floor);
            if (ltvEff == 0) return 0;
            // Collateral VALUE required to produce `needed` at the buffered ltv, then the token units
            // for that value. Both round up, so the lock is never short.
            uint256 valueNeeded = needed.mulDiv(WAD, ltvEff, Math.Rounding.Ceil);
            amount = valueNeeded.mulDiv(unit, price, Math.Rounding.Ceil);
        }
        {
            uint256 loose = IERC20(token).balanceOf(safe);
            if (amount > loose) amount = loose;
        }
        if (amount == 0) return 0;

        uint256 received = _pullCollateral(safe, token, amount, strict);
        if (received == 0) return 0;

        uint256 gainedUsd = received.mulDiv(price, unit, Math.Rounding.Floor);
        gainedPower = gainedUsd.mulDiv(cfg.ltv, WAD, Math.Rounding.Floor);

        emit CollateralLocked(safe, token, received, gainedUsd);
    }

    /**
     * @dev Moves collateral from the Safe into escrow and credits the **measured delta**.
     *
     *      Crediting the observed increase rather than the requested amount is what makes a
     *      fee-on-transfer or otherwise non-standard token safe here, and it is the same discipline
     *      the debit path applies to the treasury side.
     */
    function _pullCollateral(address safe, address token, uint256 amount, bool strict)
        internal
        returns (uint256 received)
    {
        uint256 before = IERC20(token).balanceOf(address(this));
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, address(this), amount);

        // `strict` aborts the whole operation on a failed pull; the tolerant form reports failure so
        // a best-effort lock can move on to the next token. The tolerant form is what removes the
        // `try/catch` trampoline this used to need — and with it, the one path that ran the whole
        // collateral loop outside `nonReentrant`.
        if (strict) _execFromSafe(safe, token, data);
        else if (!_tryExecFromSafe(safe, token, data)) return 0;

        received = IERC20(token).balanceOf(address(this)) - before;

        // Credit the measured delta, but never more than was asked for. Measuring is what makes a
        // fee-on-transfer token safe; clamping is what stops an unrelated inbound transfer landing
        // during the Safe's `transfer` from being attributed to this Safe. Any excess stays
        // unaccounted, which is exactly what `rescueUnaccounted` exists for.
        if (received > amount) received = amount;
        if (received != 0) _creditCollateral(safe, token, received);
    }

    /// @dev The only place `collateralOf` grows. Keeps `totalCollateral` in lockstep by construction.
    function _creditCollateral(address safe, address token, uint256 amount) internal {
        collateralOf[safe][token] += amount;
        totalCollateral[token] += amount;
    }

    /// @dev The only place `collateralOf` shrinks. Every caller clamps `amount` to the Safe's own
    ///      balance immediately beforehand, so the subtraction cannot underflow.
    function _debitCollateral(address safe, address token, uint256 amount) internal {
        collateralOf[safe][token] -= amount;
        totalCollateral[token] -= amount;
    }

    /**
     * @dev Values a whole position under this module's own rules.
     *
     *      The two figures answer deliberately different questions, and conflating them is how a
     *      guardian action or a dead feed turns into an unjustified liquidation:
     *
     *        - **power** is what we will lend against: eligible, unpaused, priced collateral only.
     *        - **capacity** is what we could seize: every escrowed balance, regardless of the
     *          `collateral` and `paused` flags, because those are decisions about future risk and
     *          must not retroactively reprice an existing position.
     *
     *      `fullyPriced` is false as soon as any held token cannot be priced, and liquidation
     *      refuses on it — otherwise one dead feed would understate capacity and let a liquidator
     *      seize a different, perfectly healthy asset at a bonus.
     */
    function _positionValue(address safe)
        internal
        view
        returns (uint256 powerUsd, uint256 capacityUsd, bool fullyPriced)
    {
        fullyPriced = true;
        uint256 length = _allowedTokens.length;

        for (uint256 i = 0; i < length; ++i) {
            address token = _allowedTokens[i];
            uint256 amount = collateralOf[safe][token];
            if (amount == 0) continue;

            TokenConfig storage cfg = _tokenConfig[token];
            (uint256 price, bool usable, bool inBand) = _price(token, cfg);
            if (!usable) {
                fullyPriced = false;
                continue;
            }
            // A capped price understates the position, which is safe for lending but NOT for
            // liquidation: it would drop the reported health factor and let a liquidator seize a
            // perfectly healthy asset. So an out-of-band token makes the whole position
            // un-liquidatable while still counting, conservatively, toward borrowing power.
            if (!inBand) fullyPriced = false;

            uint256 valueUsd = amount.mulDiv(price, 10 ** cfg.tokenDecimals, Math.Rounding.Floor);
            capacityUsd += valueUsd.mulDiv(cfg.liquidationThreshold, WAD, Math.Rounding.Floor);
            if (cfg.collateral && !tokenPaused[token]) {
                powerUsd += valueUsd.mulDiv(cfg.ltv, WAD, Math.Rounding.Floor);
            }
        }
    }

    /**
     * @dev WAD health factor, and whether every token the Safe holds could actually be priced.
     *
     *      The second return is not decoration: an unpriced token is silently dropped from
     *      capacity, so `hf` alone cannot distinguish "this position is underwater" from "we
     *      currently cannot see it". Every caller that writes state on the strength of a low
     *      reading has to tell those apart.
     */
    function _healthFactor(address safe, SafeConfig storage $)
        internal
        view
        returns (uint256 hf, bool fullyPriced)
    {
        uint256 debt = _debtOf($);
        if (debt == 0) return (HF_INFINITE, true);

        uint256 capacity;
        (, capacity, fullyPriced) = _positionValue(safe);
        hf = capacity.mulDiv(WAD, debt, Math.Rounding.Floor);
    }

    // ========================================= INTERNAL: PRICING =========================================

    /**
     * @dev The module's own view of a price: capped at its ceiling, rejected below its floor,
     *      rejected when stale by its own bound.
     *
     *      **Capping rather than reverting is the v1 fix.** v1 reverted outside its band, which on a
     *      monotonically appreciating asset is a scheduled outage — soUSD's ceiling is eventually
     *      crossed by legitimate yield, and soUSD is the primary asset. Understating value is
     *      conservative in *both* directions here: it reduces debit spending power and it reduces
     *      borrowing power, so a stale ceiling degrades to "power stops growing" instead of breaking
     *      every spend.
     *
     *      The staleness bound is enforced here, not merely in the provider, because the provider is
     *      upgradeable: a band catches an absurd price but not a stale-but-plausible one, which is
     *      precisely the exploitable case for a volatile asset.
     *
     *      **The ceiling drifts.** A static ceiling on a yield-bearing share is a scheduled outage
     *      with a computable date: soUSD only goes up, so `maxPriceUsd` is eventually crossed by
     *      legitimate yield, and above it every path that *divides* by a price reverts — debit
     *      settlement, collateral locking, all three repays and liquidation. Capping saved quoting
     *      and nothing else. So the ceiling is quoted at an anchor and allowed to rise at a
     *      configured rate: what it bounds is the rate of change, which is what a bad print has to
     *      beat, rather than a level that honest appreciation eventually beats on its own.
     *
     *      **The provider read is bounded and failure-tolerant.** The provider documents itself as
     *      never reverting, but two of its four families reach a contract nobody here controls. A
     *      revert propagating out of this function would take `_positionValue` with it, and with
     *      that every credit spend, every liquidation and the lens' single authorize read — for
     *      every user, over one asset they may not even hold.
     */
    function _price(address token, TokenConfig storage cfg)
        internal
        view
        returns (uint256 price, bool usable, bool inBand)
    {
        if (cfg.tokenDecimals == 0) return (0, false, false);

        (uint256 raw, uint64 updatedAt, bool providerUsable) =
            SolidCashConfigLib.readProvider(address(priceProvider), token);
        if (!providerUsable || raw == 0) return (0, false, false);
        if (raw < cfg.minPriceUsd) return (0, false, false);

        // Enforced here, not merely in the provider, because the provider is upgradeable: a band
        // catches an absurd price but not a stale-but-plausible one, which is precisely the
        // exploitable case for a volatile asset.
        if (cfg.maxStalenessSeconds != 0) {
            uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            if (age > cfg.maxStalenessSeconds) return (0, false, false);
        }

        uint256 ceiling = SolidCashConfigLib.effectiveCeiling(cfg);
        if (raw > ceiling) return (ceiling, true, false);
        return (raw, true, true);
    }

    /**
     * @dev The **value-moving** price: strictly inside the band, or it reverts.
     *
     *      Capping must never be used where the price *divides* a USD obligation to produce a token
     *      amount, because an understated price takes MORE of the user's tokens for the same dollar
     *      figure. Debit settlement, collateral locking, collateral repayment and liquidation
     *      seizure are all that shape, so all four take this accessor. The failure mode is a
     *      declined operation, never a silent over-collection.
     */
    function _settlementPrice(address token, TokenConfig storage cfg) internal view returns (uint256) {
        (uint256 price, bool usable, bool inBand) = _price(token, cfg);
        if (!usable) revert PriceUnusable();
        if (!inBand) revert PriceOutOfBand();
        return price;
    }

    // ========================================= INTERNAL: MISC =========================================

    function _currentMode(SafeConfig storage $) internal view returns (Mode) {
        if ($.incomingModeStartTime != 0 && block.timestamp >= $.incomingModeStartTime) return $.incomingMode;
        return $.mode;
    }

    /**
     * @dev Requires `$`'s effective mode to permit the `path` funding route.
     *
     *      `Smart` permits both; each exclusive mode permits only its own. Split out so the two
     *      call sites cannot drift — a `spend` that accepted `Smart` while `spendCredit` did not
     *      would be a silent, one-directional feature, and the failure would look like a decline
     *      rather than like a bug.
     *
     *      `path` is only ever `Debit` or `Credit` at a call site: it names a funding route, not a
     *      mode, and there is no route called "Smart".
     */
    function _requirePath(SafeConfig storage $, Mode path) internal view {
        Mode m = _currentMode($);
        if (m != path && m != Mode.Smart) revert WrongMode();
    }

    /**
     * @dev Risk rank, and the whole of the mode-switch delay rule: a switch is delayed iff it
     *      RAISES the rank, i.e. iff it widens what a compromised spender key can reach.
     *
     *      Debit sells only what the Safe already holds loose. Credit adds locking collateral and
     *      booking debt. Smart adds both. That is the enum's own declaration order, which is why
     *      this is a cast rather than a lookup — but it is a named function because the ordering is
     *      load-bearing, and a member appended to `Mode` without reading this would inherit the
     *      highest rank silently.
     */
    function _modeRank(Mode m) internal pure returns (uint8) {
        return uint8(m);
    }

    /// @dev Flushes a matured mode switch into storage so later reads do not depend on the clock.
    function _settleMode(SafeConfig storage $) internal {
        if ($.incomingModeStartTime != 0 && block.timestamp >= $.incomingModeStartTime) {
            $.mode = $.incomingMode;
            $.incomingModeStartTime = 0;
        }
    }

    /**
     * @dev Headroom under the Safe's own windows, clamped by the live org ceilings.
     *      Clamping on read rather than only at registration is what makes lowering a ceiling a
     *      real, immediate control over Safes that registered under a looser one.
     */
    function _maxCanSpendUsd(address safe) internal view returns (uint256) {
        return SpendingLimitLibV2.maxCanSpendClamped(
            _safeLimit[safe], _params.maxDailyLimitUsd, _params.maxMonthlyLimitUsd
        );
    }

    /// @dev Executes one call from the Safe and requires it to have reported success.
    function _execFromSafe(address safe, address to, bytes memory data) internal {
        bool ok = ISafe(safe).execTransactionFromModule(to, 0, data, ISafe.Operation.Call);
        if (!ok) revert SafeExecutionFailed();
    }

    /**
     * @dev `_execFromSafe` that reports failure instead of reverting, for the best-effort lock.
     *
     *      Checks the return-data length as well as the success flag, so an address with no code —
     *      which succeeds and returns nothing — reads as a failed pull rather than a decode revert.
     *
     *      The returned word is compared raw rather than passed through `abi.decode(ret, (bool))`,
     *      because that decode reverts on any word other than 0 or 1. The callee here is the user's
     *      own Safe, so a non-conforming one would otherwise be able to turn a *tolerant* helper
     *      into a revert — which is the one thing this function exists not to do. Anything that is
     *      not exactly `true` reads as a failed pull.
     */
    function _tryExecFromSafe(address safe, address to, bytes memory data) internal returns (bool) {
        (bool ok, bytes memory ret) = safe.call(
            abi.encodeWithSelector(ISafe.execTransactionFromModule.selector, to, uint256(0), data, ISafe.Operation.Call)
        );
        if (!ok || ret.length != 32) return false;

        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return word == 1;
    }

    function _requireSafeOrCreditSpender(address safe) internal view {
        if (msg.sender == safe) return;
        if (!isAuthorized(msg.sender, msg.sig)) revert Unauthorized();
    }

    /**
     * @dev Rejects duplicate tokens.
     *
     *      A duplicate would be double-counted by the per-token balance-delta checks: the second
     *      transfer's "before" balance already includes the first, so both could appear satisfied
     *      while less value moved than was booked. Quadratic, which is why `MAX_TOKENS` is small.
     */
    function _requireNoDuplicates(address[] calldata tokens) internal pure {
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; ++i) {
            for (uint256 j = i + 1; j < length; ++j) {
                if (tokens[i] == tokens[j]) revert DuplicateToken();
            }
        }
    }

    function _toU72(uint256 value) internal pure returns (uint72) {
        if (value > type(uint72).max) revert InvalidInput();
        return uint72(value);
    }

    modifier onlyRegisteredSafe() {
        if (!_safeConfig[msg.sender].registered) revert OnlyRegisteredSafe();
        _;
    }

    /// @dev Restricts to the owner directly, bypassing the authority. Used where a selector must not
    ///      be grantable to a role at all, however the authority is configured.
    function _requireOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    // ========================================= AUTH OVERRIDES =========================================

    /**
     * @dev solmate's check, moved out of the modifier body and otherwise unchanged — same
     *      `isAuthorized`, same `"UNAUTHORIZED"` revert data. A modifier is inlined at every use, so
     *      the setters carried the revert-string check once per admin function; one internal call
     *      each is what pays for `setCollateralRepayFee` under EIP-170.
     */
    modifier requiresAuth() override {
        _requireAuth();
        _;
    }

    function _requireAuth() internal view {
        require(isAuthorized(msg.sender, msg.sig), "UNAUTHORIZED");
    }

    /**
     * @notice Hands the module to a new owner. **Owner only, never grantable.**
     * @dev solmate's implementation is `requiresAuth`, which means the external authority can hand
     *      this selector to a role — and `owner` is the one address `setSettersImpl` and
     *      `sealSetters` answer to. A role with this capability could therefore take ownership and
     *      then replace the entire configuration half (and with it the treatment of every escrowed
     *      balance) in the window before `sealSetters` runs, without ever holding the owner key.
     *
     *      Keeping the power to change the owner inside the owner closes that, and it costs nothing:
     *      the owner is a timelocked multisig that can always call this directly.
     */
    function transferOwnership(address newOwner) public virtual override {
        _requireOwner();
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }

    /**
     * @notice Replaces the authority contract. **Owner only, never grantable.**
     * @dev Same reasoning as `transferOwnership`, one step removed: solmate lets the current
     *      authority authorise its own replacement, so a role granted this selector could install an
     *      authority that grants itself everything else. Every capability in this module is
     *      downstream of which authority answers `canCall`, so that decision belongs to the owner
     *      alone.
     */
    function setAuthority(Authority newAuthority) public virtual override {
        _requireOwner();
        authority = newAuthority;
        emit AuthorityUpdated(msg.sender, newAuthority);
    }
}
