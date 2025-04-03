// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {AccountantWithRateProviders} from "src/base/Roles/AccountantWithRateProviders.sol";
import {TellerWithMultiAssetSupport} from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "@forge-std/Test.sol";

/**

    // CANNOT DEPLOY ON FUSE BECAUSE RPC DOES NOT SUPPORT EIP-4399, CHECK CODE BEFORE DEPLOYING. SCRIPT USED TO DEPLOYED WAS scripts/deploy-fuse-infrastructure.js

    TEST:
        source .env && forge script script/POC/DeployFuseInfrastructure.s.sol:DeployFuseInfrastructure --fork-url fuse

    DEPLOY:
        source .env && forge script script/POC/DeployFuseInfrastructure.s.sol:DeployFuseInfrastructure --skip-simulation --broadcast --verifier blockscout --verifier-url https://explorer.fuse.io/api --rpc-url fuse

 */
contract DeployFuseInfrastructure is Script {
    // Role identifiers (must match those used in the Ethereum vault's RolesAuthority)
    uint8 constant MINTER_ROLE = 2;
    uint8 constant BURNER_ROLE = 3;

    function run() external {
        // Load configuration from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address ethereumVaultAddr = 0x242d74d15eF015D2138a23ab67b6a1278A6B535A; // Deployed Ethereum BoringVault address

        address strategistAddr = 0x70D1c611788aFF8228b5d845A5Dc95927022cF7c; // EOA
        address fuseWETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590; // Fuse WETH token address

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the Accountant on Fuse, linked to the Ethereum vault
        // We use the WETH on Fuse as the base asset for rate calculations (pegged 1:1 with vault underlying WETH).
        // Configure initial parameters for the Accountant:
        address payoutAddress = strategistAddr; // Strategist will receive any fees (for demonstration)
        uint96 startingExchangeRate = 1e18; // Start with 1.0 (1 share = 1 WETH initially, scaled by 1e18)
        address baseAsset = fuseWETH; // Base asset for exchange rate (using WETH itself as base)
        uint16 allowedChangeUpper = 1000; // 10% upper bound change per update (basis points)
        uint16 allowedChangeLower = 1000; // 10% lower bound change
        uint24 minimumUpdateDelay = 86400; // 24 hours minimum between exchange rate updates
        uint16 managementFee = 0; // 0% management fee (for simplicity)
        uint16 performanceFee = 0; // 0% performance fee

        AccountantWithRateProviders accountant = new AccountantWithRateProviders(
                deployer,
                ethereumVaultAddr,
                payoutAddress,
                startingExchangeRate,
                baseAsset,
                allowedChangeUpper,
                allowedChangeLower,
                minimumUpdateDelay,
                managementFee,
                performanceFee
            );

        // Deploy the Teller with Multi-Asset Support on Fuse, linking it to the Ethereum vault and the Accountant
        TellerWithMultiAssetSupport teller = new TellerWithMultiAssetSupport(
            deployer,
            ethereumVaultAddr,
            address(accountant),
            fuseWETH
        );

        // Configure the Accountant with the rate provider data for the Fuse WETH asset.
        // Since Fuse WETH is pegged to the base (it *is* the base in this case), mark it as pegged.
        accountant.setRateProviderData(ERC20(fuseWETH), true, address(0));
        // (If there were additional supported assets, we'd set their rate providers similarly.)

        vm.stopBroadcast();

        // **Grant Teller roles on Ethereum vault**:
        // To allow the Fuse Teller to mint and burn shares on the Ethereum vault,
        // grant it MINTER_ROLE and BURNER_ROLE in the vault's RolesAuthority.
        // This step must be executed on Ethereum Mainnet.
        //
        // Below is the call that should be made on Ethereum:
        /*
        RolesAuthority vaultAuth = RolesAuthority(BoringVault(ethereumVaultAddr).authority());
        vm.startBroadcast(deployerPrivateKey);
        vaultAuth.setUserRole(address(teller), MINTER_ROLE, true);
        vaultAuth.setUserRole(address(teller), BURNER_ROLE, true);
        vm.stopBroadcast();
        */
        //
        // (Run the above on Ethereum to finalize access control for the Teller.)

        // Log deployed addresses for reference
        console.log(
            "AccountantWithRateProviders deployed at:",
            address(accountant)
        );
        console.log(
            "TellerWithMultiAssetSupport deployed at:",
            address(teller)
        );
    }
}
