// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer, DecoderCustomTypes} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

abstract contract OneInchDecoderAndSanitizer is BaseDecoderAndSanitizer {
    //============================== ERRORS ===============================

    error OneInchDecoderAndSanitizer__PermitNotSupported();
    error OneInchDecoderAndSanitizer__RouterNotAllowed();

    //============================== ONEINCH ===============================

    function swap(
        address executor,
        DecoderCustomTypes.SwapDescription calldata desc,
        bytes calldata permit,
        bytes calldata
    ) external pure returns (bytes memory addressesFound) {
        if (permit.length > 0) revert OneInchDecoderAndSanitizer__PermitNotSupported();
        addressesFound = abi.encodePacked(executor, desc.srcToken, desc.dstToken, desc.srcReceiver, desc.dstReceiver);
    }

    /**
     * @notice Enhanced swap function that supports multiple router addresses
     * @dev The first address in packedArgumentAddresses should be the selected router
     * @dev Additional router addresses can be included for validation
     */
    function swapWithRouterSelection(
        address executor,
        DecoderCustomTypes.SwapDescription calldata desc,
        bytes calldata permit,
        bytes calldata routerData
    ) external pure returns (bytes memory addressesFound) {
        if (permit.length > 0) revert OneInchDecoderAndSanitizer__PermitNotSupported();
        
        // Extract router addresses from routerData (first 20 bytes is selected router)
        address selectedRouter = abi.decode(routerData[:20], (address));
        
        // Validate router is in allowed list (routerData[20:] contains allowed routers)
        bool routerAllowed = false;
        uint256 offset = 20;
        while (offset < routerData.length) {
            address allowedRouter = abi.decode(routerData[offset:offset+20], (address));
            if (selectedRouter == allowedRouter) {
                routerAllowed = true;
                break;
            }
            offset += 20;
        }
        
        if (!routerAllowed) revert OneInchDecoderAndSanitizer__RouterNotAllowed();
        
        addressesFound = abi.encodePacked(selectedRouter, executor, desc.srcToken, desc.dstToken, desc.srcReceiver, desc.dstReceiver);
    }

    function uniswapV3Swap(uint256, uint256, uint256[] calldata pools)
        external
        pure
        returns (bytes memory addressesFound)
    {
        for (uint256 i; i < pools.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, uint160(pools[i]));
        }
    }
}
