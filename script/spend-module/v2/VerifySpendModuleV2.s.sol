// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidSpendLens} from "src/spend-module/v2/SolidSpendLens.sol";
import {SolidPriceProviderV2} from "src/spend-module/v2/SolidPriceProviderV2.sol";

import {SpendModuleV2Verifier} from "./SpendModuleV2Verifier.sol";

/**
 * @title VerifySpendModuleV2
 * @notice Step F: assert the whole deployment, against whatever is live right now.
 * @dev The same checks the deploy script runs inline, plus the role table — which a fresh deploy
 *      usually cannot assert, because the authority is v1's and already owned by the multisig, so
 *      granting v2's capabilities is a separate multisig action. This is the run that proves it
 *      landed.
 *
 *      Reverts on the first failure. Read-only, so it is safe to run against production at any time
 *      and worth running after any configuration change.
 *
 *        SPENDER=0x.. GUARDIAN=0x.. \
 *          forge script script/spend-module/v2/VerifySpendModuleV2.s.sol --rpc-url fuse -vvv
 *
 *      `SKIP_ROLE_CHECKS=true` reports the role table as outstanding instead of asserting it, for the
 *      window between step C and step D.
 */
contract VerifySpendModuleV2 is SpendModuleV2Verifier {
    function run() external view {
        verify(
            VerifyContext({
                provider: SolidPriceProviderV2(requireV1Address("SolidPriceProvider")),
                authority: RolesAuthority(requireV1Address("FuseRolesAuthority")),
                core: SolidCashModuleV2(requireAddress("SolidCashModuleV2", "DeploySpendModuleV2.s.sol")),
                setters: requireAddress("SolidCashModuleV2Setters", "DeploySpendModuleV2.s.sol"),
                lens: SolidSpendLens(requireAddress("SolidSpendLens", "DeploySpendModuleV2.s.sol")),
                v1Module: requireV1Address("SolidCashModule"),
                treasury: settlementTreasury(),
                spender: spender(),
                creditSpender: creditSpender(),
                guardian: guardian(),
                liquidator: requireAddress("SolidLiquidator", "DeploySpendModuleV2.s.sol"),
                liquidationOperator: liquidationOperator(),
                finalOwner: owner()
            }),
            !vm.envOr("SKIP_ROLE_CHECKS", false)
        );
    }
}
