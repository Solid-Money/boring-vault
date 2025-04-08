// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MessagingParams, MessagingReceipt, ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

//HardhatError: HH700: Artifact for contract "lz-evm-oapp-v2" not found. 

/// @title VaultRateSender (LZ V2)
/// @notice Sends exchange rate updates from Ethereum to another chain (e.g., Fuse)
contract VaultRateSender {
    ILayerZeroEndpointV2 public immutable endpoint;
    address public immutable accountant;
    address public immutable owner;

    constructor(address _endpoint, address _accountant) {
        endpoint = ILayerZeroEndpointV2(_endpoint);
        accountant = _accountant;
        owner = msg.sender;
    }

    function getExchangeRate() public view returns (uint256) {
        (bool success, bytes memory data) = accountant.staticcall(
            abi.encodeWithSignature("exchangeRate()")
        );
        require(success, "Failed to fetch exchange rate");
        return abi.decode(data, (uint256));
    }

    /// @notice Sends the exchange rate to the destination chain
    /// @param dstEid The LayerZero v2 endpoint ID of the target chain (e.g., Fuse)
    /// @param receiver The address of the VaultRateReceiver on the destination chain
    /// @param options Custom LayerZero send options
    function sendExchangeRate(
        uint32 dstEid,
        address receiver,
        bytes calldata options
    ) external payable returns (MessagingReceipt memory receipt) {
        require(msg.sender == owner, "Not authorized");

        uint256 rate = getExchangeRate();

        MessagingParams memory params = MessagingParams({
            dstEid: dstEid,
            receiver: addressToBytes32(receiver),
            message: abi.encode(rate),
            options: options,
            payInLzToken: false
        });

        receipt = endpoint.send{value: msg.value}(params, payable(msg.sender));
    }

    function addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
