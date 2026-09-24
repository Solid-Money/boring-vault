// script/DeploySolidTierLockZap.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {SolidTierLockZap} from "src/solid-rewards/SolidTierLockZap.sol";

/**
 * Deploys the zap that turns "deposit into Savings, then lock" into one call.
 *
 * Separate from `DeploySolidRewards` because it needs an address that script
 * produces: the lock. Run it afterwards, against a lock that already exists.
 *
 * The zap is inert until the lock's authority grants it `lockFor` — see step 11
 * of DEPLOYMENT.md. That is deliberate and the same shape as the biller role: a
 * contract that can credit a lock is not something a deployment should be able
 * to conjure by setting an env var.
 *
 * Required environment:
 *   OWNER        — the multisig that owns the rewards contracts
 *   TIER_LOCK    — the deployed SolidTierLock
 *   SOFUSE_TELLER— the Teller that mints the share the lock escrows
 *
 * The constructor checks the Teller and the lock agree on the vault, so a zap
 * pointed at the wrong Teller fails here rather than on the first user.
 */
contract DeploySolidTierLockZap is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address tierLock = vm.envAddress("TIER_LOCK");
        address teller = vm.envAddress("SOFUSE_TELLER");

        vm.startBroadcast();

        SolidTierLockZap zap = new SolidTierLockZap(owner, tierLock, teller);
        console.log("SolidTierLockZap:", address(zap));

        vm.stopBroadcast();

        console.log("");
        console.log("Next, as the owner of the lock and of the authority:");
        console.log("  1. lock.setAuthority(<FuseRolesAuthority>)");
        console.log("  2. authority.setRoleCapability(ZAP_ROLE, lock, lockFor.selector, true)");
        console.log("  3. authority.setUserRole(<this zap>, ZAP_ROLE, true)");
        console.log("");
        console.log("Then set TIER_LOCK_ZAP_ADDRESS in the backend and redeploy it.");
    }
}
