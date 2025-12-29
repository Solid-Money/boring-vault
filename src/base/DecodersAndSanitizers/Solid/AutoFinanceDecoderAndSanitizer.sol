// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract AutoFinanceDecoderAndSanitizer is BaseDecoderAndSanitizer {
    function stake(address account, uint256) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(account);
    }

    function withdraw(address account, uint256, bool) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(account);
    }

    function getReward(address account, address recipient, bool) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(account, recipient);
    }
}