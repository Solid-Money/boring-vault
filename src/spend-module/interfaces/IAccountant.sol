// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Read-only slice of `AccountantWithRateProviders` needed to price vault shares.
 * @dev Declared as a standalone interface rather than importing the implementation so the
 *      spend module carries no dependency on the vault contracts it prices against.
 *
 *      `exchangeRate` is quoted in the accountant's `base` asset, scaled by
 *      `10 ** decimals()` share units. For soUSD on Fuse the accountant lives at
 *      0x47A5e832E1178726dd13AdD762774A704878AD98 with `base` = USDC-on-Fuse (6 decimals)
 *      and `decimals()` = 6, so a rate of 1_075_637 means 1 soUSD = 1.075637 USDC.
 */
interface IAccountant {
    /**
     * @notice Current share price in the base asset. Does not revert when paused.
     */
    function getRate() external view returns (uint256 rate);

    /**
     * @notice Packed accountant state. Read for `lastUpdateTimestamp` and `isPaused`, which
     *         `getRate()` alone does not expose.
     */
    function accountantState()
        external
        view
        returns (
            address payoutAddress,
            uint96 highwaterMark,
            uint128 feesOwedInBase,
            uint128 totalSharesLastUpdate,
            uint96 exchangeRate,
            uint16 allowedExchangeRateChangeUpper,
            uint16 allowedExchangeRateChangeLower,
            uint64 lastUpdateTimestamp,
            bool isPaused,
            uint24 minimumUpdateDelayInSeconds,
            uint16 platformFee,
            uint16 performanceFee
        );

    /**
     * @notice Decimals the exchange rate is scaled by (equal to the priced vault's decimals).
     */
    function decimals() external view returns (uint8);

    /**
     * @notice The vault whose shares this accountant prices.
     */
    function vault() external view returns (address);

    /**
     * @notice The asset `exchangeRate` is denominated in.
     * @dev Critically not always a dollar-like asset: soUSD's base is USDC-on-Fuse (6 decimals, ~$1)
     *      while soETH's is WETH (18 decimals, ~$3000). Anything converting a rate to USD must price
     *      this asset explicitly rather than assume it is worth one dollar.
     */
    function base() external view returns (address);
}
