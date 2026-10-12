// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";

import {SpendModuleV2Config} from "./SpendModuleV2Config.sol";

/**
 * @title SealSettersV2
 * @notice Step E: close the upgrade hatch permanently.
 * @dev The core's fallback `delegatecall`s every unknown selector into `settersImpl`, which runs with
 *      the core's storage and its escrowed collateral. Being able to set it is being able to replace
 *      the module — in a contract whose header states it is deliberately not upgradeable. That gate
 *      is already `owner`-only rather than `requiresAuth`, so no authority grant can open it; sealing
 *      removes it from the owner too.
 *
 *      **One way. There is no unseal.** After this, a mechanics change is a new deployment plus the
 *      documented per-user migration, which was always the plan — the split exists to fit EIP-170,
 *      not because the configuration half is expected to change. Parameters, token configuration,
 *      pauses and the limit waivers all keep working: sealing freezes the implementation, not the
 *      configuration it exposes.
 *
 *      Its own step, not part of the deploy, for one reason: everything reachable only through the
 *      setters half — every repay path, every parameter, the guardian's breakers — should have been
 *      exercised against the real deployment before the ability to replace that half is given up.
 *      Soak first, then seal.
 *
 *      Rehearse:
 *        forge script script/spend-module/v2/SealSettersV2.s.sol --fork-url $FUSE_RPC_URL -vvv
 *
 *      With a multisig owner, CALLDATA_ONLY=1 prints the payload without sending.
 */
contract SealSettersV2 is SpendModuleV2Config {
    function run() external {
        SolidCashModuleV2 core = SolidCashModuleV2(requireAddress("SolidCashModuleV2", "DeploySpendModuleV2.s.sol"));
        requireHasCode(address(core), "core");

        address impl = core.settersImpl();
        require(impl != address(0), "settersImpl is unset - nothing to seal");
        requireHasCode(impl, "settersImpl");

        if (core.settersSealed()) {
            console.log("Already sealed. Nothing to do.");
            return;
        }

        // The seal is only meaningful over the implementation that is actually wired, so prove the
        // wired one is the one that was reviewed before freezing it in place.
        require(
            SolidCashModuleV2Setters(impl).settlementTreasury() == core.settlementTreasury(),
            "wired setters disagree about the treasury - do not seal"
        );
        require(
            SolidCashModuleV2Setters(impl).v1Module() == core.v1Module(),
            "wired setters disagree about the v1 module - do not seal"
        );

        console.log("Core:        ", address(core));
        console.log("Setters:     ", impl);
        console.log("Owner:       ", core.owner());
        console.log("");
        console.log("Sealing is PERMANENT. After this, replacing the configuration half requires a");
        console.log("new module deployment and a per-user re-consent migration.");

        if (vm.envOr("CALLDATA_ONLY", false)) {
            console.log("\nCALLDATA_ONLY - submit from the owner:");
            console.log("  to:  ", address(core));
            console.logBytes(abi.encodeCall(SolidCashModuleV2.sealSetters, ()));
            return;
        }

        require(msg.sender == core.owner(), "signer is not the owner - rerun with CALLDATA_ONLY=1");

        vm.startBroadcast();
        core.sealSetters();
        vm.stopBroadcast();

        require(core.settersSealed(), "seal did not take");
        console.log("\nSealed. `setSettersImpl` now reverts for everyone, permanently.");
    }
}
