// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";

import {SpendModuleConfig} from "./SpendModuleConfig.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/**
 * @title UpgradeSolidPriceProvider
 * @notice Deploys a new provider implementation and switches the proxy to it.
 * @dev The provider is the upgradeable half of the split - new feed families cannot be enumerated in
 *      advance, and needing a per-user re-consent migration to add one would be its own risk. The
 *      module is deliberately not upgradeable.
 *
 *      That makes this the sharpest trust vector in the system: an implementation reporting any price
 *      turns a fixed USD debit into an arbitrary token amount. What bounds it is the module's own
 *      per-token band, applied to every price the module receives. So the check that matters after an
 *      upgrade is not "did it deploy" but "does every allowlisted token still price inside the
 *      module's band" - which is what this asserts, reverting the whole script if not.
 *
 *      **This script does not validate storage layout.** the openzeppelin-foundry-upgrades library is
 *      vendored in `lib/` but needs `ffi = true` plus `build_info`/`ast` output, which this repo does
 *      not enable. The Hardhat path (`scripts/spend-module/upgradeSolidPriceProvider.js`) does validate
 *      layout via the OpenZeppelin hardhat-upgrades plugin, so treat that as authoritative and use
 *      this script for rehearsal or for producing the calldata.
 *
 *      Rehearse against a fork first - it will report any price regression without broadcasting:
 *        forge script script/spend-module/UpgradeSolidPriceProvider.s.sol --fork-url $FUSE_RPC_URL -vvv
 *
 *      With a multisig UPGRADER_ROLE holder, CALLDATA_ONLY=1 deploys the implementation and prints the
 *      `upgradeToAndCall` payload without switching.
 */
contract UpgradeSolidPriceProvider is SpendModuleConfig {
    function run() external {
        address proxy = requireAddress("SolidPriceProvider", "DeploySpendModule.s.sol");
        SolidPriceProvider provider = SolidPriceProvider(proxy);
        SolidCashModule module = SolidCashModule(requireAddress("SolidCashModule", "DeploySpendModule.s.sol"));

        // Snapshot what the module accepts today, so the comparison afterwards means something.
        address[] memory tokens = module.allowedTokens();
        uint256[] memory pricesBefore = new uint256[](tokens.length);
        bool[] memory usableBefore = new bool[](tokens.length);

        console.log("Proxy:", proxy);
        console.log("Allowlisted tokens:", tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (pricesBefore[i], usableBefore[i]) = module.getPriceUsd(tokens[i]);
            console.log("  before:", tokens[i]);
            logUsd("    price", pricesBefore[i]);
        }

        vm.startBroadcast();

        SolidPriceProvider implementation = new SolidPriceProvider();
        console.log("\nNew implementation:", address(implementation));

        if (vm.envOr("CALLDATA_ONLY", false)) {
            vm.stopBroadcast();
            console.log("\nCALLDATA_ONLY - submit from the UPGRADER_ROLE holder:");
            console.log("  to:  ", proxy);
            console.logBytes(abi.encodeCall(IUUPS.upgradeToAndCall, (address(implementation), "")));
            saveAddress("SolidPriceProviderPendingImplementation", address(implementation));
            return;
        }

        require(
            provider.hasRole(keccak256("UPGRADER_ROLE"), msg.sender),
            "signer lacks UPGRADER_ROLE - rerun with CALLDATA_ONLY=1"
        );

        IUUPS(proxy).upgradeToAndCall(address(implementation), "");
        console.log("Upgraded.");

        vm.stopBroadcast();

        saveAddress("SolidPriceProviderImplementation", address(implementation));

        // The check that matters: prices the module will accept, not what the provider reports.
        console.log("\nPost-upgrade, through the module (its own band applied):");
        bool regressed = false;
        for (uint256 i = 0; i < tokens.length; ++i) {
            (uint256 priceAfter, bool usableAfter) = module.getPriceUsd(tokens[i]);
            console.log("  after:", tokens[i]);
            logUsd("    price", priceAfter);

            if (usableBefore[i] && !usableAfter) {
                console.log("  ERROR: was usable before the upgrade, is not now");
                regressed = true;
                continue;
            }
            if (usableBefore[i] && priceAfter != pricesBefore[i]) {
                uint256 delta =
                    priceAfter > pricesBefore[i] ? priceAfter - pricesBefore[i] : pricesBefore[i] - priceAfter;
                uint256 deltaBps = (delta * 10_000) / pricesBefore[i];
                console.log("    changed by (bps):", deltaBps);

                // A yield-bearing share's rate moves between blocks, so a small change is expected.
                if (deltaBps > 100) {
                    console.log("  ERROR: moved more than 1% across the upgrade");
                    regressed = true;
                }
            }
        }

        require(!regressed, "post-upgrade price regression - roll back the implementation");
        console.log("\nUpgrade complete, prices unchanged within tolerance.");
    }
}
