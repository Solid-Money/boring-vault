// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";

import {SpendModuleConfig} from "./SpendModuleConfig.sol";

/**
 * @title HandOverOwnership
 * @notice Moves every privileged key to its production holder. Only needed if the deploy ran with
 *         SKIP_HANDOVER set - otherwise `DeploySpendModule` already did this.
 * @dev Ordering is deliberate and not rearrangeable:
 *        1. grant the provider's roles to the new holders
 *        2. renounce the deployer's - grant before renounce, or the proxy becomes permanently
 *           unadministrable and un-upgradeable
 *        3. transfer the authority's owner
 *        4. transfer the module's owner, last, because it gates redoing any of the above
 *
 *        forge script script/spend-module/HandOverOwnership.s.sol --rpc-url fuse --broadcast -vvv
 */
contract HandOverOwnership is SpendModuleConfig {
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PRICE_ADMIN_ROLE = keccak256("PRICE_ADMIN_ROLE");
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function run() external {
        address deployer = msg.sender;
        address finalOwner = owner();
        address newPriceAdmin = priceAdmin();

        require(finalOwner != deployer, "configured owner is the signer - nothing to hand over");

        // PRICE_ADMIN is the one role this script can silently ORPHAN, and it is the default
        // configuration that does it: `priceAdmin()` falls back to `owner()`, but a .env carried over
        // from the deploy usually still points it at the deployer. The grant below is then skipped
        // (the deployer already holds it) and step 2 renounces it, leaving the role with nobody and
        // `setTokenConfig` uncallable until the new owner re-grants it. Recoverable, but nothing in
        // the output says it happened - so it is a hard failure here instead.
        require(
            newPriceAdmin != deployer,
            "PRICE_ADMIN is the signer: point it at the new owner or a separate key, or the renounce below orphans the role"
        );

        SolidPriceProvider provider =
            SolidPriceProvider(requireAddress("SolidPriceProvider", "DeploySpendModule.s.sol"));
        FuseRolesAuthority authority =
            FuseRolesAuthority(requireAddress("FuseRolesAuthority", "DeploySpendModule.s.sol"));
        SolidCashModule module = SolidCashModule(requireAddress("SolidCashModule", "DeploySpendModule.s.sol"));

        if (newPriceAdmin == finalOwner) {
            console.log("WARNING: PRICE_ADMIN_ROLE and UPGRADER_ROLE will both sit on the owner.");
            console.log("         Set PRICE_ADMIN to split feed configuration from upgrade authority.");
        }

        vm.startBroadcast();

        // 1. Grant, before renouncing anything.
        if (!provider.hasRole(DEFAULT_ADMIN_ROLE, finalOwner)) provider.grantRole(DEFAULT_ADMIN_ROLE, finalOwner);
        if (!provider.hasRole(UPGRADER_ROLE, finalOwner)) provider.grantRole(UPGRADER_ROLE, finalOwner);
        if (!provider.hasRole(PRICE_ADMIN_ROLE, newPriceAdmin)) provider.grantRole(PRICE_ADMIN_ROLE, newPriceAdmin);
        console.log("provider roles granted to:", finalOwner);

        require(provider.hasRole(DEFAULT_ADMIN_ROLE, finalOwner), "refusing to renounce into a bricked proxy");
        require(provider.hasRole(UPGRADER_ROLE, finalOwner), "refusing to renounce into an un-upgradeable proxy");
        require(provider.hasRole(PRICE_ADMIN_ROLE, newPriceAdmin), "refusing to renounce PRICE_ADMIN into nobody");

        // 2. Renounce the deployer's. `renounceRole` only accepts the caller's own account.
        if (provider.hasRole(PRICE_ADMIN_ROLE, deployer)) provider.renounceRole(PRICE_ADMIN_ROLE, deployer);
        if (provider.hasRole(UPGRADER_ROLE, deployer)) provider.renounceRole(UPGRADER_ROLE, deployer);
        if (provider.hasRole(DEFAULT_ADMIN_ROLE, deployer)) provider.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console.log("deployer provider roles renounced");

        // 3. Authority.
        if (authority.owner() == deployer) {
            authority.transferOwnership(finalOwner);
            console.log("authority owner ->", finalOwner);
        } else {
            console.log("authority already owned by:", authority.owner());
        }

        // 4. Module last.
        if (module.owner() == deployer) {
            module.transferOwnership(finalOwner);
            console.log("module owner    ->", finalOwner);
        } else {
            console.log("module already owned by:", module.owner());
        }

        vm.stopBroadcast();

        // GUARDIAN_ROLE is deliberately NOT touched. It is a *user* role on the authority, not an
        // admin one, and it holds only pause / unpause / setSafePaused - no ability to move value. A
        // pause has to land in seconds during an incident, which is the one thing a multisig is bad
        // at, so leaving it on a hot key is the intended shape (see SpendModuleConfig.guardian).
        // Move it with `authority.setUserRole(<addr>, 2, true/false)` if that is not what you want.
        console.log("");
        console.log("GUARDIAN_ROLE was NOT moved - it is a hot pause key by design. Current holder:");
        console.log("  ", guardian());
        console.log("");
        console.log("Handover complete. Run VerifySpendModule.s.sol to confirm.");
    }
}
