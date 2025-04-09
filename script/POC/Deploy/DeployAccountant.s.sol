// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {IRateProvider} from "src/interfaces/IRateProvider.sol";
import {AccountantWithRateProviders} from "src/base/Roles/AccountantWithRateProviders.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

import {Script, console} from "forge-std/Script.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

// Custom wrapper to adapt Chainlink oracle to IRateProvider
contract ChainlinkRateProvider is IRateProvider {
    AggregatorV3Interface public immutable oracle;

    constructor(address _oracle) {
        oracle = AggregatorV3Interface(_oracle);
    }

    function getRate() external view override returns (uint256) {
        (, int256 answer, , , ) = oracle.latestRoundData();
        require(answer > 0, "Invalid price");
        return uint256(answer); // 8 decimals (Chainlink)
    }
}

/**
    source .env && forge script script/POC/Deploy/DeployAccountant.s.sol:DeployAccountant --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract DeployAccountant is Script {
    function run() external {
        vm.startBroadcast();

        // === CONFIG ===
        address VAULT = vm.envAddress("VAULT");
        address PAYOUT = vm.envAddress("DEPLOYER"); // Payout address for fees
        address BASE = vm.envAddress("USDC");
        address WETH = vm.envAddress("WETH");
        address CHAINLINK_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        // === ACCOUNTANT SETUP ===
        uint96 startExchangeRate = 1e6; // 1.00 USDC/share
        uint16 upper = 10500; // 5% max up
        uint16 lower = 9500; // 5% max down
        uint24 delay = 3600; // 1 hour min delay
        uint16 platformFee = 500; // 5% mgmt
        uint16 performanceFee = 1000; // 10% yield fee

        // 1. Deploy the Chainlink rate provider wrapper
        ChainlinkRateProvider rateProvider = new ChainlinkRateProvider(
            CHAINLINK_WETH_USD
        );
        console.log("ChainlinkRateProvider deployed:", address(rateProvider));

        // 2. Deploy the accountant
        AccountantWithRateProviders accountant = new AccountantWithRateProviders(
                msg.sender,
                VAULT,
                PAYOUT,
                startExchangeRate,
                BASE,
                upper,
                lower,
                delay,
                platformFee,
                performanceFee
            );
        console.log("Accountant deployed:", address(accountant));

        // 3. Link WETH to the Chainlink oracle wrapper
        accountant.setRateProviderData(
            ERC20(WETH),
            false, // not pegged
            address(rateProvider)
        );
        console.log("Rate provider set for WETH");

        vm.stopBroadcast();
    }
}
