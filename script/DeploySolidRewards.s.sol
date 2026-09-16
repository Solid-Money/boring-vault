// script/DeploySolidRewards.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {SolidTierLock} from "src/solid-rewards/SolidTierLock.sol";
import {SolidSubscriptionModule} from "src/solid-rewards/SolidSubscriptionModule.sol";

/**
 * Deploys the two contracts behind rewards v3 tier upgrades on Fuse.
 *
 *  - `SolidTierLock` escrows soFUSE shares for a fixed term, which is one of the
 *    two ways to hold Prime or Ultra.
 *  - `SolidSubscriptionModule` is the Safe module that collects the annual fee,
 *    which is the other.
 *
 * Both take the owner as a constructor argument and neither is deployed with a
 * `RolesAuthority` attached. That is deliberate: the authority is set afterwards
 * by the owner, and until it is, only the owner can call anything gated. The
 * biller role in particular has to be granted explicitly, so a mis-set env var
 * cannot silently hand billing rights to an address nobody meant.
 *
 * Required environment:
 *   OWNER                     — the multisig that will own both contracts
 *   SOFUSE_VAULT              — the soFUSE BoringVault (the share token)
 *   SOFUSE_ACCOUNTANT         — its AccountantWithRateProviders
 *   USDC                      — the billing asset on Fuse
 *   REVENUE_TREASURY          — the only address the module can ever pay
 *   LOCK_DURATION_SECONDS     — the term, e.g. 31536000 for 365 days
 *   MIN_LOCK_SHARES           — the smallest lock worth taking, in shares
 *   MAX_CHARGE_AMOUNT         — org ceiling on one charge, in USDC units
 */
contract DeploySolidRewards is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address soFuseVault = vm.envAddress("SOFUSE_VAULT");
        address soFuseAccountant = vm.envAddress("SOFUSE_ACCOUNTANT");
        address usdc = vm.envAddress("USDC");
        address revenueTreasury = vm.envAddress("REVENUE_TREASURY");
        uint64 lockDuration = uint64(vm.envUint("LOCK_DURATION_SECONDS"));
        uint256 minLockShares = vm.envUint("MIN_LOCK_SHARES");
        uint128 maxChargeAmount = uint128(vm.envUint("MAX_CHARGE_AMOUNT"));

        vm.startBroadcast();

        SolidTierLock tierLock =
            new SolidTierLock(owner, soFuseVault, soFuseAccountant, lockDuration, minLockShares);
        console.log("SolidTierLock:", address(tierLock));

        SolidSubscriptionModule subscriptionModule =
            new SolidSubscriptionModule(owner, usdc, revenueTreasury, maxChargeAmount);
        console.log("SolidSubscriptionModule:", address(subscriptionModule));

        vm.stopBroadcast();

        console.log("");
        console.log("Next, as the owner:");
        console.log("  1. setAuthority(<FuseRolesAuthority>) on both contracts");
        console.log("  2. authority.setRoleCapability(BILLER_ROLE, module, charge.selector, true)");
        console.log("  3. authority.setUserRole(<billing signer>, BILLER_ROLE, true)");
    }
}
