// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {SolidCrossChainTokenDecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Solid/SolidCrossChainTokenDecoderAndSanitizer.sol";
import {CrossChainTokenServiceDecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Protocols/CrossChainTokenServiceDecoderAndSanitizer.sol";
import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Test} from "@forge-std/Test.sol";

contract MockEURC is ERC20("EURC", "EURC", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Records the call; the real service pulls the tokens through the token's TokenManager.
contract MockCrossChainTokenService {
    uint256 public calls;
    uint256 public lastValue;
    uint256 public lastAmount;
    bytes public lastDestinationAddress;

    function crossChainTransfer(
        bytes32,
        uint256 amount,
        uint32,
        bytes calldata destinationAddress,
        bytes32,
        uint32,
        DecoderCustomTypes.CrossChainTokenClaim calldata,
        bool,
        bytes calldata
    ) external payable {
        calls++;
        lastValue = msg.value;
        lastAmount = amount;
        lastDestinationAddress = destinationAddress;
    }
}

contract CrossChainTokenServiceDecoderTest is Test {
    bytes32 internal constant EURC_TOKEN_ID = 0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c;
    uint32 internal constant ETHEREUM_DOMAIN = 0;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant FINALITY_STANDARD = 2000;

    address internal constant BASE_VAULT = 0x4f4B212aF8B5020399dde325e1Bc5B33b53DB70B;
    address internal constant MAINNET_VAULT = 0x1111111111111111111111111111111111111111;
    address internal constant TOKEN_MANAGER = 0x8c27579e24F9f19D96724e19fC059dAcd1469e10;

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 7;

    SolidCrossChainTokenDecoderAndSanitizer internal decoder;

    function setUp() external {
        decoder = new SolidCrossChainTokenDecoderAndSanitizer();
    }

    function _claim(address refundAddress) internal pure returns (DecoderCustomTypes.CrossChainTokenClaim memory) {
        return DecoderCustomTypes.CrossChainTokenClaim({signedQuote: hex"c0ffee", refundAddress: refundAddress});
    }

    // =============================== SELECTOR ===============================

    function testSelector() external pure {
        assertEq(CrossChainTokenServiceDecoderAndSanitizer.crossChainTransfer.selector, bytes4(0x780c5acf));
        assertEq(
            bytes4(
                keccak256("crossChainTransfer(bytes32,uint256,uint32,bytes,bytes32,uint32,(bytes,address),bool,bytes)")
            ),
            bytes4(0x780c5acf)
        );
    }

    // =============================== ADDRESSES FOUND ===============================

    function testAddressesFoundBaseToMainnet() external view {
        bytes memory found = decoder.crossChainTransfer(
            EURC_TOKEN_ID,
            100e6,
            ETHEREUM_DOMAIN,
            abi.encodePacked(MAINNET_VAULT),
            bytes32(0),
            FINALITY_STANDARD,
            _claim(BASE_VAULT),
            false,
            ""
        );

        bytes memory expected = bytes.concat(
            hex"6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2", // tokenId bytes 0..19
            hex"90b9ca7a995ad4d2234880da13ca38c657fb241c", // tokenId bytes 12..31
            hex"0000000000000000000000000000000000000000", // destinationDomain 0 (Ethereum)
            hex"1111111111111111111111111111111111111111", // destinationAddress
            hex"0000000000000000000000000000000000000000", // destinationCaller (anyone)
            hex"4f4b212af8b5020399dde325e1bc5b33b53db70b" // refundAddress
        );
        assertEq(found.length, 120);
        assertEq(found, expected);
    }

    function testAddressesFoundMainnetToBase() external view {
        address destinationCaller = 0x2222222222222222222222222222222222222222;
        bytes memory found = decoder.crossChainTransfer(
            EURC_TOKEN_ID,
            1,
            BASE_DOMAIN,
            abi.encodePacked(BASE_VAULT),
            bytes32(uint256(uint160(destinationCaller))),
            1000,
            _claim(MAINNET_VAULT),
            false,
            ""
        );

        bytes memory expected = bytes.concat(
            hex"6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2",
            hex"90b9ca7a995ad4d2234880da13ca38c657fb241c",
            hex"0000000000000000000000000000000000000006", // destinationDomain 6 (Base)
            hex"4f4b212af8b5020399dde325e1bc5b33b53db70b",
            hex"2222222222222222222222222222222222222222",
            hex"1111111111111111111111111111111111111111"
        );
        assertEq(found, expected);
    }

    // =============================== REVERTS ===============================

    function testRevertsOnDestinationAddressNot20Bytes() external {
        bytes[3] memory badAddresses = [bytes(""), abi.encode(MAINNET_VAULT), abi.encodePacked(MAINNET_VAULT, uint8(0))];
        for (uint256 i; i < badAddresses.length; ++i) {
            vm.expectRevert(
                CrossChainTokenServiceDecoderAndSanitizer
                    .CrossChainTokenServiceDecoderAndSanitizer__DestinationAddressNotEvm
                    .selector
            );
            decoder.crossChainTransfer(
                EURC_TOKEN_ID,
                100e6,
                ETHEREUM_DOMAIN,
                badAddresses[i],
                bytes32(0),
                FINALITY_STANDARD,
                _claim(BASE_VAULT),
                false,
                ""
            );
        }
    }

    function testRevertsOnDestinationCallerUpperBits() external {
        vm.expectRevert(
            CrossChainTokenServiceDecoderAndSanitizer
                .CrossChainTokenServiceDecoderAndSanitizer__DestinationCallerNotEvm
                .selector
        );
        decoder.crossChainTransfer(
            EURC_TOKEN_ID,
            100e6,
            ETHEREUM_DOMAIN,
            abi.encodePacked(MAINNET_VAULT),
            bytes32(uint256(1) << 160),
            FINALITY_STANDARD,
            _claim(BASE_VAULT),
            false,
            ""
        );
    }

    function testRevertsOnAutoExecuteHook() external {
        vm.expectRevert(
            CrossChainTokenServiceDecoderAndSanitizer
                .CrossChainTokenServiceDecoderAndSanitizer__HooksNotSupported
                .selector
        );
        decoder.crossChainTransfer(
            EURC_TOKEN_ID,
            100e6,
            ETHEREUM_DOMAIN,
            abi.encodePacked(MAINNET_VAULT),
            bytes32(0),
            FINALITY_STANDARD,
            _claim(BASE_VAULT),
            true,
            ""
        );
    }

    function testRevertsOnHookData() external {
        vm.expectRevert(
            CrossChainTokenServiceDecoderAndSanitizer
                .CrossChainTokenServiceDecoderAndSanitizer__HooksNotSupported
                .selector
        );
        decoder.crossChainTransfer(
            EURC_TOKEN_ID,
            100e6,
            ETHEREUM_DOMAIN,
            abi.encodePacked(MAINNET_VAULT),
            bytes32(0),
            FINALITY_STANDARD,
            _claim(BASE_VAULT),
            false,
            hex"01"
        );
    }

    // =============================== THROUGH THE MANAGER ===============================

    uint256 internal constant FEE = 0.0008 ether;

    BoringVault internal vault;
    ManagerWithMerkleVerification internal manager;
    MockEURC internal eurc;
    MockCrossChainTokenService internal service;
    bytes32 internal approveLeaf;
    bytes32 internal transferLeaf;

    /// @dev Builds the two leaves the backend builds (approve the TokenManager, crossChainTransfer with a
    ///      fee) and runs them through ManagerWithMerkleVerification against a mock service.
    function testManagerApproveAndTransfer() external {
        _setUpManager();

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = transferLeaf;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = approveLeaf;
        address[] memory decoders = new address[](2);
        decoders[0] = address(decoder);
        decoders[1] = address(decoder);
        address[] memory targets = new address[](2);
        targets[0] = address(eurc);
        targets[1] = address(service);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, TOKEN_MANAGER, 100e6);
        data[1] = _transferData(abi.encodePacked(MAINNET_VAULT), address(vault));
        uint256[] memory values = new uint256[](2);
        values[1] = FEE;

        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);

        assertEq(eurc.allowance(address(vault), TOKEN_MANAGER), 100e6);
        assertEq(service.calls(), 1);
        assertEq(service.lastValue(), FEE);
        assertEq(service.lastAmount(), 100e6);
        assertEq(service.lastDestinationAddress(), abi.encodePacked(MAINNET_VAULT));
    }

    /// @dev Any other destination produces a different leaf and is rejected.
    function testManagerRejectsOtherDestination() external {
        _setUpManager();

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = approveLeaf;
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = address(service);
        bytes[] memory data = new bytes[](1);
        data[0] = _transferData(abi.encodePacked(address(this)), address(vault));
        uint256[] memory values = new uint256[](1);
        values[0] = FEE;

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                address(service),
                data[0],
                FEE
            )
        );
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    function _setUpManager() internal {
        vault = new BoringVault(address(this), "Solid EUR", "soEUR", 6);
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

        eurc = new MockEURC();
        service = new MockCrossChainTokenService();
        eurc.mint(address(vault), 100e6);
        vm.deal(address(vault), 1 ether);

        approveLeaf =
            keccak256(abi.encodePacked(address(decoder), address(eurc), false, ERC20.approve.selector, TOKEN_MANAGER));
        transferLeaf = keccak256(
            abi.encodePacked(
                address(decoder),
                address(service),
                true, // value is the CCTPx fee
                bytes4(0x780c5acf),
                address(bytes20(EURC_TOKEN_ID)),
                address(uint160(uint256(EURC_TOKEN_ID))),
                address(uint160(ETHEREUM_DOMAIN)),
                MAINNET_VAULT,
                address(0),
                address(vault)
            )
        );
        manager.setManageRoot(address(this), _hashPair(approveLeaf, transferLeaf));
    }

    function _transferData(bytes memory destinationAddress, address refundAddress)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            bytes4(0x780c5acf),
            EURC_TOKEN_ID,
            100e6,
            ETHEREUM_DOMAIN,
            destinationAddress,
            bytes32(0),
            FINALITY_STANDARD,
            _claim(refundAddress),
            false,
            bytes("")
        );
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
