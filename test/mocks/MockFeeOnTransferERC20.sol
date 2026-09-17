// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";

/**
 * @notice An ERC-20 that delivers less than it was asked to, and says it worked.
 *
 * A fee-on-transfer token is the ordinary version of this; a rebasing or
 * deflationary one behaves the same way from the recipient's side. The return
 * value is `true` either way, which is precisely why a return value cannot
 * stand in for an amount.
 */
contract MockFeeOnTransferERC20 is ERC20 {
    /// @notice Basis points withheld on every transfer.
    uint256 public immutable feeBps;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _feeBps)
        ERC20(_name, _symbol, _decimals)
    {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
            totalSupply -= fee;
        }
        emit Transfer(msg.sender, to, amount - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
            totalSupply -= fee;
        }
        emit Transfer(from, to, amount - fee);
        return true;
    }
}
