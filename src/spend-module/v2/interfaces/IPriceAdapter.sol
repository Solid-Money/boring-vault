// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice The permanent extension point for new oracle families.
 * @dev An adapter is a small, independently auditable contract that translates one source into the
 *      provider's denomination. Adding an oracle therefore costs a deploy plus a config transaction
 *      instead of an upgrade to the contract that prices everyone's collateral.
 *
 *      **Contract an adapter must honour:**
 *        1. Return the price of one whole token in **6-decimal USD**. Owning the source's native
 *           decimals is the adapter's job, exactly as `VEDA_ACCOUNTANT` owns `baseDecimals`.
 *        2. Never revert. Report failure as `usable = false`. The provider defends against a
 *           violation anyway (bounded staticcall, returndata-length check), but an adapter that
 *           reverts makes every read of its token fail closed.
 *        3. Never call back into `SolidPriceProviderV2`. The provider's gas cap turns a violation
 *           into a fail-closed `(0, false)` rather than something dangerous, but it is still a bug.
 *        4. Be stateless with respect to callers, and view-only.
 */
interface IPriceAdapter {
    /**
     * @param token The token to price.
     * @return price Price of one whole token in 6-decimal USD. Must be 0 when `usable` is false.
     * @return usable False when this adapter cannot currently price `token`.
     * @return updatedAt Unix timestamp of the underlying observation, for the caller's staleness check.
     */
    function price(address token) external view returns (uint256 price, bool usable, uint64 updatedAt);
}
