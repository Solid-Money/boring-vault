// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {ChainlinkQuoteAdapter} from "src/spend-module/v2/adapters/ChainlinkQuoteAdapter.sol";

import {SpendModuleV2BaseConfig} from "./SpendModuleV2BaseConfig.sol";

/**
 * @title DeployChainlinkAdapterBase
 * @notice **Base step 1.** Deploys the price adapter and configures EURC's quote.
 *
 * @dev First, because everything else depends on it. The provider cannot configure EURC without an
 *      adapter that already answers, and the module cannot allowlist a token the provider cannot
 *      price.
 *
 *      **Owned by the multisig from construction, not handed over afterwards.** Repointing a token's
 *      feeds is equivalent to setting its price, so there must be no window in which a deployer EOA
 *      holds that power over a contract other systems are about to trust. The adapter has no
 *      authority at all and `setAuthority` reverts, so ownership is the whole access model.
 *
 *      That means the deployer cannot call `setQuote`. This script therefore **deploys only** when
 *      the owner is a multisig, and prints the configuration calldata for it to execute. When the
 *      deployer *is* the owner, typically on a fork rehearsal, it configures inline.
 *
 *        forge script script/spend-module/v2/base/DeployChainlinkAdapterBase.s.sol \
 *          --rpc-url base --broadcast -vvv
 *
 *      Required environment: `EURC_ADDRESS`, `EURC_USD_FEED`, `SEQUENCER_UPTIME_FEED`.
 *      Optional: `SEQUENCER_GRACE_PERIOD`, `EURC_USD_MAX_STALENESS`, `OWNER`.
 */
contract DeployChainlinkAdapterBase is SpendModuleV2BaseConfig {
    function run() external {
        requireBaseChain();

        address deployer = msg.sender;
        address finalOwner = owner();

        console.log("\n=== Base step 1: ChainlinkQuoteAdapter ===");
        console.log("Deployer:             ", deployer);
        console.log("Owner:                ", finalOwner);
        logBaseInputs();

        // Asserted before deploying, because an adapter pointed at an address with no code would
        // deploy happily and fail only at the probe, after the gas is spent.
        requireHasCode(baseEurc(), "EURC");
        requireHasCode(baseEurcUsdFeed(), "EURC/USD feed");
        requireHasCode(baseSequencerUptimeFeed(), "sequencer uptime feed");

        vm.startBroadcast();

        ChainlinkQuoteAdapter adapter =
            new ChainlinkQuoteAdapter(finalOwner, baseSequencerUptimeFeed(), baseSequencerGracePeriod());
        console.log("\n  deployed:           ", address(adapter));

        if (finalOwner == deployer) {
            _configure(adapter);
        }

        vm.stopBroadcast();

        saveAddress("ChainlinkQuoteAdapter", address(adapter));

        if (finalOwner != deployer) _printConfigureCalldata(adapter);

        console.log("\n=== next ===");
        console.log("  2. Deploy the provider and configure EURC on it");
        console.log("     script/spend-module/v2/base/DeploySpendModuleV2Base.s.sol");
    }

    /**
     * @dev Configures and then reads back.
     *
     *      `setQuote` already probes before storing, so a configuration that cannot price its own
     *      token reverts here rather than surfacing later as a declined card transaction. This
     *      re-reads anyway, because the probe proves the feed answered once and this proves the
     *      stored entry is the one that answers.
     */
    function _configure(ChainlinkQuoteAdapter adapter) private {
        adapter.setQuote(
            baseEurc(),
            baseEurcUsdFeed(),
            baseEurcUsdMaxStaleness(),
            // No denominator. On a dollar instance EURC/USD is already the answer; dividing by
            // EUR/USD would produce EURC priced in euros, which is about 1.00 and would understate
            // it by the euro premium on every single spend.
            address(0),
            0
        );

        (uint256 price, bool usable,) = adapter.price(baseEurc());
        require(usable && price != 0, "adapter cannot price EURC after configuration");

        logUsd("  EURC price          ", price);

        // A sanity band far wider than the module's, catching a feed that answers in the wrong
        // decimals or the wrong pair rather than one that is merely off.
        require(price > 0.5e6 && price < 2e6, "EURC price is not plausibly a euro in dollars");
    }

    function _printConfigureCalldata(ChainlinkQuoteAdapter adapter) private view {
        console.log("\n=== OWNER multisig must run ===");
        console.log("  adapter:", address(adapter));
        console.log("  setQuote(EURC, EURC/USD, staleness, 0, 0)");
        console.logBytes(
            abi.encodeCall(
                ChainlinkQuoteAdapter.setQuote,
                (baseEurc(), baseEurcUsdFeed(), baseEurcUsdMaxStaleness(), address(0), 0)
            )
        );
        console.log("\n  Until this lands the adapter prices nothing and step 2 will refuse.");
    }
}
