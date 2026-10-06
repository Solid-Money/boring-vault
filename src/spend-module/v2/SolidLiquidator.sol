// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The one function of `SolidCashModuleV2` this contract exists to reach.
interface ISolidCashModuleV2Liquidation {
    function liquidate(address safe, address repayToken, uint256 repayAmountUsd, address collateralToken) external;
}

/**
 * @title SolidLiquidator
 * @notice The only address permitted to liquidate positions on `SolidCashModuleV2`, and a contract
 *         that provably cannot keep what it seizes.
 *
 * @dev **Why this exists.** `SolidCashModuleV2.liquidate` is the one path that hands a user's
 *      escrowed collateral to somebody other than that user or the immutable settlement treasury,
 *      and the size of a liquidation is driven by debt. `bookForcedSpend` can create debt with no
 *      collateral backing it, because a mandatory card authorization has already happened off-chain
 *      and refusing to record it is worse than recording it. While liquidation was permissionless,
 *      those two facts composed into a complete theft: a compromised `CREDIT_SPENDER_ROLE` key
 *      books unbacked debt against any registered Safe, then liquidates the position it just
 *      manufactured and keeps the collateral plus `liquidationBonusBps`.
 *
 *      Capping what one mandatory authorization may be would close that at the debt end, but the
 *      card flow cannot accept a per-transaction cap on a charge that has already happened. So it is
 *      closed at the extraction end instead, in two layers:
 *
 *        1. The module's `liquidate` is `requiresAuth`, and `LIQUIDATOR_ROLE` is granted to exactly
 *           one address: this contract.
 *        2. This contract forwards every token it receives to the immutable `settlementTreasury`
 *           inside the same transaction. There is no parameter naming a destination and no function
 *           that can send a token anywhere else.
 *
 *      The operator key that drives this contract is deliberately **neither spender key**. So
 *      manufacturing a liquidation now needs two independent compromises, and even with both the
 *      proceeds land in Solid's own treasury — where `reverseSpend` plus a refund make the user
 *      whole. There is no call sequence that pays an attacker.
 *
 *      **The float.** The module's repay leg pulls `repayToken` from this contract straight to the
 *      treasury, so this contract must hold a working balance of whatever it repays with. That
 *      balance is Solid's own money, funded by the treasury, and `sweep` returns it at any time.
 *      Keeping the float here rather than taking a standing allowance on the treasury is deliberate:
 *      a bounded balance is a bounded blast radius, whereas an unlimited approval on the treasury
 *      would make this contract as dangerous as the treasury itself.
 *
 *      **Not upgradeable, and holds nothing it is owed.** Anything sitting here is either the float
 *      or a stray transfer, and `sweep` is permissionless precisely because its destination is fixed
 *      at construction — there is no version of calling it that helps an attacker.
 */
contract SolidLiquidator is Auth, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The `SolidCashModuleV2` core. Immutable, so the target is never a parameter.
    address public immutable module;

    /// @notice Where every token this contract touches ends up. Immutable, and the module's own
    ///         settlement destination, so both legs of a liquidation converge on one address.
    address public immutable settlementTreasury;

    error InvalidInput();

    event Liquidated(
        address indexed safe,
        address indexed collateralToken,
        address indexed repayToken,
        uint256 repayAmountUsd,
        uint256 seizedSweptToTreasury
    );
    event Swept(address indexed token, uint256 amount);

    /**
     * @param _owner Timelocked multisig. Also the module's owner.
     * @param _authority `FuseRolesAuthority`, granting `LIQUIDATION_OPERATOR_ROLE` over `liquidate`
     * @param _module The `SolidCashModuleV2` core
     * @param _settlementTreasury Must equal the module's own `settlementTreasury`
     */
    constructor(address _owner, address _authority, address _module, address _settlementTreasury)
        Auth(_owner, Authority(_authority))
    {
        if (_owner == address(0) || _module == address(0) || _settlementTreasury == address(0)) revert InvalidInput();

        module = _module;
        settlementTreasury = _settlementTreasury;
    }

    /**
     * @notice Liquidates one position and forwards everything seized to the treasury.
     * @dev Gated on `LIQUIDATION_OPERATOR_ROLE`, a key held by neither the debit spender nor the
     *      credit spender. Every eligibility rule still lives in the module: the grace period, the
     *      `fullyPriced` requirement, the close factor and `liquidationsPaused` all apply exactly as
     *      before, so this contract widens nothing and can only ever act on a position the module
     *      already considers liquidatable.
     *
     *      The approval is granted for the balance this contract holds and reset to zero in the same
     *      call, so no standing allowance survives the transaction.
     *
     *      Sweeping `collateralToken` is the step that makes the whole design work: when the
     *      collateral and the repay token are the same asset, this also returns the float, which is
     *      the conservative direction.
     * @param safe The position to liquidate
     * @param repayToken Token to repay with. Must be tender the module accepts, and held here
     * @param repayAmountUsd USD of debt to retire, clamped by the module's close factor
     * @param collateralToken Collateral to seize
     */
    function liquidate(address safe, address repayToken, uint256 repayAmountUsd, address collateralToken)
        external
        requiresAuth
        nonReentrant
    {
        uint256 float = IERC20(repayToken).balanceOf(address(this));
        if (float == 0) revert InvalidInput();

        IERC20(repayToken).forceApprove(module, float);
        ISolidCashModuleV2Liquidation(module).liquidate(safe, repayToken, repayAmountUsd, collateralToken);
        IERC20(repayToken).forceApprove(module, 0);

        uint256 swept = _sweep(collateralToken);

        emit Liquidated(safe, collateralToken, repayToken, repayAmountUsd, swept);
    }

    /**
     * @notice Sends this contract's whole balance of `token` to the settlement treasury.
     * @dev Permissionless, because the destination is immutable and is the same address the module
     *      settles to. Anyone paying gas to return Solid's money to Solid is welcome to. It is also
     *      how the float is recovered and how a stray transfer is cleared.
     */
    function sweep(address token) external nonReentrant returns (uint256) {
        return _sweep(token);
    }

    function _sweep(address token) private returns (uint256 balance) {
        balance = IERC20(token).balanceOf(address(this));
        if (balance != 0) {
            IERC20(token).safeTransfer(settlementTreasury, balance);
            emit Swept(token, balance);
        }
    }
}
