// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {SolidCCTPDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Solid/SolidCCTPDecoderAndSanitizer.sol";
import {CCTPDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/Protocols/CCTPDecoderAndSanitizer.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Test} from "@forge-std/Test.sol";

contract MockUSDC is ERC20("USDC", "USDC", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Pulls and records the burn; the real TokenMessengerV2 burns it and emits the CCTP message.
contract MockTokenMessengerV2 {
    uint256 public calls;
    uint256 public lastAmount;
    bytes32 public lastMintRecipient;

    function depositForBurn(uint256 amount, uint32, bytes32 mintRecipient, address burnToken, bytes32, uint256, uint32)
        external
    {
        calls++;
        lastAmount = amount;
        lastMintRecipient = mintRecipient;
        ERC20(burnToken).transferFrom(msg.sender, address(this), amount);
    }
}

contract SolidCCTPDecoderTest is Test {
    uint32 internal constant ETHEREUM_DOMAIN = 0;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant FINALITY_STANDARD = 2000;

    address internal constant BASE_VAULT = 0x3c0c8f95D7f4265B2dc5575eBc37a6945c7a7A31;
    address internal constant MAINNET_VAULT = 0x6E575AE5e1A12e910641183F555Fad62eD1481F2;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 7;

    SolidCCTPDecoderAndSanitizer internal decoder;

    function setUp() external {
        decoder = new SolidCCTPDecoderAndSanitizer();
    }

    // =============================== SELECTOR ===============================

    function testSelector() external pure {
        assertEq(CCTPDecoderAndSanitizer.depositForBurn.selector, bytes4(0x8e0250ee));
        assertEq(
            bytes4(keccak256("depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)")),
            bytes4(0x8e0250ee)
        );
    }

    // =============================== ADDRESSES FOUND ===============================

    function testAddressesFoundBaseToMainnet() external view {
        bytes memory found = decoder.depositForBurn(
            100e6, ETHEREUM_DOMAIN, _bytes32(MAINNET_VAULT), BASE_USDC, bytes32(0), 0, FINALITY_STANDARD
        );

        bytes memory expected = bytes.concat(
            hex"0000000000000000000000000000000000000000", // destinationDomain 0 (Ethereum)
            hex"6e575ae5e1a12e910641183f555fad62ed1481f2", // mintRecipient
            hex"833589fcd6edb6e08f4c7c32d4f71b54bda02913", // burnToken
            hex"0000000000000000000000000000000000000000" // destinationCaller (anyone)
        );
        assertEq(found.length, 80);
        assertEq(found, expected);
    }

    function testAddressesFoundMainnetToBase() external view {
        address mainnetUsdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        bytes memory found =
            decoder.depositForBurn(1, BASE_DOMAIN, _bytes32(BASE_VAULT), mainnetUsdc, bytes32(0), 5, 1000);

        bytes memory expected = bytes.concat(
            hex"0000000000000000000000000000000000000006", // destinationDomain 6 (Base)
            hex"3c0c8f95d7f4265b2dc5575ebc37a6945c7a7a31",
            hex"a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            hex"0000000000000000000000000000000000000000"
        );
        assertEq(found, expected);
    }

    // =============================== REVERTS ===============================

    function testRevertsOnMintRecipientUpperBits() external {
        vm.expectRevert(SolidCCTPDecoderAndSanitizer.SolidCCTPDecoderAndSanitizer__MintRecipientNotEvm.selector);
        decoder.depositForBurn(
            100e6,
            ETHEREUM_DOMAIN,
            bytes32(uint256(1) << 160) | _bytes32(MAINNET_VAULT),
            BASE_USDC,
            bytes32(0),
            0,
            FINALITY_STANDARD
        );
    }

    function testRevertsOnDestinationCallerUpperBits() external {
        vm.expectRevert(SolidCCTPDecoderAndSanitizer.SolidCCTPDecoderAndSanitizer__DestinationCallerNotEvm.selector);
        decoder.depositForBurn(
            100e6,
            ETHEREUM_DOMAIN,
            _bytes32(MAINNET_VAULT),
            BASE_USDC,
            bytes32(uint256(1) << 160),
            0,
            FINALITY_STANDARD
        );
    }

    // =============================== THROUGH THE MANAGER ===============================

    BoringVault internal vault;
    ManagerWithMerkleVerification internal manager;
    MockUSDC internal usdc;
    MockTokenMessengerV2 internal messenger;
    bytes32 internal approveLeaf;
    bytes32 internal burnLeaf;

    /// @dev Builds the two leaves the backend builds (approve the TokenMessengerV2, depositForBurn to the
    ///      mainnet vault) and runs them through ManagerWithMerkleVerification against a mock messenger.
    function testManagerApproveAndBurn() external {
        _setUpManager();

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = burnLeaf;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = approveLeaf;
        address[] memory decoders = new address[](2);
        decoders[0] = address(decoder);
        decoders[1] = address(decoder);
        address[] memory targets = new address[](2);
        targets[0] = address(usdc);
        targets[1] = address(messenger);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(messenger), 100e6);
        data[1] = _burnData(MAINNET_VAULT);
        uint256[] memory values = new uint256[](2);

        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);

        assertEq(messenger.calls(), 1);
        assertEq(messenger.lastAmount(), 100e6);
        assertEq(messenger.lastMintRecipient(), _bytes32(MAINNET_VAULT));
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @dev Any other recipient produces a different leaf and is rejected.
    function testManagerRejectsOtherRecipient() external {
        _setUpManager();

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = approveLeaf;
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = address(messenger);
        bytes[] memory data = new bytes[](1);
        data[0] = _burnData(address(this));
        uint256[] memory values = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                address(messenger),
                data[0],
                0
            )
        );
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    function _setUpManager() internal {
        vault = new BoringVault(address(this), "Solid USD", "soUSD", 6);
        manager = new ManagerWithMerkleVerification(address(this), address(vault), address(0));
        RolesAuthority authority = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(authority);
        manager.setAuthority(authority);

        authority.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );
        authority.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address[],bytes[],uint256[])")), true
        );
        authority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        authority.setUserRole(address(manager), MANAGER_ROLE, true);
        authority.setUserRole(address(this), STRATEGIST_ROLE, true);

        usdc = new MockUSDC();
        messenger = new MockTokenMessengerV2();
        usdc.mint(address(vault), 100e6);

        approveLeaf = keccak256(
            abi.encodePacked(address(decoder), address(usdc), false, ERC20.approve.selector, address(messenger))
        );
        burnLeaf = keccak256(
            abi.encodePacked(
                address(decoder),
                address(messenger),
                false,
                bytes4(0x8e0250ee),
                address(uint160(ETHEREUM_DOMAIN)),
                MAINNET_VAULT,
                address(usdc),
                address(0)
            )
        );
        manager.setManageRoot(address(this), _hashPair(approveLeaf, burnLeaf));
    }

    function _burnData(address recipient) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(0x8e0250ee),
            100e6,
            ETHEREUM_DOMAIN,
            _bytes32(recipient),
            address(usdc),
            bytes32(0),
            0,
            FINALITY_STANDARD
        );
    }

    function _bytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
