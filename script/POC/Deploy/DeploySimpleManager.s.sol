// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {UniswapV3Helper} from "src/helpers/UniswapV3Helper.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Script, console} from "forge-std/Script.sol";
import {MerkleProofLib} from "@solmate/utils/MerkleProofLib.sol";

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {UniswapV3Helper} from "src/helpers/UniswapV3Helper.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Script, console} from "forge-std/Script.sol";
import {MerkleProofLib} from "@solmate/utils/MerkleProofLib.sol";

/**
 * @title SimpleManager Contract
 * @dev Manages the vault and supports Merkle proof verification with actions for token swaps and liquidity management.
 */
contract SimpleManager is ManagerWithMerkleVerification {
    using SafeTransferLib for ERC20;

    // Reference to UniswapV3Helper contract to manage liquidity and swaps
    UniswapV3Helper public uniswapHelper;
    address public USDC; // USDC token address for swapping

    constructor(
        address strategist,
        address vault,
        address balancerVault,
        address _uniswapHelper,
        address _USDC
    ) ManagerWithMerkleVerification(strategist, vault, balancerVault) {
        uniswapHelper = UniswapV3Helper(_uniswapHelper);
        USDC = _USDC;
    }

    /**
     * @notice Create a 50/50 liquidity position from only WETH.
     * @dev Since the vault only has WETH, we will swap half of it to USDC and then create the liquidity position.
     * @param amountWETH The total amount of WETH available for creating the liquidity position.
     * @param fee The pool fee for Uniswap V3 (e.g., 3000 for the 0.3% pool).
     * @param tickLower The lower tick for the liquidity range.
     * @param tickUpper The upper tick for the liquidity range.
     * @param deadline The deadline for the transaction.
     */
    function create50_50LiquidityPositionFromWETH(
        uint256 amountWETH,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 deadline
    ) external requiresAuth {
        // Swap half of WETH to USDC to create a 50/50 position
        uint256 halfWETH = amountWETH / 2;
        uint256 amountUSDC = uniswapHelper.swapWETHForUSDC(
            halfWETH,
            0,
            address(this)
        );

        // Create the 50/50 liquidity position on Uniswap V3
        uint256 tokenId = uniswapHelper.createLiquidityPosition(
            address(WETH),
            USDC,
            fee,
            tickLower,
            tickUpper,
            halfWETH,
            amountUSDC,
            0,
            0,
            address(this),
            deadline
        );

        console.log("Liquidity position created! TokenId:", tokenId);
    }

    /**
     * @notice Withdraw the entire liquidity from the position as WETH.
     * @dev If the position contains both WETH and USDC, the USDC will be swapped back to WETH.
     * @param tokenId The token ID of the liquidity position to withdraw from.
     * @param amount0Min Minimum amount of WETH to withdraw.
     * @param amount1Min Minimum amount of USDC to withdraw.
     */
    function withdrawLiquidityAsWETH(
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min
    ) external requiresAuth {
        // Collect the liquidity from the position
        (uint256 amountWETH, uint256 amountUSDC) = uniswapHelper
            .collectLiquidity(tokenId, amount0Min, amount1Min);

        // If the position has USDC, swap it back to WETH
        if (amountUSDC > 0) {
            uniswapHelper.swapUSDCForWETH(amountUSDC, 0, address(this));
        }

        // Transfer all WETH to the caller (or vault, depending on your requirement)
        ERC20(WETH).safeTransfer(msg.sender, amountWETH);

        console.log("Withdrawal successful! Amount WETH:", amountWETH);
    }
}
/*
    source .env && forge script script/POC/Deploy/DeploySimpleManager.s.sol:DeploySimpleManager --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
*/
contract DeploySimpleManager is Script {
    function run() external {
        vm.startBroadcast();

        // Vault and strategist addresses, you will need to set them in your .env
        address vault = vm.envAddress("VAULT");
        address strategist = vm.envAddress("DEPLOYER");
        address balancerVault = address(0); // Set the appropriate BalancerVault address
        address uniswapHelper = vm.envAddress("UNISWAP_HELPER"); // Set the Uniswap helper contract address

        // Merkle root
        bytes32 root = 0x385c70e91efd653df05dc62fc03efe5d5ad405f18eaa832c7b7493ce5d884958;

        // Deploy the manager contract
        SimpleManager manager = new SimpleManager(
            strategist,
            vault,
            balancerVault,
            uniswapHelper
        );
        console.log("Manager deployed at:", address(manager));

        // Set the Merkle root for the strategist
        manager.setManageRoot(strategist, root);
        console.log("Merkle root set for strategist");

        vm.stopBroadcast();
    }
}
