// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ILayerZeroEndpointV2, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract VaultRateReceiver {
    ILayerZeroEndpointV2 public immutable endpoint;
    uint32 public immutable sourceEid;

    address public owner;
    uint256 public latestRate;
    uint64 public lastReceivedNonce;

    event RateUpdated(uint256 rate, uint64 nonce);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _endpoint, uint32 _sourceEid) {
        endpoint = ILayerZeroEndpointV2(_endpoint);
        sourceEid = _sourceEid;
        owner = msg.sender;
    }

    /// @notice LayerZero V2 receive hook
    /// @dev This must match the signature expected by the endpoint
    function lzReceive(
        Origin calldata origin,
        bytes32 /* guid */,
        bytes calldata message,
        bytes calldata /* extraData */
    ) external {
        require(msg.sender == address(endpoint), "Unauthorized endpoint");
        require(origin.srcEid == sourceEid, "Invalid source EID");

        latestRate = abi.decode(message, (uint256));
        lastReceivedNonce = origin.nonce;

        emit RateUpdated(latestRate, origin.nonce);
    }

    function getLatestRate() external view returns (uint256) {
        return latestRate;
    }
}
