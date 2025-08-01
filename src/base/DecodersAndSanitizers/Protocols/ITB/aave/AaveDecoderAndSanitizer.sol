/* SPDX-License-Identifier: UNLICENSED */
pragma solidity ^0.8.0;

contract AaveDecoderAndSanitizer {
    function deposit(address asset, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(asset);
    }

    function withdrawSupply(address asset, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(asset);
    }
}
