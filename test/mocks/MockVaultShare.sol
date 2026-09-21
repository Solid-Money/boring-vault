// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

/**
 * @notice A BoringVault's two relevant halves: it is the share token, and it is
 *         the address a deposit asset is pulled by.
 *
 * That second part is the one a simpler mock would get wrong. The Teller does
 * not move the deposit asset itself — the vault does, inside `enter` — so the
 * approval a depositor has to grant goes to the vault, not to the Teller. A
 * zap that approved the Teller would compile, pass a test against a mock that
 * pulled from the Teller, and revert on chain.
 */
contract MockVaultShare is ERC20 {
    using SafeTransferLib for ERC20;

    constructor() ERC20("soFUSE", "soFUSE", 18) {}

    function enter(address from, ERC20 asset, uint256 assetAmount, address to, uint256 shareAmount) external {
        if (assetAmount > 0) asset.safeTransferFrom(from, address(this), assetAmount);
        _mint(to, shareAmount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
