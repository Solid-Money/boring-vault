// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {SolidPriceProviderV2} from "src/spend-module/v2/SolidPriceProviderV2.sol";

import {SpendModuleV2Config} from "./SpendModuleV2Config.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @dev The slice of the live v1 module this script checks itself against.
interface ISolidCashModuleV1Read {
    function allowedTokens() external view returns (address[] memory);
    function getPriceUsd(address token) external view returns (uint256, bool);
}

/**
 * @title UpgradePriceProviderV2
 * @notice Step A: put `SolidPriceProviderV2` behind the live provider proxy.
 * @dev **This runs underneath a live v1 module serving real cardholders**, which is why it is its own
 *      step rather than part of the v2 deployment. The proxy is shared: every v1 spend prices through
 *      it, so a regression here declines cards for a cohort that has nothing to do with v2.
 *
 *      The check that matters afterwards is therefore not "did it deploy" but "does every token the
 *      LIVE v1 module allowlists still price, and at the same number" — asserted below, reverting the
 *      whole script if not.
 *
 *      Storage compatibility was verified by hand rather than by tooling: the inheritance prefix is
 *      identical, `_adapterAllowed` consumes the first word of the old `uint256[45] __gap` (which
 *      shrinks to 44 to pay for it), and `PriceFeedConfigV2` appends `pairIndex` into the trailing
 *      padding of the config's fourth slot, so it costs no slot and reads as 0 for every entry the
 *      previous implementation wrote. **This script does not re-check that.** The repo does not
 *      enable the `ffi`/`build_info`/`ast` output the openzeppelin-foundry-upgrades library needs;
 *      the Hardhat path validates layout through the OZ plugin, so treat that as authoritative for a
 *      production run and use this for rehearsal or to produce the calldata.
 *
 *      Nothing here touches feed configuration — the bare pegs are step B, deliberately separate, so
 *      the upgrade can be rolled back without also having to undo a config rewrite.
 *
 *      Rehearse (reports any regression, broadcasts nothing):
 *        forge script script/spend-module/v2/UpgradePriceProviderV2.s.sol --fork-url $FUSE_RPC_URL -vvv
 *
 *      With a multisig UPGRADER_ROLE holder, CALLDATA_ONLY=1 deploys the implementation and prints
 *      the `upgradeToAndCall` payload without switching.
 */
contract UpgradePriceProviderV2 is SpendModuleV2Config {
    function run() external {
        address proxy = requireV1Address("SolidPriceProvider");
        address v1Module = requireV1Address("SolidCashModule");
        requireHasCode(proxy, "price provider proxy");
        requireHasCode(v1Module, "v1 module");

        SolidPriceProviderV2 provider = SolidPriceProviderV2(proxy);
        ISolidCashModuleV1Read module = ISolidCashModuleV1Read(v1Module);

        // Snapshot what the LIVE module accepts today, so the comparison afterwards means something.
        address[] memory tokens = module.allowedTokens();
        uint256[] memory before = new uint256[](tokens.length);
        bool[] memory usableBefore = new bool[](tokens.length);

        console.log("Proxy:               ", proxy);
        console.log("Live v1 module:      ", v1Module);
        console.log("Allowlisted on v1:   ", tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (before[i], usableBefore[i]) = module.getPriceUsd(tokens[i]);
            console.log("  before:", tokens[i]);
            logUsd("    price", before[i]);
        }

        vm.startBroadcast();

        SolidPriceProviderV2 implementation = new SolidPriceProviderV2();
        console.log("\nNew implementation:", address(implementation));

        if (vm.envOr("CALLDATA_ONLY", false)) {
            vm.stopBroadcast();
            console.log("\nCALLDATA_ONLY - submit from the UPGRADER_ROLE holder:");
            console.log("  to:  ", proxy);
            console.logBytes(abi.encodeCall(IUUPS.upgradeToAndCall, (address(implementation), "")));
            saveAddress("SolidPriceProviderV2Implementation", address(implementation));
            return;
        }

        require(
            provider.hasRole(provider.UPGRADER_ROLE(), msg.sender),
            "signer lacks UPGRADER_ROLE - rerun with CALLDATA_ONLY=1"
        );

        IUUPS(proxy).upgradeToAndCall(address(implementation), "");
        console.log("Upgraded.");

        vm.stopBroadcast();

        saveAddress("SolidPriceProviderV2Implementation", address(implementation));

        _requireNoRegression(module, tokens, before, usableBefore);

        console.log("\nStep A complete. Next: DeploySpendModuleV2.s.sol (step C). There is no step B.");
    }

    /**
     * @dev Read back through the v1 MODULE, not the provider: the module applies its own band and its
     *      own staleness bound on top, and it is the module's answer that decides whether a card
     *      works. A provider that reports a fine price the module then rejects is still an outage.
     */
    function _requireNoRegression(
        ISolidCashModuleV1Read module,
        address[] memory tokens,
        uint256[] memory before,
        bool[] memory usableBefore
    ) private view {
        console.log("\nPost-upgrade, through the LIVE v1 module (its own band applied):");
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
            if (!usableBefore[i] || priceAfter == before[i]) continue;

            uint256 delta = priceAfter > before[i] ? priceAfter - before[i] : before[i] - priceAfter;
            uint256 deltaBps = (delta * MAX_BPS) / before[i];
            console.log("    changed by (bps):", deltaBps);

            // A yield-bearing share's rate moves between blocks, so a small change is expected.
            if (deltaBps > 100) {
                console.log("  ERROR: moved more than 1% across the upgrade");
                regressed = true;
            }
        }

        require(!regressed, "post-upgrade price regression - roll the implementation back");
        console.log("\nv1 cohort unaffected, prices unchanged within tolerance.");
    }
}
