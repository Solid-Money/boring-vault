// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Price feed families `SolidPriceProviderV2` can evaluate.
 * @dev **APPEND-ONLY.** The first three members and their ordering are identical to
 *      `ISolidPriceProvider.PriceFeedKind` because they share storage with the deployed
 *      implementation: reordering or removing a member would silently re-point every
 *      already-configured token at a different pricing path.
 */
enum PriceFeedKindV2 {
    /// @dev Unconfigured. Always unusable, so an unlisted token can never be priced by accident.
    NONE,
    /// @dev USD-pegged asset quoted at a configured peg price (USDC, USDT).
    STABLE,
    /// @dev Veda / BoringVault share, priced as `accountant.exchangeRate x price(baseAsset)`.
    VEDA_ACCOUNTANT,
    /// @dev **TOMBSTONE.** Was a Supra S-Value pull feed. Supra is deprecated on Fuse and this
    ///      member was never written to storage on any chain, so the read and configuration paths
    ///      for it are gone. The member itself stays because the enum is append-only and
    ///      storage-shared: reusing slot 3 for a different family would silently re-point any
    ///      entry that ever did carry it.
    SUPRA,
    /// @dev An allowlisted adapter contract, which **sets** the price. The permanent escape hatch:
    ///      a new oracle family becomes a small contract plus a config transaction rather than
    ///      another upgrade. This is the family a volatile asset (WETH) or a non-USD peg (EURC,
    ///      whose USD price floats with EUR/USD) uses.
    EXTERNAL_ADAPTER,
    /// @dev A USD peg an allowlisted adapter may mark **down** but never up. Distinct from
    ///      `EXTERNAL_ADAPTER` precisely because the capability is narrower: the quote is capped at
    ///      the peg in this contract, so a compromised adapter cannot inflate collateral — it can
    ///      only reduce it. See `SolidPriceProviderV2.priceUsdDetailed`.
    STABLE_ADAPTER
}

/**
 * @notice Per-token pricing configuration.
 * @dev Layout-compatible with the deployed `PriceFeedConfig`: `pairIndex` is **appended**, and it
 *      lands in the trailing padding of the third slot, so it costs no new storage slot and reads
 *      as 0 for every entry written by the previous implementation.
 * @param kind Which feed family evaluates this token
 * @param tokenDecimals Decimals of the priced token, cached to keep it off the hot path
 * @param baseDecimals `VEDA_ACCOUNTANT` only: decimals of the accountant's base asset
 * @param maxStaleness `VEDA_ACCOUNTANT` / `EXTERNAL_ADAPTER` / `STABLE_ADAPTER`: how old the source's last
 *        update may be. Zero disables the check, which is only ever correct for `STABLE`.
 * @param source `VEDA_ACCOUNTANT`: the accountant. `EXTERNAL_ADAPTER` / `STABLE_ADAPTER`: the
 *        adapter. Unused otherwise, and always zero for a bare `STABLE` peg.
 * @param baseAsset `VEDA_ACCOUNTANT` only: the accountant's base asset, itself priced by this provider
 * @param pegPriceUsd `STABLE` / `STABLE_ADAPTER`: the peg in 6-decimal USD, normally 1_000_000. For
 *        `STABLE_ADAPTER` it is the **ceiling** on what the adapter may quote, not merely a default.
 * @param minPriceUsd Absolute sanity floor applied to whatever the feed computes (6 decimals)
 * @param maxPriceUsd Absolute sanity ceiling applied to whatever the feed computes (6 decimals)
 * @param pairIndex **RESERVED.** Was the `SUPRA` pair index. Kept rather than removed because it
 *        occupies the third slot's trailing padding and costs nothing; removing it would churn a
 *        storage-layout comment for no gain.
 */
struct PriceFeedConfigV2 {
    PriceFeedKindV2 kind;
    uint8 tokenDecimals;
    uint8 baseDecimals;
    uint64 maxStaleness;
    address source;
    address baseAsset;
    uint96 pegPriceUsd;
    uint96 minPriceUsd;
    uint96 maxPriceUsd;
    uint32 pairIndex;
}

/**
 * @notice Single place every spend-module price comes from.
 * @dev Extends the v1 surface with `priceUsdDetailed`, which returns the source's own last-update
 *      timestamp. That is what lets `SolidCashModuleV2` enforce its **own** staleness bound rather
 *      than trusting the (upgradeable) provider's. Without it the module's independent price checks
 *      could catch an absurd value but not a stale-but-plausible one, which is precisely the
 *      exploitable case for a volatile asset.
 */
interface ISolidPriceProviderV2 {
    /**
     * @notice Price of one whole `token` in USD, 6 decimals.
     * @dev Never reverts. Every failure mode collapses to `(0, false)`.
     */
    function priceUsd(address token) external view returns (uint256 price, bool usable);

    /**
     * @notice `priceUsd` plus the source's last-update timestamp.
     * @dev Never reverts. `updatedAt` is `block.timestamp` for sources that carry no timestamp of
     *      their own (`STABLE`), so a caller's staleness check passes trivially for those — a peg
     *      is a constant, not an observation.
     * @return price USD price of one whole token, 6 decimals. Zero whenever `usable` is false.
     * @return usable False when unconfigured, paused, stale, or outside the configured band.
     * @return updatedAt Unix timestamp of the underlying observation.
     */
    function priceUsdDetailed(address token) external view returns (uint256 price, bool usable, uint64 updatedAt);

    /// @notice The configuration driving `priceUsd` for a token.
    function getConfig(address token) external view returns (PriceFeedConfigV2 memory);

    /// @notice Every token that currently has a feed configured.
    function configuredTokens() external view returns (address[] memory);

    /// @notice Whether `adapter` may be referenced by an `EXTERNAL_ADAPTER` config.
    function isAdapterAllowed(address adapter) external view returns (bool);
}
