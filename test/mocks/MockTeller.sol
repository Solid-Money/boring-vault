// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {MockVaultShare} from "test/mocks/MockVaultShare.sol";
import {MockWrappedNative} from "test/mocks/MockWrappedNative.sol";

/**
 * @notice `TellerWithMultiAssetSupport`, reduced to what a deposit does.
 *
 * Faithful in the three ways a zap depends on and would otherwise get wrong:
 *
 *  - shares are minted to `msg.sender`, which is why a Safe cannot name the
 *    lock as the recipient and why the zap has to exist at all;
 *  - the deposit asset is pulled by the **vault**, so that is the address a
 *    depositor approves;
 *  - a native deposit ignores the `depositAmount` argument entirely and uses
 *    `msg.value`.
 */
contract MockTeller {
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    MockVaultShare public immutable share;
    MockWrappedNative public immutable wrapped;

    /// @notice Assets per share, 18-decimal. Above par, like a share that has earned.
    uint256 public rate;

    error MockTeller__MinimumMintNotMet(uint256 shares, uint256 minimum);

    constructor(address _share, address _wrapped, uint256 _rate) {
        share = MockVaultShare(_share);
        wrapped = MockWrappedNative(payable(_wrapped));
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function vault() external view returns (address) {
        return address(share);
    }

    function nativeWrapper() external view returns (address) {
        return address(wrapped);
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        payable
        returns (uint256 shares)
    {
        if (address(depositAsset) == NATIVE) {
            depositAmount = msg.value;
            wrapped.deposit{value: depositAmount}();
            wrapped.approve(address(share), depositAmount);
            shares = (depositAmount * 1e18) / rate;
            share.enter(address(this), ERC20(address(wrapped)), depositAmount, msg.sender, shares);
        } else {
            shares = (depositAmount * 1e18) / rate;
            share.enter(msg.sender, depositAsset, depositAmount, msg.sender, shares);
        }

        if (shares < minimumMint) revert MockTeller__MinimumMintNotMet(shares, minimumMint);
    }
}
