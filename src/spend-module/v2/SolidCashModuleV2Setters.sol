// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

import {SolidCashConfigLib} from "./libraries/SolidCashConfigLib.sol";
import {SolidCreditMathLib} from "./libraries/SolidCreditMathLib.sol";
import {SolidCashStorageV2} from "./SolidCashStorageV2.sol";

/**
 * @title SolidCashModuleV2Setters
 * @notice The configuration half of `SolidCashModuleV2`, reached only through the core's fallback.
 * @dev **Never called directly and never holds funds.** It is `delegatecall`ed by the core, so every
 *      read and write lands in the core's storage and `msg.sender` is the original caller — which is
 *      what makes `requiresAuth` here mean exactly what it means there.
 *
 *      It exists purely so the whole feature set fits EIP-170: the configuration surface is ~8.6KB
 *      of validation, struct decoding and pending-change machinery that no value-moving path needs.
 *
 *      Deployed with the same `settlementTreasury` and `v1Module` as the core, and the core's
 *      `setSettersImpl` verifies that before accepting it.
 */
contract SolidCashModuleV2Setters is SolidCashStorageV2 {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /**
     * @dev This contract's own address, captured at construction.
     *
     *      Under `delegatecall` from the core, `address(this)` is the *core*, so comparing against
     *      this captured value distinguishes the intended execution context from a direct call.
     *      Every function here is gated on that difference: a direct call would otherwise operate on
     *      this contract's own empty storage — harmless to funds, but it would emit configuration
     *      events that ops dashboards and reconciliation would read as real changes.
     */
    address private immutable _self;

    error OnlyViaCore();

    constructor(address _owner, address _authority, address _settlementTreasury, address _v1Module)
        Auth(_owner, Authority(_authority))
    {
        if (_settlementTreasury == address(0) || _v1Module == address(0)) revert InvalidInput();
        settlementTreasury = _settlementTreasury;
        v1Module = _v1Module;
        _self = address(this);
    }

    /// @dev Reverts on a direct call; passes only when running as the core's implementation.
    modifier onlyViaCore() {
        if (address(this) == _self) revert OnlyViaCore();
        _;
    }

    // ========================================= GUARDIAN =========================================

    /// @notice Halts both spend paths. Exits, repays and liquidation stay open.
    function pause() external onlyViaCore requiresAuth {
        isPaused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyViaCore requiresAuth {
        isPaused = false;
        emit PausedSet(false);
    }

    /// @notice Halts or resumes spending for one Safe. Exits and repays stay open.
    function setSafePaused(address safe, bool paused) external onlyViaCore requiresAuth {
        safePaused[safe] = paused;
        emit SafePausedSet(safe, paused);
    }

    /**
     * @notice Halts or resumes one token, immediately. The fast response to a suspect feed.
     * @dev Deliberately **capacity-preserving**: a paused token stops being sellable, stops being
     *      lockable, and stops contributing to borrowing power, but still counts toward liquidation
     *      capacity. Dropping it from capacity would let a guardian action tank a health factor and
     *      manufacture liquidations, which is exactly the outcome a circuit breaker must not have.
     */
    function setTokenPaused(address token, bool paused) external onlyViaCore requiresAuth {
        if (_tokenConfig[token].tokenDecimals == 0) revert TokenNotAllowed();
        tokenPaused[token] = paused;
        emit TokenPausedSet(token, paused);
    }

    /**
     * @notice Halts or resumes seizures. The brake `setTokenPaused` deliberately cannot be.
     * @dev A price wrong in the LOW direction understates capacity, drops the health factor and
     *      lets a liquidator seize a discounted asset at a bonus. `setTokenPaused` is
     *      capacity-preserving precisely so a guardian action cannot manufacture a liquidation —
     *      which is also why it cannot stop one — and tightening `minPriceUsd` is classified
     *      risk-increasing and waits out `paramChangeDelay`. Without this there was no immediate
     *      answer to a bad low print that did not go through the timelock.
     *
     *      Narrow on purpose: it stops seizures and nothing else. Repay, deleverage and collateral
     *      withdrawal all stay open, so leaving it on freezes bad debt rather than trapping users.
     */
    function setLiquidationsPaused(bool paused) external onlyViaCore requiresAuth {
        liquidationsPaused = paused;
        emit LiquidationsPausedSet(paused);
    }

    /**
     * @notice Allows or refuses a token as INCOMING payment against debt.
     * @dev Owner-gated rather than guardian-gated: this is a statement about which prices this
     *      module is willing to *accept value at*, which is a risk-parameter decision rather than an
     *      incident response. `setTokenPaused` remains the immediate lever, and it already refuses
     *      tender for a paused token.
     *
     *      Kept outside `TokenConfig` deliberately — see `repayTender`'s declaration for why a flag
     *      inside that struct would be cleared by the permissionless `commitTokenConfig`.
     *
     *      Intended launch set: soUSD and USDC.e. USDC.e is soUSD's accountant base, so accepting it
     *      at its peg asserts nothing the vault's own NAV does not already assert. USDT is spendable
     *      and is NOT tender: its price here is a bare peg with nothing observing it, which is sound
     *      for valuing one bounded settlement and not sound for deciding how much debt a payment
     *      retires.
     */
    function setRepayTender(address token, bool allowed) external onlyViaCore requiresAuth {
        if (_tokenConfig[token].tokenDecimals == 0) revert TokenNotAllowed();
        repayTender[token] = allowed;
        emit RepayTenderSet(token, allowed);
    }

    /**
     * @notice Sets the fee `repayFromCollateral` charges for one collateral token. Zero, the
     *         default, is repayment at par.
     * @dev Owner-gated like `setRepayTender`: it prices a user action rather than responding to an
     *      incident.
     *
     *      **Held strictly below `liquidationBonusBps`**, so deleveraging yourself always costs less
     *      than being liquidated, and a token with no bonus cannot carry a fee at all. That bound
     *      is also what keeps the operation from worsening health: spending `X(1+f)` of a token
     *      with threshold `T` against `X` of debt cannot lower a health factor at or above
     *      `(1+f)T`, and `validateTokenConfig` enforces `T + bonus <= 1`, so
     *      `(1+f)T < (1+b)(1-b) <= 1`.
     *
     *      Applies immediately in both directions. It is bounded by the bonus, and a raise can only
     *      make the user's own button dearer, never a position liquidatable.
     */
    function setCollateralRepayFee(address token, uint16 feeBps) external onlyViaCore requiresAuth {
        TokenConfig storage cfg = _tokenConfig[token];
        if (cfg.tokenDecimals == 0) revert TokenNotAllowed();
        if (feeBps != 0 && feeBps >= cfg.liquidationBonusBps) revert InvalidInput();
        _collateralRepayFeeBps[token] = feeBps;
        emit CollateralRepayFeeSet(token, feeBps);
    }

    function collateralRepayFeeBps(address token) external view onlyViaCore returns (uint16) {
        return _collateralRepayFeeBps[token];
    }

    // ========================================= OWNER CONFIGURATION =========================================

    /**
     * @notice Allowlists a token, with its full risk parameter set.
     * @dev `tokenDecimals` is read from the token rather than supplied, and the price band is
     *      mandatory: a token allowlisted without bounds would inherit whatever the upgradeable
     *      price provider said, which is precisely the dependency the band exists to break.
     *
     *      **The token must not rebase.** Escrowed collateral is attributed in `collateralOf`, and
     *      `rescueUnaccounted` sweeps `balance - totalCollateral` to the treasury — which for a
     *      rebasing token is exactly the yield earned on users' escrowed balances. Nothing on chain
     *      can detect this, so it is a precondition of allowlisting rather than a check. A
     *      share-price token (soUSD, soETH) is fine: its balance does not move, its price does.
     *
     *      The allowlist is capped. Every credit operation and every authorize read walks it in
     *      full, so its length is a latency budget as much as a policy choice.
     */
    function allowToken(address token, TokenConfig calldata config) external onlyViaCore requiresAuth {
        if (token == address(0)) revert InvalidInput();
        if (_tokenConfig[token].tokenDecimals != 0) revert TokenAlreadyAllowed();
        if (_allowedTokens.length >= MAX_ALLOWED_TOKENS) revert TooManyAllowedTokens();

        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals == 0 || decimals > 36) revert TokenDecimalsMismatch();
        if (config.tokenDecimals != decimals) revert TokenDecimalsMismatch();
        SolidCashConfigLib.validateTokenConfig(config);

        _tokenConfig[token] = config;
        _allowedTokens.push(token);

        emit TokenAllowed(token, config);
    }

    /**
     * @notice Updates an allowlisted token's risk parameters.
     * @dev Risk-**reducing** changes apply immediately; risk-**increasing** ones are scheduled for
     *      `paramChangeDelay`. `DebtManagerAdmin._setCollateralTokenConfig` applies all of them at
     *      once, which would let governance make currently-healthy positions instantly liquidatable
     *      — and therefore liquidate its own users' collateral in a single transaction.
     *
     *      Band tightening counts as risk-increasing for the same reason: making a token
     *      unpriceable removes it from liquidation capacity and drops the health factor. The
     *      immediate lever for a suspect feed is `setTokenPaused`, which is capacity-preserving.
     *
     *      The guardian's pause is not in `TokenConfig` at all, so neither this nor the
     *      permissionless `commitTokenConfig` can clear it by writing a configuration authored
     *      before the incident that caused it.
     */
    function updateToken(address token, TokenConfig calldata config) external onlyViaCore requiresAuth {
        TokenConfig memory current = _tokenConfig[token];
        if (current.tokenDecimals == 0) revert TokenNotAllowed();
        if (config.tokenDecimals != current.tokenDecimals) revert TokenDecimalsMismatch();
        SolidCashConfigLib.validateTokenConfig(config);

        if (SolidCashConfigLib.isRiskIncreasing(current, config)) {
            uint64 activationTime = uint64(block.timestamp) + _params.paramChangeDelay;
            _pendingTokenConfig[token] = PendingTokenConfig(activationTime, config);
            emit TokenConfigScheduled(token, config, activationTime);
        } else {
            _tokenConfig[token] = config;
            delete _pendingTokenConfig[token];
            emit TokenConfigApplied(token, config);
        }
    }

    /// @notice Applies a matured risk-increasing change. Permissionless once ready.
    function commitTokenConfig(address token) external onlyViaCore {
        PendingTokenConfig memory pending = _pendingTokenConfig[token];
        if (pending.activationTime == 0) revert NoPendingConfig();
        if (block.timestamp < pending.activationTime) revert ConfigNotReady();
        if (_tokenConfig[token].tokenDecimals != pending.cfg.tokenDecimals) revert TokenDecimalsMismatch();

        _tokenConfig[token] = pending.cfg;
        delete _pendingTokenConfig[token];

        emit TokenConfigApplied(token, pending.cfg);
    }

    /// @notice Cancels a scheduled risk-increasing change.
    function cancelTokenConfig(address token) external onlyViaCore requiresAuth {
        if (_pendingTokenConfig[token].activationTime == 0) revert NoPendingConfig();
        delete _pendingTokenConfig[token];
        emit TokenConfigCancelled(token);
    }

    /**
     * @notice Removes a token from the allowlist entirely.
     * @dev Blocked while any Safe still has it escrowed. Deleting the config would erase the
     *      decimals and band that liquidation capacity is computed from, so every position holding it
     *      would instantly read as under-collateralised — mass liquidation as a side effect of an
     *      unrelated configuration change. To stop *new* pledging without that, set
     *      `collateral = false` (delayed) or `paused = true` (immediate).
     */
    function disallowToken(address token) external onlyViaCore requiresAuth {
        if (_tokenConfig[token].tokenDecimals == 0) revert TokenNotAllowed();
        if (totalCollateral[token] != 0) revert TokenStillEscrowed();

        delete _tokenConfig[token];
        delete _pendingTokenConfig[token];
        // A re-allowlisted token starts from a clean slate; the guardian re-pauses if it needs to.
        // Leaving a stale bit set would make `allowToken` succeed on a token nothing can use, with
        // no field in the config to explain why.
        delete tokenPaused[token];
        // Same reasoning in the opposite direction: a stale tender bit would make a re-allowlisted
        // token acceptable as payment without anyone deciding that again.
        delete repayTender[token];
        // And a stale fee would be charged on a re-allowlisted token nobody re-priced.
        delete _collateralRepayFeeBps[token];

        uint256 length = _allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_allowedTokens[i] == token) {
                _allowedTokens[i] = _allowedTokens[length - 1];
                _allowedTokens.pop();
                break;
            }
        }

        emit TokenDisallowed(token);
    }

    /// @notice Replaces the price provider. Every price it returns is still band-checked here.
    function setPriceProvider(address _priceProvider) external onlyViaCore requiresAuth {
        if (_priceProvider == address(0)) revert InvalidInput();
        priceProvider = ISolidPriceProviderV2(_priceProvider);
        emit PriceProviderSet(_priceProvider);
    }

    /**
     * @notice Sets the borrow rate. Fixed, not utilization-driven.
     * @dev Accrues **before** writing, or the new rate would retroactively reprice elapsed time.
     */
    function setBorrowApyPerSecond(uint64 apyPerSecond) external onlyViaCore requiresAuth {
        if (apyPerSecond > MAX_BORROW_APY_PER_SECOND) revert InvalidInput();
        _accrue();
        emit BorrowApySet(borrowApyPerSecond, apyPerSecond);
        borrowApyPerSecond = apyPerSecond;
    }

    /// @notice Sets every org-wide cap, delay and sizing parameter.
    function setParams(Params calldata p) external onlyViaCore requiresAuth {
        SolidCashConfigLib.validateParams(p, _params.paramChangeDelay);

        _params = p;
        emit ParamsSet(p);
    }

    /**
     * @notice Arms a reduction of `paramChangeDelay`, effective after the CURRENT `paramChangeDelay`.
     * @dev The one parameter that cannot be lowered through `setParams`, because it is the parameter
     *      every other delayed change is measured against. Shortening it must itself be objectable
     *      for the length of time it is about to remove.
     */
    function requestParamChangeDelayReduction(uint64 newDelay) external onlyViaCore requiresAuth {
        if (newDelay >= _params.paramChangeDelay) revert InvalidInput();
        if (newDelay < _params.liquidationGracePeriod) revert InvalidInput();
        uint64 activationTime = uint64(block.timestamp) + _params.paramChangeDelay;
        pendingParamChangeDelay = newDelay;
        paramChangeDelayReadyAt = activationTime;
        emit ParamChangeDelayReductionRequested(newDelay, activationTime);
    }

    /// @notice Applies a matured reduction. Permissionless once ready, like `commitTokenConfig`.
    function commitParamChangeDelayReduction() external onlyViaCore {
        uint64 readyAt = paramChangeDelayReadyAt;
        if (readyAt == 0) revert NoPendingConfig();
        if (block.timestamp < readyAt) revert ConfigNotReady();

        uint64 newDelay = pendingParamChangeDelay;
        if (newDelay < _params.liquidationGracePeriod) revert InvalidInput();

        _params.paramChangeDelay = newDelay;
        pendingParamChangeDelay = 0;
        paramChangeDelayReadyAt = 0;

        emit ParamChangeDelaySet(newDelay);
    }

    /// @notice Disarms a pending reduction. Immediate, like every other de-risking action here.
    function cancelParamChangeDelayReduction() external onlyViaCore requiresAuth {
        if (paramChangeDelayReadyAt == 0) revert NoPendingConfig();
        pendingParamChangeDelay = 0;
        paramChangeDelayReadyAt = 0;
        emit ParamChangeDelayReductionCancelled();
    }

    /**
     * @notice Sweeps tokens sitting in this contract that belong to no Safe.
     * @dev Bounded by `balance - sum(collateralOf)`, so it can never touch accounted collateral, and
     *      the destination is the treasury rather than a parameter. Exists because a direct transfer
     *      into this contract is otherwise stuck forever; it is the only privileged path that moves
     *      a token out, and it provably cannot move a user's.
     */
    function rescueUnaccounted(address token) external onlyViaCore requiresAuth nonReentrant {
        uint256 accounted = totalCollateral[token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance <= accounted) revert AmountZero();

        uint256 surplus = balance - accounted;
        IERC20(token).safeTransfer(settlementTreasury, surplus);

        emit UnaccountedRescued(token, surplus);
    }

    function getParams() external view onlyViaCore returns (Params memory) {
        return _params;
    }

    function getTokenConfig(address token) external view onlyViaCore returns (TokenConfig memory) {
        return _tokenConfig[token];
    }

    function getPendingTokenConfig(address token) external view onlyViaCore returns (PendingTokenConfig memory) {
        return _pendingTokenConfig[token];
    }

    // ========================================= VIEWS =========================================
    // Reads only. They live here rather than in the core for the same reason the configuration
    // surface does: the core's budget is spent on the paths that move value, and a `staticcall`
    // resolves through its fallback exactly the way `getParams` already does.

    /// @notice The Safe's limit state with all matured transitions applied.
    function applicableSpendingLimit(address safe) external view onlyViaCore returns (SpendingLimit memory) {
        return SpendingLimitLibV2.currentLimit(_safeLimit[safe]);
    }

    // `getIncomingMode` and `pokeHealth` used to live here. Both moved to the core when the tender
    // list was added: which half a function lives in is an EIP-170 decision and nothing else, and
    // the fallback makes it invisible to callers either way. `pokeHealth` in particular belongs
    // beside `liquidate` now, since arming the grace stamp is the call a liquidator makes first.

    // ========================================= REPAY =========================================

    /**
     * @notice Repays a Safe's debt from the caller's own tokens. Permissionless.
     * @dev Anyone may repay anyone. Never blocked by any pause: de-risking must always work. Only
     *      the amount actually needed is pulled, so there is no refund path to get wrong, and the
     *      delivered value is rounded DOWN so a repayer can never be over-credited.
     *
     *      This is the only place in the design an ERC20 allowance appears, and only for a
     *      third-party repayer who is not the Safe — every Safe-initiated path uses module authority.
     */
    function repay(address safe, address token, uint256 amount) external onlyViaCore nonReentrant {
        if (amount == 0) revert AmountZero();
        SafeConfig storage $ = _safeConfig[safe];

        _accrue();
        (uint256 amountUsd, uint256 tokenAmount) = _sizeRepay($, token, amount);

        _reduceDebt($, amountUsd);
        IERC20(token).safeTransferFrom(msg.sender, settlementTreasury, tokenAmount);

        _refreshHealthStamp(safe, $);
        emit Repaid(safe, token, tokenAmount, amountUsd, msg.sender);
    }

    /**
     * @notice Repays a Safe's debt from that Safe's own loose balance.
     * @dev Two callers are *possible* — the Safe itself and `CREDIT_SPENDER_ROLE` — but **the role
     *      is deliberately not granted at deploy**, so in practice only the Safe can call this. The
     *      backend watches a position and notifies; it never spends a user's balance for them. The
     *      capability survives in the contract so the decision is one `setRoleCapability` to revisit
     *      rather than a new module.
     *
     *      Capped at the outstanding debt with no bonus, so it can never over-collect; with no debt
     *      it reverts rather than moving anything.
     */
    function repayFromSafe(address safe, address token, uint256 amount) external onlyViaCore nonReentrant {
        _requireSafeOrCreditSpender(safe);
        if (amount == 0) revert AmountZero();
        SafeConfig storage $ = _safeConfig[safe];

        _accrue();

        uint256 loose = IERC20(token).balanceOf(safe);
        if (amount > loose) amount = loose;
        (uint256 amountUsd, uint256 tokenAmount) = _sizeRepay($, token, amount);

        _reduceDebt($, amountUsd);

        uint256 before = IERC20(token).balanceOf(settlementTreasury);
        _execFromSafe(safe, token, abi.encodeWithSelector(IERC20.transfer.selector, settlementTreasury, tokenAmount));
        if (IERC20(token).balanceOf(settlementTreasury) - before < tokenAmount) revert SettlementShortfall();

        _refreshHealthStamp(safe, $);
        emit Repaid(safe, token, tokenAmount, amountUsd, safe);
    }

    /**
     * @notice Repays a Safe's debt out of its own escrowed collateral. The deleverage button.
     * @dev **The user's button, not Solid's.** `CREDIT_SPENDER_ROLE` is not granted this selector at
     *      deploy, so there is no auto-deleverage cron: a drifting position is notified, and the
     *      user decides. Zero bonus, capped at the outstanding debt.
     *
     *      The cost of that choice is explicit: with no deleverage acting on the user's behalf, an
     *      unhealthy position's only resolution is `liquidate`, which takes `liquidationBonusBps`
     *      out of the same collateral the user would have spent here. Here it is spent at par plus
     *      the token's `collateralRepayFeeBps` — zero unless set, and always below that bonus. The
     *      fee is debited on top of the collateral the credit is worth, so `amountUsd` is still
     *      the debt retired.
     *
     *      **Unlike an Aave position manager, this needs no headroom and clears a fully leveraged
     *      position in one call.** The collateral is in this contract's own escrow and this contract
     *      owns both ledgers, so the end state is computed directly and no external protocol ever
     *      inspects an intermediate one. `type(uint256).max` means "repay everything".
     *
     *      The post-op health check is a bug net, not a limiter: for any position whose collateral
     *      value exceeds its debt, `d/dX [(C-X)T/(D-X)] = T(C-D)/(D-X)^2 >= 0`, so this operation
     *      cannot worsen health; with a fee the condition becomes `HF >= (1+f)T`, which the bonus cap
     *      guarantees for any healthy position (see `setCollateralRepayFee`). It is skipped for an
     *      already-insolvent position, which must still be allowed to de-risk partially.
     */
    function repayFromCollateral(address safe, address token, uint256 amountUsd) external onlyViaCore nonReentrant {
        _requireSafeOrCreditSpender(safe);
        SafeConfig storage $ = _safeConfig[safe];

        _accrue();
        uint256 debt = _debtOf($);
        if (debt == 0) revert NoDebt();
        if (amountUsd > debt) amountUsd = debt;
        if (amountUsd == 0) revert AmountZero();

        uint256 tokenAmount;
        uint256 feeAmount;
        (tokenAmount, feeAmount, amountUsd) = _sizeCollateralRepay(safe, token, amountUsd);

        (uint256 hfBefore,) = _healthFactor(safe, $);

        _debitCollateral(safe, token, tokenAmount);
        _reduceDebt($, amountUsd);
        // The fee goes to the same immutable treasury in the same transfer: no new destination.
        IERC20(token).safeTransfer(settlementTreasury, tokenAmount);

        (uint256 hfAfter,) = _healthFactor(safe, $);
        if (hfBefore >= WAD && hfAfter < hfBefore) revert HealthWorsened();

        _refreshHealthStamp(safe, $);
        emit RepaidFromCollateral(safe, token, tokenAmount, amountUsd);
        if (feeAmount != 0) emit CollateralRepayFeeCharged(safe, token, feeAmount);
    }

    /// @dev `repayFromCollateral`'s sizing, split out only to keep that function under the stack limit.
    function _sizeCollateralRepay(address safe, address token, uint256 amountUsd)
        private
        view
        returns (uint256 tokenAmount, uint256 feeAmount, uint256 creditedUsd)
    {
        TokenConfig storage cfg = _tokenConfig[token];
        if (cfg.tokenDecimals == 0) revert TokenNotAllowed();

        // Re-capped at the bonus here, not only in `setCollateralRepayFee`: lowering the bonus is
        // risk-reducing and applies at once, and must not leave the fee above it.
        uint256 feeBps = Math.min(_collateralRepayFeeBps[token], cfg.liquidationBonusBps);

        return SolidCreditMathLib.sizeCollateralRepay(
            amountUsd, _settlementPrice(token, cfg), 10 ** cfg.tokenDecimals, collateralOf[safe][token], feeBps
        );
    }

    /**
     * @dev Shared repay sizing: value the delivered token DOWN, clamp to the outstanding debt, and
     *      re-derive the token amount so only what is needed is moved.
     * @return amountUsd Debt to retire
     * @return tokenAmount Token units to move
     */
    function _sizeRepay(SafeConfig storage $, address token, uint256 amount)
        private
        view
        returns (uint256 amountUsd, uint256 tokenAmount)
    {
        if (amount == 0) revert AmountZero();

        TokenConfig storage cfg = _tokenConfig[token];
        if (cfg.tokenDecimals == 0) revert TokenNotAllowed();
        // A token the guardian has just declared suspect is not tender. `repayFromCollateral` is
        // deliberately exempt — that one spends the borrower's OWN escrowed balance to de-risk, and
        // refusing it would trap the position it is meant to rescue.
        if (tokenPaused[token]) revert TokenIsPaused();
        // Nor is a token whose price nothing observes. This sizing decides how much debt an incoming
        // payment retires, so accepting an uncorroborated peg here would let a borrower settle a
        // dollar of debt with a token that has stopped being worth a dollar — the one use of a bare
        // peg the provider's design never argued was safe. `repayFromCollateral` is exempt for the
        // same reason it is exempt from the pause.
        if (!repayTender[token]) revert TokenNotTender();

        uint256 debt = _debtOf($);
        if (debt == 0) revert NoDebt();

        // Strict, never capped: a capped price would understate the credit the payer is due.
        return SolidCreditMathLib.sizeRepay(amount, _settlementPrice(token, cfg), 10 ** cfg.tokenDecimals, debt);
    }

    // ========================================= LIMIT WAIVER =========================================

    /**
     * @notice Requests the org-wide spending-limit waiver, effective after `paramChangeDelay`.
     * @dev The most risk-increasing change this contract permits, so it is delayed like every other
     *      one — and the delay is the window in which anyone watching the event can object. It never
     *      waives the collateral requirement or the global debt cap (see `limitsWaived`).
     *
     *      Prefer `requestWaiveSafeLimits` wherever the need is one account: the org-wide waiver
     *      removes the per-transaction and rolling caps for **every** registered Safe at once, which
     *      is precisely the on-chain backstop against a compromised spender key.
     */
    function requestWaiveLimits() external onlyViaCore requiresAuth {
        uint64 activationTime = uint64(block.timestamp) + _params.paramChangeDelay;
        limitsWaiveAt = activationTime;
        emit LimitsWaiveRequested(activationTime);
    }

    /// @notice Restores the org-wide limits, **immediately**. Also disarms a pending waiver. Admin
    ///         only; no Safe is involved.
    function restoreLimits() external onlyViaCore requiresAuth {
        limitsWaiveAt = 0;
        emit LimitsRestored();
    }

    /**
     * @notice Requests a waiver for one Safe, effective after `limitWaiveDelay`.
     * @dev The operationally useful form — a whale, a partner account, or an incident where the caps
     *      are blocking a legitimate settlement — and its blast radius is one account rather than the
     *      whole book. **The Safe does nothing:** it is already registered from onboarding, and no
     *      owner signature is involved at any point in waiving or restoring.
     *
     *      It runs on its own `limitWaiveDelay` rather than `paramChangeDelay`, because that one is
     *      floored by `liquidationGracePeriod` — sharing it would mean buying a fast operational
     *      waiver by shortening the window that protects users from a bad oracle print. Set
     *      `limitWaiveDelay` to 0 for an immediate waiver, accepting that a compromised admin key
     *      could then lift one Safe's caps in a single transaction. Value would still only reach the
     *      immutable treasury, and the collateral requirement and global debt cap still bind.
     */
    function requestWaiveSafeLimits(address safe) external onlyViaCore requiresAuth {
        if (!_safeConfig[safe].registered) revert NotRegistered();
        uint64 activationTime = uint64(block.timestamp) + _params.limitWaiveDelay;
        safeLimitsWaiveAt[safe] = activationTime;
        emit SafeLimitsWaiveRequested(safe, activationTime);
    }

    /// @notice Restores one Safe's limits, **immediately**. Also disarms a pending waiver. Admin only;
    ///         the Safe is not involved.
    function restoreSafeLimits(address safe) external onlyViaCore requiresAuth {
        safeLimitsWaiveAt[safe] = 0;
        emit SafeLimitsRestored(safe);
    }

    /**
     * @notice Writes off debt a position can no longer cover. Owner only, timelocked.
     * @dev Accounting hygiene, not a bailout: Solid is the sole lender, so bad debt is Solid's loss
     *      and there is nothing to socialise. Refuses while any collateral remains, so it can never
     *      substitute for liquidation.
     */
    function writeOffBadDebt(address safe) external onlyViaCore requiresAuth {
        SafeConfig storage $ = _safeConfig[safe];
        _accrue();

        uint256 length = _allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            if (collateralOf[safe][_allowedTokens[i]] != 0) revert TokenStillEscrowed();
        }

        uint256 debt = _debtOf($);
        if (debt == 0) revert NoDebt();
        _reduceDebt($, debt);
        $.forcedDebtUsd = 0;
        $.unhealthySince = 0;

        emit BadDebtWrittenOff(safe, debt);
    }
}
