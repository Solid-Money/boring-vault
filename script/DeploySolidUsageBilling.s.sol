// script/DeploySolidUsageBilling.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {SolidUsageBillingModule} from "src/solid-billing/SolidUsageBillingModule.sol";

/**
 * Deploys `SolidUsageBillingModule` on Base — the Safe module the AI API bills
 * usage through as it accrues, in dollars, from USDC first and then soUSD.
 *
 * Deployed with no `RolesAuthority` attached, like the rewards contracts: until
 * the owner attaches one and grants the biller role, only the owner can charge,
 * so a mis-set env var cannot hand billing rights to an address nobody meant.
 *
 * Required environment (every amount is micro-USD, 6 decimals):
 *   AI_BILLING_OWNER             — the multisig that will own the module
 *   AI_BILLING_TREASURY          — the only address it can ever pay. IMMUTABLE
 *   AI_BILLING_MAX_CHARGE_AMOUNT — org ceiling on one charge, e.g. 1000000000 = $1,000
 *   AI_BILLING_MIN_PERIOD        — shortest period a mandate's cap may apply to, seconds,
 *                                  e.g. 86400 = a day. IMMUTABLE
 *   AI_BILLING_TOKENS            — comma-separated, in draw order, e.g. USDC
 *   AI_BILLING_RATE_PROVIDERS    — comma-separated, same length; 0x0 = a dollar at par
 *
 * Optional:
 *   AI_BILLING_ALLOW_EOA_OWNER   — `true` to let a single key own the module. QA only:
 *                                  the owner sets what every billing token is worth, so
 *                                  on prod it must be a Safe needing 2+ signatures.
 *
 * See src/solid-billing/DEPLOYMENT.md for the full runbook.
 */
contract DeploySolidUsageBilling is Script {
    function run() external {
        address owner = vm.envAddress("AI_BILLING_OWNER");
        address treasury = vm.envAddress("AI_BILLING_TREASURY");
        (uint128 maxChargeAmount, uint64 minPeriod) =
            narrow(vm.envUint("AI_BILLING_MAX_CHARGE_AMOUNT"), vm.envUint("AI_BILLING_MIN_PERIOD"));
        address[] memory tokens = vm.envAddress("AI_BILLING_TOKENS", ",");
        address[] memory rateProviders = vm.envAddress("AI_BILLING_RATE_PROVIDERS", ",");

        require(block.chainid == 8453, "SolidUsageBillingModule is deployed on Base (8453)");
        checkOwner(owner, vm.envOr("AI_BILLING_ALLOW_EOA_OWNER", false));

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

    /**
     * The owner chooses the tokens a charge draws from and what each is worth, so it must
     * be a Safe that needs more than one signature: code alone could be a contract that can
     * never make the owner's calls. One key holding that is a QA choice, made by name, never
     * a mistyped prod address.
     */
    function checkOwner(address owner, bool allowSingleKey) public view {
        if (allowSingleKey) return;
        // An EOA answers with no data, and so does a contract that isn't a Safe.
        (bool ok, bytes memory data) = owner.staticcall(abi.encodeWithSignature("getThreshold()"));
        require(
            ok && data.length == 32 && abi.decode(data, (uint256)) > 1,
            "AI_BILLING_OWNER must be a Safe needing 2+ signatures (AI_BILLING_ALLOW_EOA_OWNER=true for QA only)"
        );
    }

    /// Checked before narrowing: a cast keeps only the low bits, so a mistyped value would deploy as another.
    function narrow(uint256 maxChargeAmount, uint256 minPeriod) public pure returns (uint128, uint64) {
        require(
            maxChargeAmount > 0 && maxChargeAmount <= type(uint128).max,
            "AI_BILLING_MAX_CHARGE_AMOUNT must be above 0 and fit in uint128"
        );
        // Its range (an hour to 1460 days) is the constructor's to enforce.
        require(minPeriod <= type(uint64).max, "AI_BILLING_MIN_PERIOD must fit in uint64");
        return (uint128(maxChargeAmount), uint64(minPeriod));
    }
}
