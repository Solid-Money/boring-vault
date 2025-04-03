// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "@forge-std/Test.sol";

/**

    TEST:
        source .env && forge script script/POC/DeployEthereumInfrastructure.s.sol:DeployEthereumInfrastructure

    DEPLOY:
        source .env && forge script script/POC/DeployEthereumInfrastructure.s.sol:DeployEthereumInfrastructure --broadcast --rpc-url mainnet

 */
contract DeployEthereumInfrastructure is Script {
    // Define role identifiers (matching BoringVault architecture roles)
    uint8 constant MANAGER_ROLE = 0;
    uint8 constant STRATEGIST_ROLE = 1;
    uint8 constant MINTER_ROLE = 2;
    uint8 constant BURNER_ROLE = 3;

    // Known Balancer Vault address on Ethereum (for flash loans in Manager)
    address constant BALANCER_VAULT =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    function run() external {
        // Load configuration from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address strategistAddr = 0x70D1c611788aFF8228b5d845A5Dc95927022cF7c; // EOA
        string memory vaultName = "fWETH";
        string memory vaultSymbol = "fWETH";

        // Note: The underlying asset for the vault (e.g., WETH on Ethereum)
        // is implicit in how the vault is managed (via Manager calls and Teller enters).
        // The vault itself doesn't store a specific asset address; it accepts any asset via `enter`.

        // Start broadcasting transactions to Ethereum network
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the BoringVault for fWETH (shares representing WETH deposits)
        // Using 18 decimals for shares (same as WETH)
        BoringVault vault = new BoringVault(
            deployer,
            vaultName,
            vaultSymbol,
            18
        );

        // Deploy the Manager with Merkle Verification for this vault
        ManagerWithMerkleVerification manager = new ManagerWithMerkleVerification(
                deployer,
                address(vault),
                BALANCER_VAULT
            );

        // Deploy a RolesAuthority to manage roles on the vault (and manager)
        RolesAuthority auth = new RolesAuthority(
            deployer,
            RolesAuthority(address(0))
        );
        auth.setAuthority(auth);
        auth.setUserRole(deployer, 0, true); // Give yourself a role with permissions

        // Set role capabilities on the vault:
        // - MANAGER_ROLE can call both variants of vault.manage(...)
        bytes4 vaultManageSingle = bytes4(
            keccak256("manage(address,bytes,uint256)")
        );
        bytes4 vaultManageBatch = bytes4(
            keccak256("manage(address[],bytes[],uint256[])")
        );
        auth.setRoleCapability(
            MANAGER_ROLE,
            address(vault),
            vaultManageSingle,
            true
        );
        auth.setRoleCapability(
            MANAGER_ROLE,
            address(vault),
            vaultManageBatch,
            true
        );
        // - MINTER_ROLE can call vault.enter(...)
        auth.setRoleCapability(
            MINTER_ROLE,
            address(vault),
            vault.enter.selector,
            true
        );
        // - BURNER_ROLE can call vault.exit(...)
        auth.setRoleCapability(
            BURNER_ROLE,
            address(vault),
            vault.exit.selector,
            true
        );

        // Set role capabilities on the manager:
        // - STRATEGIST_ROLE can call manager.manageVaultWithMerkleVerification(...)
        bytes4 manageVaultSig = bytes4(
            keccak256(
                "manageVaultWithMerkleVerification(bytes32[][],address[],address[],bytes[],uint256[])"
            )
        );
        auth.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            manageVaultSig,
            true
        );

        // Assign roles to the appropriate addresses:
        // Grant the Manager contract permission to manage the vault
        auth.setUserRole(address(manager), MANAGER_ROLE, true);
        // Grant the strategist address permission to call manageVault on the manager
        auth.setUserRole(strategistAddr, STRATEGIST_ROLE, true);
        // (The MINTER_ROLE and BURNER_ROLE will be assigned to the Teller contract later, in the Fuse deployment script)

        // Apply the RolesAuthority to the vault and manager for access control
        vault.setAuthority(auth);
        manager.setAuthority(auth);

        vm.stopBroadcast();

        // Log deployed addresses for reference
        console.log("BoringVault deployed at:", address(vault));
        console.log(
            "ManagerWithMerkleVerification deployed at:",
            address(manager)
        );
        console.log("RolesAuthority deployed at:", address(auth));
    }
}
