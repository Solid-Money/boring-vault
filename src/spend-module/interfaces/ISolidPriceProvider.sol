// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Price feed families the provider can evaluate.
 * @dev New kinds are added by upgrading `SolidPriceProvider`. The enum is append-only: reordering or
 *      removing a member would silently re-point every already-configured token at a different
 *      pricing path, so new families are always appended.
 */
enum PriceFeedKind {
    /// @dev Unconfigured. Always unusable, so an unlisted token can never be priced by accident.
    NONE,
    /// @dev USD-pegged asset quoted at a configured peg price (USDC, USDT).
    STABLE,
    /// @dev Veda / BoringVault share, priced as `accountant.exchangeRate x price(baseAsset)`.
    VEDA_ACCOUNTANT
}

/**
 * @notice Per-token pricing configuration.
 * @param kind Which feed family evaluates this token
 * @param tokenDecimals Decimals of the priced token, cached to keep it off the hot path
 * @param baseDecimals `VEDA_ACCOUNTANT` only: decimals of the accountant's base asset
 * @param maxStaleness `VEDA_ACCOUNTANT` only: how old the accountant's last rate update may be
 * @param source `VEDA_ACCOUNTANT` only: the accountant contract
 * @param baseAsset `VEDA_ACCOUNTANT` only: the accountant's base asset, itself priced by this provider
 * @param pegPriceUsd `STABLE` only: the quoted price in 6-decimal USD, normally 1_000_000
 * @param minPriceUsd Absolute sanity floor applied to whatever the feed computes (6 decimals)
 * @param maxPriceUsd Absolute sanity ceiling applied to whatever the feed computes (6 decimals)
 */
struct PriceFeedConfig {
    PriceFeedKind kind;
    uint8 tokenDecimals;
    uint8 baseDecimals;
    uint64 maxStaleness;
    address source;
    address baseAsset;
    uint96 pegPriceUsd;
    uint96 minPriceUsd;
    uint96 maxPriceUsd;
}

/**
 * @notice Single place every spend-module price comes from.
 * @dev Modelled on ether.fi's `IPriceProvider` / `PriceProviderV2`: one call, one denomination, and
 *      the consuming contract never learns how a token is priced. That is what lets a new asset be
 *      onboarded with a configuration transaction instead of a redeploy.
 */
interface ISolidPriceProvider {
    /**
     * @notice Price of one whole `token` in USD, with 6 decimals.
     * @dev Returns a usability flag rather than reverting, so a caller aggregating several tokens can
     *      report one bad feed without losing the whole read — which matters because the card
     *      authorize path has a single chance to answer inside its latency budget.
     * @return price USD price of one whole token, 6 decimals. Zero whenever `usable` is false.
     * @return usable False when the token is unconfigured, the feed is paused, the rate is stale, or
     *         the computed price falls outside its configured sanity band.
     */
    function priceUsd(address token) external view returns (uint256 price, bool usable);

    /**
     * @notice The configuration driving `priceUsd` for a token.
     */
    function getConfig(address token) external view returns (PriceFeedConfig memory);

    /**
     * @notice Every token that currently has a feed configured.
     */
    function configuredTokens() external view returns (address[] memory);
}
