// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";
import {ResolvDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/ResolvDecoderAndSanitizer.sol";
import {OneInchDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import {NativeWrapperDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/NativeWrapperDecoderAndSanitizer.sol";
import {TellerDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/TellerDecoderAndSanitizer.sol";
import {OdosDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/OdosDecoderAndSanitizer.sol";

contract HyperUsdDecoderAndSanitizer is 
    ResolvDecoderAndSanitizer, 
    OneInchDecoderAndSanitizer,
    NativeWrapperDecoderAndSanitizer,
    TellerDecoderAndSanitizer,
    OdosDecoderAndSanitizer
{
    constructor(address _odosRouter) OdosDecoderAndSanitizer(_odosRouter) {
        
    }
    // Override withdraw to resolve conflict between NativeWrapper and Resolv
    function withdraw(uint256) 
        external 
        pure 
        override(NativeWrapperDecoderAndSanitizer, ResolvDecoderAndSanitizer) 
        returns (bytes memory addressesFound) 
    {
        // This handles both WETH withdrawals and stUSR withdrawals
        return addressesFound;
    }
}