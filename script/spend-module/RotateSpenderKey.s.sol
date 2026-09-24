// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";

import {SpendModuleConfig} from "./SpendModuleConfig.sol";

/**
 * @title RotateSpenderKey
 * @notice Moves SPENDER_ROLE from one sweep key to another.
 * @dev The sweep signer is not stored on the module - it is a role assignment on the
 *      authority, so rotation never touches the module and never needs user re-consent.
 *
 *      **Grant before revoke, and they are deliberately separate runs.** By settlement
 *      time Wirex has already paid the merchant, so a window where no key can call
 *      `spend` is a window where Solid absorbs those transactions. The safe sequence is:
 *      grant the new key, cut the backend over, watch settlements land, then revoke the
 *      old key. Doing both in one transaction would collapse that window to zero *only*
 *      if the backend switched at the same instant, which it cannot.
 *
 *      Both keys can settle during the overlap. That is intended - `txId` is consumed
 *      per Safe, not per key, so a debit cannot be replayed by the other key, and the
 *      caps are per Safe rather than per signer. Two live keys widen the compromise
 *      surface but change no bound, which is why the overlap is acceptable and should
 *      still be short.
 *
 *      Grant the new key:
 *        NEW_SPENDER=0x.. forge script script/spend-module/RotateSpenderKey.s.sol \
 *          --rpc-url fuse --broadcast --private-key $PRIVATE_KEY -vvv
 *
 *      Then, once the backend is signing with it:
 *        OLD_SPENDER=0x.. REVOKE=true forge script script/spend-module/RotateSpenderKey.s.sol \
 *          --rpc-url fuse --broadcast --private-key $PRIVATE_KEY -vvv
 *
 *      Rehearse either step by dropping --broadcast.
 */
contract RotateSpenderKey is SpendModuleConfig {
    function run() external {
        FuseRolesAuthority authority =
            FuseRolesAuthority(requireAddress("FuseRolesAuthority", "DeploySpendModule.s.sol"));
        SolidCashModule module = SolidCashModule(requireAddress("SolidCashModule", "DeploySpendModule.s.sol"));

        // Read the authority off the module rather than trusting the record: rotating the
        // wrong authority would appear to succeed and change nothing.
        require(address(module.authority()) == address(authority), "record authority is not the module's authority");

        bool revoke = vm.envOr("REVOKE", false);
        address newSpender = vm.envOr("NEW_SPENDER", address(0));
        address oldSpender = vm.envOr("OLD_SPENDER", address(0));

        console.log("Authority:        ", address(authority));
        console.log("Authority owner:  ", authority.owner());
        console.log("Signer:           ", msg.sender);
        require(authority.owner() == msg.sender, "signer does not own the authority");

        // The capability, not just the assignment. A role that cannot call `spend` makes
        // the whole rotation a no-op that looks like it worked.
        require(
            authority.doesRoleHaveCapability(SPENDER_ROLE, address(module), SolidCashModule.spend.selector),
            "SPENDER_ROLE cannot call spend on this module"
        );

        if (revoke) {
            _revoke(authority, oldSpender, newSpender);
        } else {
            _grant(authority, newSpender, oldSpender);
        }
    }

    function _grant(FuseRolesAuthority authority, address newSpender, address oldSpender) private {
        require(newSpender != address(0), "NEW_SPENDER is required");
        require(!authority.doesUserHaveRole(newSpender, SPENDER_ROLE), "NEW_SPENDER already holds SPENDER_ROLE");

        console.log("\nGranting SPENDER_ROLE to:", newSpender);

        vm.startBroadcast();
        authority.setUserRole(newSpender, SPENDER_ROLE, true);
        vm.stopBroadcast();

        require(authority.doesUserHaveRole(newSpender, SPENDER_ROLE), "grant did not take effect");
        console.log("Granted.");

        // Named explicitly so the second step cannot be run against the wrong address
        // from memory, and so it is obvious the old key is still live right now.
        console.log("");
        console.log("The old key can still settle. Once the backend signs with the new key, revoke it:");
        if (oldSpender != address(0)) {
            console.log("  OLD_SPENDER=", oldSpender);
        } else {
            console.log("  OLD_SPENDER=<previous sweep key>  (pass OLD_SPENDER here to have it echoed)");
        }
        console.log("  REVOKE=true forge script script/spend-module/RotateSpenderKey.s.sol --rpc-url fuse --broadcast");
    }

    function _revoke(FuseRolesAuthority authority, address oldSpender, address newSpender) private {
        require(oldSpender != address(0), "OLD_SPENDER is required to revoke");
        require(authority.doesUserHaveRole(oldSpender, SPENDER_ROLE), "OLD_SPENDER does not hold SPENDER_ROLE");

        // Refuse to leave nobody able to settle. RolesAuthority cannot enumerate role
        // holders, so the replacement has to be named and checked rather than inferred -
        // without this, a mistyped rotation silently disables settlement entirely and the
        // first symptom is unsettled card transactions.
        require(newSpender != address(0), "pass NEW_SPENDER too, so the replacement can be confirmed live");
        require(newSpender != oldSpender, "NEW_SPENDER and OLD_SPENDER are the same address");
        require(
            authority.doesUserHaveRole(newSpender, SPENDER_ROLE),
            "NEW_SPENDER does not hold SPENDER_ROLE yet - run the grant step first"
        );

        console.log("\nReplacement key confirmed live:", newSpender);
        console.log("Revoking SPENDER_ROLE from:     ", oldSpender);

        vm.startBroadcast();
        authority.setUserRole(oldSpender, SPENDER_ROLE, false);
        vm.stopBroadcast();

        require(!authority.doesUserHaveRole(oldSpender, SPENDER_ROLE), "revoke did not take effect");
        require(authority.doesUserHaveRole(newSpender, SPENDER_ROLE), "replacement lost SPENDER_ROLE");

        console.log("Revoked. Rotation complete.");
        console.log("");
        console.log("Update SPENDER in .env so VerifySpendModule.s.sol checks the new key.");
    }
}
