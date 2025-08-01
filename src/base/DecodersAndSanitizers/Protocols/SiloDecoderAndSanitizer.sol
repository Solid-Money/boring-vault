// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";
import {ERC4626DecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";

contract SiloDecoderAndSanitizer is ERC4626DecoderAndSanitizer {
    //in addition to ERC4626 functions for depositing, these functions can be used
    function deposit(uint256, /*_assets*/ address _receiver, DecoderCustomTypes.CollateralType /*_collateralType*/ )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_receiver);
    }

    function mint(uint256, /*_shares*/ address _receiver, DecoderCustomTypes.CollateralType /*_collateralType*/ )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_receiver);
    }

    function withdraw(
        uint256, /*_assets*/
        address _receiver,
        address _owner,
        DecoderCustomTypes.CollateralType /*_collateralType*/
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_receiver, _owner);
    }

    function redeem(
        uint256, /*_shares*/
        address _receiver,
        address _owner,
        DecoderCustomTypes.CollateralType /*_collateralType*/
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_receiver, _owner);
    }

    function borrow(uint256, /*_assets*/ address _receiver, address _borrower)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_receiver, _borrower);
    }

    function borrowShares(uint256, /*_shares*/ address _receiver, address _borrower)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_receiver, _borrower);
    }

    function borrowSameAsset(uint256, /*_assets*/ address _receiver, address _borrower)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_receiver, _borrower);
    }

    function repay(uint256, /*_assets*/ address _borrower)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_borrower);
    }

    function repayShares(uint256, /*_shares*/ address _borrower)
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_borrower);
    }

    function transitionCollateral(
        uint256, /*_shares*/
        address _owner,
        DecoderCustomTypes.CollateralType /*_transitionFrom*/
    ) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_owner);
    }

    function switchCollateralToThisSilo() external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }

    function accrueInterest() external pure virtual returns (bytes memory addressesFound) {
        return addressesFound;
    }

    // Silo Incentives

    function claimRewards(address _to) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_to);
    }

    function claimRewards(address _to, string[] memory /*programNames*/ )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_to);
    }

    // Silo Vault
    function claimRewards() external pure virtual returns (bytes memory addressesFound) {
        //nothing to sanitize
        return addressesFound;
    }
}
