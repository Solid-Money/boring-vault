// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ISolidPriceProviderV2, PriceFeedConfigV2} from "src/spend-module/v2/interfaces/ISolidPriceProviderV2.sol";

/**
 * @notice Directly settable stand-in for `SolidPriceProviderV2`.
 * @dev The real provider reaches a price through an allowlisted adapter or a Veda accountant, neither of
 *      which a test about *funding modes* has any business standing up. What the module actually
 *      consumes is three words from `priceUsdDetailed`, so that is the whole surface here.
 *
 *      `setUsable(false)` reproduces the one degraded case the mode paths care about: a feed that
 *      is down, which must make a position un-liquidatable and understate borrowing power without
 *      reverting anything.
 */
contract MockPriceProviderV2 is ISolidPriceProviderV2 {
    struct Feed {
        uint256 price;
        bool usable;
        uint64 updatedAt;
    }

    mapping(address => Feed) internal feed;

    function setPrice(address token, uint256 priceUsd6) external {
        feed[token] = Feed({price: priceUsd6, usable: true, updatedAt: uint64(block.timestamp)});
    }

    function setUsable(address token, bool usable) external {
        feed[token].usable = usable;
    }

    function setUpdatedAt(address token, uint64 updatedAt) external {
        feed[token].updatedAt = updatedAt;
    }

    function priceUsd(address token) external view returns (uint256, bool) {
        Feed memory f = feed[token];
        return f.usable ? (f.price, true) : (0, false);
    }

    function priceUsdDetailed(address token) external view returns (uint256, bool, uint64) {
        Feed memory f = feed[token];
        if (!f.usable) return (0, false, f.updatedAt);
        return (f.price, true, f.updatedAt);
    }

    function getConfig(address) external pure returns (PriceFeedConfigV2 memory config) {
        return config;
    }

    function configuredTokens() external pure returns (address[] memory list) {
        return list;
    }

    function isAdapterAllowed(address) external pure returns (bool) {
        return false;
    }
}
