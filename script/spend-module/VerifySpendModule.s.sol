// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashLens} from "src/spend-module/SolidCashLens.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";

import {SpendModuleVerifier} from "./SpendModuleVerifier.sol";

/**
 * @title VerifySpendModule
 * @notice Read-only verification of an already-deployed spend module. Reverts on any failure, so it
 *         can gate a release.
 * @dev Reads addresses from `deployments/addresses/<Network>/SpendModule.json`; individual addresses
 *      can be overridden by env var of the same name.
 *
 *        forge script script/spend-module/VerifySpendModule.s.sol --rpc-url fuse -vvv
 */
contract VerifySpendModule is SpendModuleVerifier {
    function run() external {
        SolidPriceProvider provider =
            SolidPriceProvider(requireAddress("SolidPriceProvider", "DeploySpendModule.s.sol"));
        FuseRolesAuthority authority =
            FuseRolesAuthority(requireAddress("FuseRolesAuthority", "DeploySpendModule.s.sol"));
        SolidCashModule module = SolidCashModule(requireAddress("SolidCashModule", "DeploySpendModule.s.sol"));
        SolidCashLens lens = SolidCashLens(requireAddress("SolidCashLens", "DeploySpendModule.s.sol"));

        verify(
            VerifyContext({
                provider: provider,
                authority: authority,
                module: module,
                lens: lens,
                treasury: module.settlementTreasury(),
                spender: spender(),
                guardian: guardian(),
                finalOwner: owner(),
                priceAdmin: priceAdmin()
            })
        );
    }
}
