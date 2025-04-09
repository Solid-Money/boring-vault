import {Authority} from "@solmate/auth/Auth.sol";

interface IBoringVault {
    function setAuthority(address) external;
}

interface ISimpleAuthority is Authority {
    function setPermission(
        address user,
        address target,
        bytes4 funcSig,
        bool allowed
    ) external;
}

contract SimpleAuthority is Authority {
    mapping(address => mapping(address => mapping(bytes4 => bool)))
        public permissions;

    function canCall(
        address user,
        address target,
        bytes4 functionSig
    ) external view override returns (bool) {
        return permissions[user][target][functionSig];
    }

    function setPermission(
        address user,
        address target,
        bytes4 functionSig,
        bool allowed
    ) external {
        // you can add an owner check here if desired
        permissions[user][target][functionSig] = allowed;
    }
}
