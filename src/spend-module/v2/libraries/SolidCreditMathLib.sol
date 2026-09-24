// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LiquidationSizing} from "../SolidCashTypes.sol";

/**
 * @notice Inputs to one liquidation's arithmetic. Grouped so the computation can be reasoned about,
 *         fuzzed and audited without a live position.
 * @param debt The position's whole debt in 6-decimal USD
 * @param requestedUsd What the liquidator asked to retire
 * @param closeBps Close factor in bps; 10_000 for a dust position
 * @param cPrice Collateral price, 6-decimal USD, already proven strictly in band
 * @param cUnit `10 ** collateralDecimals`
 * @param bonusNum `10_000 + liquidationBonusBps`
 * @param available The Safe's escrowed balance of the collateral token
 * @param rPrice Repay token price, 6-decimal USD, already proven strictly in band
 * @param rUnit `10 ** repayDecimals`
 */
struct LiquidationInput {
    uint256 debt;
    uint256 requestedUsd;
    uint256 closeBps;
    uint256 cPrice;
    uint256 cUnit;
    uint256 bonusNum;
    uint256 available;
    uint256 rPrice;
    uint256 rUnit;
}

/**
 * @title SolidCreditMathLib
 * @notice The value-moving arithmetic of `SolidCashModuleV2`, as pure functions.
 * @dev `public` rather than `internal`, so it deploys to its own account and is delegatecalled —
 *      which is what keeps its bytecode out of the module's EIP-170 budget. Deployment therefore
 *      requires linking.
 *
 *      Being pure and storage-free is the point beyond size: every rounding decision below can be
 *      fuzzed directly, with no position to set up, and the module cannot accidentally couple the
 *      arithmetic to state it has not already validated.
 *
 *      **Rounding, and who each direction favours.** A liquidation moves value in two directions at
 *      once, so the two legs round oppositely and both round against the liquidator:
 *        - collateral out rounds DOWN, so a liquidator never receives a dust unit more than the
 *          bonus entitles, and the borrower keeps the remainder;
 *        - the repayment rounds UP, so a liquidator never settles a slice for less than its dollar
 *          value.
 *      A liquidator therefore cannot profit from precision in either leg, at any scale.
 */
library SolidCreditMathLib {
    uint16 internal constant MAX_BPS = 10_000;

    error AmountZero();

    /**
     * @notice Sizes one liquidation.
     * @dev The two-step clamp is what makes a partially-collateralised position safe to liquidate.
     *      The first pass sizes the seizure from the requested repayment; if the position does not
     *      hold that much collateral, the seizure is capped at what it does hold and the repayment
     *      is **re-derived from the seizure** rather than left at the requested figure — otherwise a
     *      liquidator would retire less debt than the collateral they walked away with was worth.
     *      Re-clamping to `maxRepay` afterwards keeps the close factor authoritative even in that
     *      branch, and the seizure is recomputed a final time so the two legs always agree.
     */
    function sizeLiquidation(LiquidationInput memory i) public pure returns (LiquidationSizing memory z) {
        uint256 maxRepay = Math.mulDiv(i.debt, i.closeBps, MAX_BPS, Math.Rounding.Floor);
        z.repaidUsd = i.requestedUsd > maxRepay ? maxRepay : i.requestedUsd;
        if (z.repaidUsd == 0) revert AmountZero();

        z.seized = Math.mulDiv(z.repaidUsd, i.bonusNum * i.cUnit, uint256(MAX_BPS) * i.cPrice, Math.Rounding.Floor);

        if (z.seized > i.available) {
            z.seized = i.available;
            z.repaidUsd = Math.mulDiv(z.seized, i.cPrice * MAX_BPS, i.bonusNum * i.cUnit, Math.Rounding.Ceil);
            if (z.repaidUsd > maxRepay) {
                z.repaidUsd = maxRepay;
                z.seized =
                    Math.mulDiv(z.repaidUsd, i.bonusNum * i.cUnit, uint256(MAX_BPS) * i.cPrice, Math.Rounding.Floor);
            }
        }
        if (z.seized == 0 || z.repaidUsd == 0) revert AmountZero();

        z.repayTokenAmount = Math.mulDiv(z.repaidUsd, i.rUnit, i.rPrice, Math.Rounding.Ceil);
        if (z.repayTokenAmount == 0) revert AmountZero();
    }

    /**
     * @notice Sizes a repayment made out of the borrower's own escrowed collateral.
     * @dev The collateral taken rounds UP so the treasury is never short, exactly as settlement
     *      does; when the position does not hold that much, the seizure is capped at what it holds
     *      and the credit is re-derived DOWN from it, so the borrower is never over-charged for a
     *      partial deleverage. No bonus in either direction — this is not a liquidation.
     *
     *      `feeBps` is taken on top of the collateral the credit is worth, and it also rounds UP.
     *      In the capped branch the credit is re-derived from `available / (1 + fee)`, so the
     *      principal plus the fee never exceeds what the Safe holds. At a zero fee every figure is
     *      identical to at-par sizing.
     * @return tokenAmount Collateral to debit, fee included
     * @return feeAmount The part of `tokenAmount` that is fee
     * @return creditedUsd Debt retired
     */
    function sizeCollateralRepay(uint256 amountUsd, uint256 price, uint256 unit, uint256 available, uint256 feeBps)
        public
        pure
        returns (uint256 tokenAmount, uint256 feeAmount, uint256 creditedUsd)
    {
        creditedUsd = amountUsd;
        uint256 principal = Math.mulDiv(amountUsd, unit, price, Math.Rounding.Ceil);
        feeAmount = Math.mulDiv(principal, feeBps, MAX_BPS, Math.Rounding.Ceil);
        tokenAmount = principal + feeAmount;

        if (tokenAmount > available) {
            tokenAmount = available;
            creditedUsd = Math.mulDiv(available, price * MAX_BPS, unit * (MAX_BPS + feeBps), Math.Rounding.Floor);
            // The fee's own ceiling can put `available` a unit past `principal * (1 + fee)`, which
            // for a token worth more than a USD unit per token unit re-derives a credit above the
            // one requested — and the request is already capped at the debt.
            if (creditedUsd > amountUsd) creditedUsd = amountUsd;
            // Cannot underflow: `creditedUsd * unit / price <= available / (1 + fee)`. At a zero fee
            // the remainder is rounding dust, not fee, and is reported as none.
            feeAmount =
                feeBps == 0 ? 0 : available - Math.mulDiv(creditedUsd, unit, price, Math.Rounding.Ceil);
        }
        if (tokenAmount == 0 || creditedUsd == 0) revert AmountZero();
    }

    /**
     * @notice Sizes a repayment: the debt it retires, and the tokens to move.
     * @dev The delivered value rounds DOWN so a payer is never over-credited; when the payment
     *      exceeds the debt, only the tokens the debt needs are moved and that figure rounds UP so
     *      the treasury is never short. Clamped back to `amount` so the caller can never be asked
     *      for more than they offered.
     */
    function sizeRepay(uint256 amount, uint256 price, uint256 unit, uint256 debt)
        public
        pure
        returns (uint256 amountUsd, uint256 tokenAmount)
    {
        amountUsd = Math.mulDiv(amount, price, unit, Math.Rounding.Floor);
        tokenAmount = amount;

        if (amountUsd > debt) {
            amountUsd = debt;
            tokenAmount = Math.mulDiv(debt, unit, price, Math.Rounding.Ceil);
            if (tokenAmount > amount) tokenAmount = amount;
        }
        if (amountUsd == 0) revert AmountZero();
    }
}
