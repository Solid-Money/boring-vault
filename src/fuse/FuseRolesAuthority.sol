// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {Authority} from "@solmate/auth/Auth.sol";

contract FuseRolesAuthority is RolesAuthority {
    constructor(
        address _owner,
        Authority _authority
    ) RolesAuthority(_owner, _authority) {}
}
