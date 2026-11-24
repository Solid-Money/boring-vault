// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract KyberswapRouterDecoderAndSanitizer is BaseDecoderAndSanitizer {
    // Canonical layout for selector 0xe21fd0e9 (MetaAggregationRouterV2.swap). Use address not IERC20 so ABI tuple matches.
    struct SwapDescriptionV2 {
        address srcToken;
        address dstToken;
        address[] srcReceivers;
        uint256[] srcAmounts;
        address[] feeReceivers;
        uint256[] feeAmounts;
        address dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
        bytes permit;
    }

    struct SwapExecutionParams {
        address callTarget;
        address approveTarget;
        bytes targetData;
        SwapDescriptionV2 desc;
        bytes clientData;
    }

    function swap(SwapExecutionParams calldata execution)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(
            execution.callTarget,
            execution.approveTarget,
            execution.desc.srcToken,
            execution.desc.dstToken,
            execution.desc.srcReceivers,
            execution.desc.dstReceiver
        );
    }
}
