// script/DeploySolidUsageBilling.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {SolidUsageBillingModule} from "src/solid-billing/SolidUsageBillingModule.sol";

/**
 * Deploys `SolidUsageBillingModule` on Base — the Safe module the AI API bills
 * a day's usage through, in dollars, from USDC first and then soUSD.
 *
 * Deployed with no `RolesAuthority` attached, like the rewards contracts: until
 * the owner attaches one and grants the biller role, only the owner can charge,
 * so a mis-set env var cannot hand billing rights to an address nobody meant.
 *
 * Required environment (every amount is micro-USD, 6 decimals):
 *   AI_BILLING_OWNER             — the multisig that will own the module
 *   AI_BILLING_TREASURY          — the only address it can ever pay. IMMUTABLE
 *   AI_BILLING_MAX_CHARGE_AMOUNT — org ceiling on one charge, e.g. 1000000000 = $1,000
 *   AI_BILLING_MIN_PERIOD        — shortest period a user may sign, seconds. IMMUTABLE
 *   AI_BILLING_TOKENS            — comma-separated, in draw order, e.g. USDC
 *   AI_BILLING_RATE_PROVIDERS    — comma-separated, same length; 0x0 = a dollar at par
 *
 * See src/solid-billing/DEPLOYMENT.md for the full runbook.
 */
contract DeploySolidUsageBilling is Script {
    function run() external {
        address owner = vm.envAddress("AI_BILLING_OWNER");
        address treasury = vm.envAddress("AI_BILLING_TREASURY");
        uint128 maxChargeAmount = uint128(vm.envUint("AI_BILLING_MAX_CHARGE_AMOUNT"));
        uint64 minPeriod = uint64(vm.envUint("AI_BILLING_MIN_PERIOD"));
        address[] memory tokens = vm.envAddress("AI_BILLING_TOKENS", ",");
        address[] memory rateProviders = vm.envAddress("AI_BILLING_RATE_PROVIDERS", ",");

        require(block.chainid == 8453, "SolidUsageBillingModule is deployed on Base (8453)");

        vm.startBroadcast();

        SolidUsageBillingModule module =
            new SolidUsageBillingModule(owner, treasury, maxChargeAmount, minPeriod, tokens, rateProviders);
        console.log("SolidUsageBillingModule:", address(module));

        vm.stopBroadcast();

        console.log("");
        console.log("Next, as the owner (src/solid-billing/DEPLOYMENT.md, step 7):");
        console.log("  1. module.setAuthority(<RolesAuthority on Base>)");
        console.log("  2. authority.setRoleCapability(BILLER_ROLE, module, charge.selector, true)");
        console.log("  3. authority.setUserRole(<backend smart account on Base>, BILLER_ROLE, true)");
        console.log("");
        console.log("The biller is the ERC-4337 account the backend submits from on chain 8453,");
        console.log("NOT the EOA that signs for it.");
    }
}
