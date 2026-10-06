
// File: lib/solmate/src/tokens/ERC20.sol


pragma solidity >=0.8.0;

/// @notice Modern and gas efficient ERC20 + EIP-2612 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC20.sol)
/// @author Modified from Uniswap (https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/UniswapV2ERC20.sol)
/// @dev Do not manually set balances without updating totalSupply, as the sum of all user balances must not exceed it.
abstract contract ERC20 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;

    string public symbol;

    uint8 public immutable decimals;

    /*//////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                               ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 amount) internal virtual {
        totalSupply += amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        balanceOf[from] -= amount;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}

// File: lib/solmate/src/utils/SafeTransferLib.sol


pragma solidity >=0.8.0;


/// @notice Safe ETH and ERC20 transfer library that gracefully handles missing return values.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/SafeTransferLib.sol)
/// @dev Use with caution! Some functions in this library knowingly create dirty bits at the destination of the free memory pointer.
/// @dev Note that none of the functions in this library check that a token has code at all! That responsibility is delegated to the caller.
library SafeTransferLib {
    /*//////////////////////////////////////////////////////////////
                             ETH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function safeTransferFrom(
        ERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "from" argument.
            mstore(add(freeMemoryPointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
            )
        }

        require(success, "TRANSFER_FROM_FAILED");
    }

    function safeTransfer(
        ERC20 token,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "TRANSFER_FAILED");
    }

    function safeApprove(
        ERC20 token,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "APPROVE_FAILED");
    }
}

// File: lib/solmate/src/tokens/WETH.sol


pragma solidity >=0.8.0;



/// @notice Minimalist and modern Wrapped Ether implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/WETH.sol)
/// @author Inspired by WETH9 (https://github.com/dapphub/ds-weth/blob/master/src/weth9.sol)
contract WETH is ERC20("Wrapped Ether", "WETH", 18) {
    using SafeTransferLib for address;

    event Deposit(address indexed from, uint256 amount);

    event Withdrawal(address indexed to, uint256 amount);

    function deposit() public payable virtual {
        _mint(msg.sender, msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public virtual {
        _burn(msg.sender, amount);

        emit Withdrawal(msg.sender, amount);

        msg.sender.safeTransferETH(amount);
    }

    receive() external payable virtual {
        deposit();
    }
}

// File: lib/openzeppelin-contracts/contracts/utils/Address.sol


// OpenZeppelin Contracts (last updated v5.0.0) (utils/Address.sol)

pragma solidity ^0.8.20;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error AddressInsufficientBalance(address account);

    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedInnerCall();

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert AddressInsufficientBalance(address(this));
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert FailedInnerCall();
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {FailedInnerCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert AddressInsufficientBalance(address(this));
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {FailedInnerCall}) in case of an
     * unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {FailedInnerCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {FailedInnerCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert FailedInnerCall();
        }
    }
}

// File: lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC721/IERC721Receiver.sol)

pragma solidity ^0.8.20;

/**
 * @title ERC721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be
     * reverted.
     *
     * The selector can be obtained in Solidity with `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

// File: lib/openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC721/utils/ERC721Holder.sol)

pragma solidity ^0.8.20;


/**
 * @dev Implementation of the {IERC721Receiver} interface.
 *
 * Accepts all token transfers.
 * Make sure the contract is able to use its token with {IERC721-safeTransferFrom}, {IERC721-approve} or
 * {IERC721-setApprovalForAll}.
 */
abstract contract ERC721Holder is IERC721Receiver {
    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     *
     * Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// File: lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol


// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/IERC165.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// File: lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol


// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/ERC165.sol)

pragma solidity ^0.8.20;


/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// File: lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC1155/IERC1155Receiver.sol)

pragma solidity ^0.8.20;


/**
 * @dev Interface that must be implemented by smart contracts in order to receive
 * ERC-1155 token transfers.
 */
interface IERC1155Receiver is IERC165 {
    /**
     * @dev Handles the receipt of a single ERC1155 token type. This function is
     * called at the end of a `safeTransferFrom` after the balance has been updated.
     *
     * NOTE: To accept the transfer, this must return
     * `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))`
     * (i.e. 0xf23a6e61, or its own function selector).
     *
     * @param operator The address which initiated the transfer (i.e. msg.sender)
     * @param from The address which previously owned the token
     * @param id The ID of the token being transferred
     * @param value The amount of tokens being transferred
     * @param data Additional data with no specified format
     * @return `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))` if transfer is allowed
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);

    /**
     * @dev Handles the receipt of a multiple ERC1155 token types. This function
     * is called at the end of a `safeBatchTransferFrom` after the balances have
     * been updated.
     *
     * NOTE: To accept the transfer(s), this must return
     * `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))`
     * (i.e. 0xbc197c81, or its own function selector).
     *
     * @param operator The address which initiated the batch transfer (i.e. msg.sender)
     * @param from The address which previously owned the token
     * @param ids An array containing ids of each token being transferred (order and length must match values array)
     * @param values An array containing amounts of each token being transferred (order and length must match ids array)
     * @param data Additional data with no specified format
     * @return `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))` if transfer is allowed
     */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}

// File: lib/openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC1155/utils/ERC1155Holder.sol)

pragma solidity ^0.8.20;



/**
 * @dev Simple implementation of `IERC1155Receiver` that will allow a contract to hold ERC1155 tokens.
 *
 * IMPORTANT: When inheriting this contract, you must include a way to use the received tokens, otherwise they will be
 * stuck.
 */
abstract contract ERC1155Holder is ERC165, IERC1155Receiver {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

// File: lib/solmate/src/utils/FixedPointMathLib.sol


pragma solidity >=0.8.0;

/// @notice Arithmetic library with operations for fixed-point numbers.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/FixedPointMathLib.sol)
/// @author Inspired by USM (https://github.com/usmfum/USM/blob/master/contracts/WadMath.sol)
library FixedPointMathLib {
    /*//////////////////////////////////////////////////////////////
                    SIMPLIFIED FIXED POINT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_UINT256 = 2**256 - 1;

    uint256 internal constant WAD = 1e18; // The scalar of ETH and most ERC20s.

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD); // Equivalent to (x * y) / WAD rounded down.
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD); // Equivalent to (x * y) / WAD rounded up.
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y); // Equivalent to (x * WAD) / y rounded down.
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y); // Equivalent to (x * WAD) / y rounded up.
    }

    /*//////////////////////////////////////////////////////////////
                    LOW LEVEL FIXED POINT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // Divide x * y by the denominator.
            z := div(mul(x, y), denominator)
        }
    }

    function mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // If x * y modulo the denominator is strictly greater than 0,
            // 1 is added to round up the division of x * y by the denominator.
            z := add(gt(mod(mul(x, y), denominator), 0), div(mul(x, y), denominator))
        }
    }

    function rpow(
        uint256 x,
        uint256 n,
        uint256 scalar
    ) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            switch x
            case 0 {
                switch n
                case 0 {
                    // 0 ** 0 = 1
                    z := scalar
                }
                default {
                    // 0 ** n = 0
                    z := 0
                }
            }
            default {
                switch mod(n, 2)
                case 0 {
                    // If n is even, store scalar in z for now.
                    z := scalar
                }
                default {
                    // If n is odd, store x in z for now.
                    z := x
                }

                // Shifting right by 1 is like dividing by 2.
                let half := shr(1, scalar)

                for {
                    // Shift n right by 1 before looping to halve it.
                    n := shr(1, n)
                } n {
                    // Shift n right by 1 each iteration to halve it.
                    n := shr(1, n)
                } {
                    // Revert immediately if x ** 2 would overflow.
                    // Equivalent to iszero(eq(div(xx, x), x)) here.
                    if shr(128, x) {
                        revert(0, 0)
                    }

                    // Store x squared.
                    let xx := mul(x, x)

                    // Round to the nearest number.
                    let xxRound := add(xx, half)

                    // Revert if xx + half overflowed.
                    if lt(xxRound, xx) {
                        revert(0, 0)
                    }

                    // Set x to scaled xxRound.
                    x := div(xxRound, scalar)

                    // If n is even:
                    if mod(n, 2) {
                        // Compute z * x.
                        let zx := mul(z, x)

                        // If z * x overflowed:
                        if iszero(eq(div(zx, x), z)) {
                            // Revert if x is non-zero.
                            if iszero(iszero(x)) {
                                revert(0, 0)
                            }
                        }

                        // Round to the nearest number.
                        let zxRound := add(zx, half)

                        // Revert if zx + half overflowed.
                        if lt(zxRound, zx) {
                            revert(0, 0)
                        }

                        // Return properly scaled zxRound.
                        z := div(zxRound, scalar)
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        GENERAL NUMBER UTILITIES
    //////////////////////////////////////////////////////////////*/

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            let y := x // We start y at x, which will help us make our initial estimate.

            z := 181 // The "correct" value is 1, but this saves a multiplication later.

            // This segment is to get a reasonable initial estimate for the Babylonian method. With a bad
            // start, the correct # of bits increases ~linearly each iteration instead of ~quadratically.

            // We check y >= 2^(k + 8) but shift right by k bits
            // each branch to ensure that if x >= 256, then y >= 256.
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }

            // Goal was to get z*z*y within a small factor of x. More iterations could
            // get y in a tighter range. Currently, we will have y in [256, 256*2^16).
            // We ensured y >= 256 so that the relative difference between y and y+1 is small.
            // That's not possible if x < 256 but we can just verify those cases exhaustively.

            // Now, z*z*y <= x < z*z*(y+1), and y <= 2^(16+8), and either y >= 256, or x < 256.
            // Correctness can be checked exhaustively for x < 256, so we assume y >= 256.
            // Then z*sqrt(y) is within sqrt(257)/sqrt(256) of sqrt(x), or about 20bps.

            // For s in the range [1/256, 256], the estimate f(s) = (181/1024) * (s+1) is in the range
            // (1/2.84 * sqrt(s), 2.84 * sqrt(s)), with largest error when s = 1 and when s = 256 or 1/256.

            // Since y is in [256, 256*2^16), let a = y/65536, so that a is in [1/256, 256). Then we can estimate
            // sqrt(y) using sqrt(65536) * 181/1024 * (a + 1) = 181/4 * (y + 65536)/65536 = 181 * (y + 65536)/2^18.

            // There is no overflow risk here since y < 2^136 after the first branch above.
            z := shr(18, mul(z, add(y, 65536))) // A mul() is saved from starting z at 181.

            // Given the worst case multiplicative error of 2.84 above, 7 iterations should be enough.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // If x+1 is a perfect square, the Babylonian method cycles between
            // floor(sqrt(x)) and ceil(sqrt(x)). This statement ensures we return floor.
            // See: https://en.wikipedia.org/wiki/Integer_square_root#Using_only_integer_division
            // Since the ceil is rare, we save gas on the assignment and repeat division in the rare case.
            // If you don't care whether the floor or ceil square root is returned, you can remove this statement.
            z := sub(z, lt(div(x, z), z))
        }
    }

    function unsafeMod(uint256 x, uint256 y) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Mod x by y. Note this will return
            // 0 instead of reverting if y is zero.
            z := mod(x, y)
        }
    }

    function unsafeDiv(uint256 x, uint256 y) internal pure returns (uint256 r) {
        /// @solidity memory-safe-assembly
        assembly {
            // Divide x by y. Note this will return
            // 0 instead of reverting if y is zero.
            r := div(x, y)
        }
    }

    function unsafeDivUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Add 1 to x * y if x % y > 0. Note this will
            // return 0 instead of reverting if y is zero.
            z := add(gt(mod(x, y), 0), div(x, y))
        }
    }
}

// File: src/interfaces/BeforeTransferHook.sol


pragma solidity 0.8.21;

interface BeforeTransferHook {
    function beforeTransfer(address from, address to, address operator) external view;
}

// File: lib/solmate/src/auth/Auth.sol


pragma solidity >=0.8.0;

/// @notice Provides a flexible and updatable auth pattern which is completely separate from application logic.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/auth/Auth.sol)
/// @author Modified from Dappsys (https://github.com/dapphub/ds-auth/blob/master/src/auth.sol)
abstract contract Auth {
    event OwnershipTransferred(address indexed user, address indexed newOwner);

    event AuthorityUpdated(address indexed user, Authority indexed newAuthority);

    address public owner;

    Authority public authority;

    constructor(address _owner, Authority _authority) {
        owner = _owner;
        authority = _authority;

        emit OwnershipTransferred(msg.sender, _owner);
        emit AuthorityUpdated(msg.sender, _authority);
    }

    modifier requiresAuth() virtual {
        require(isAuthorized(msg.sender, msg.sig), "UNAUTHORIZED");

        _;
    }

    function isAuthorized(address user, bytes4 functionSig) internal view virtual returns (bool) {
        Authority auth = authority; // Memoizing authority saves us a warm SLOAD, around 100 gas.

        // Checking if the caller is the owner only after calling the authority saves gas in most cases, but be
        // aware that this makes protected functions uncallable even to the owner if the authority is out of order.
        return (address(auth) != address(0) && auth.canCall(user, address(this), functionSig)) || user == owner;
    }

    function setAuthority(Authority newAuthority) public virtual {
        // We check if the caller is the owner first because we want to ensure they can
        // always swap out the authority even if it's reverting or using up a lot of gas.
        require(msg.sender == owner || authority.canCall(msg.sender, address(this), msg.sig));

        authority = newAuthority;

        emit AuthorityUpdated(msg.sender, newAuthority);
    }

    function transferOwnership(address newOwner) public virtual requiresAuth {
        owner = newOwner;

        emit OwnershipTransferred(msg.sender, newOwner);
    }
}

/// @notice A generic interface for a contract which provides authorization data to an Auth instance.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/auth/Auth.sol)
/// @author Modified from Dappsys (https://github.com/dapphub/ds-auth/blob/master/src/auth.sol)
interface Authority {
    function canCall(
        address user,
        address target,
        bytes4 functionSig
    ) external view returns (bool);
}

// File: src/base/BoringVault.sol


pragma solidity 0.8.21;









contract BoringVault is ERC20, Auth, ERC721Holder, ERC1155Holder {
    using Address for address;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // ========================================= STATE =========================================

    /**
     * @notice Contract responsbile for implementing `beforeTransfer`.
     */
    BeforeTransferHook public hook;

    //============================== EVENTS ===============================

    event Enter(address indexed from, address indexed asset, uint256 amount, address indexed to, uint256 shares);
    event Exit(address indexed to, address indexed asset, uint256 amount, address indexed from, uint256 shares);

    //============================== CONSTRUCTOR ===============================

    constructor(address _owner, string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol, _decimals)
        Auth(_owner, Authority(address(0)))
    {}

    //============================== MANAGE ===============================

    /**
     * @notice Allows manager to make an arbitrary function call from this contract.
     * @dev Callable by MANAGER_ROLE.
     */
    function manage(address target, bytes calldata data, uint256 value)
        external
        requiresAuth
        returns (bytes memory result)
    {
        result = target.functionCallWithValue(data, value);
    }

    /**
     * @notice Allows manager to make arbitrary function calls from this contract.
     * @dev Callable by MANAGER_ROLE.
     */
    function manage(address[] calldata targets, bytes[] calldata data, uint256[] calldata values)
        external
        requiresAuth
        returns (bytes[] memory results)
    {
        uint256 targetsLength = targets.length;
        results = new bytes[](targetsLength);
        for (uint256 i; i < targetsLength; ++i) {
            results[i] = targets[i].functionCallWithValue(data[i], values[i]);
        }
    }

    //============================== ENTER ===============================

    /**
     * @notice Allows minter to mint shares, in exchange for assets.
     * @dev If assetAmount is zero, no assets are transferred in.
     * @dev Callable by MINTER_ROLE.
     */
    function enter(address from, ERC20 asset, uint256 assetAmount, address to, uint256 shareAmount)
        external
        requiresAuth
    {
        // Transfer assets in
        if (assetAmount > 0) asset.safeTransferFrom(from, address(this), assetAmount);

        // Mint shares.
        _mint(to, shareAmount);

        emit Enter(from, address(asset), assetAmount, to, shareAmount);
    }

    //============================== EXIT ===============================

    /**
     * @notice Allows burner to burn shares, in exchange for assets.
     * @dev If assetAmount is zero, no assets are transferred out.
     * @dev Callable by BURNER_ROLE.
     */
    function exit(address to, ERC20 asset, uint256 assetAmount, address from, uint256 shareAmount)
        external
        requiresAuth
    {
        // Burn shares.
        _burn(from, shareAmount);

        // Transfer assets out.
        if (assetAmount > 0) asset.safeTransfer(to, assetAmount);

        emit Exit(to, address(asset), assetAmount, from, shareAmount);
    }

    //============================== BEFORE TRANSFER HOOK ===============================
    /**
     * @notice Sets the share locker.
     * @notice If set to zero address, the share locker logic is disabled.
     * @dev Callable by OWNER_ROLE.
     */
    function setBeforeTransferHook(address _hook) external requiresAuth {
        hook = BeforeTransferHook(_hook);
    }

    /**
     * @notice Call `beforeTransferHook` passing in `from` `to`, and `msg.sender`.
     */
    function _callBeforeTransfer(address from, address to) internal view {
        if (address(hook) != address(0)) hook.beforeTransfer(from, to, msg.sender);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _callBeforeTransfer(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _callBeforeTransfer(from, to);
        return super.transferFrom(from, to, amount);
    }

    //============================== RECEIVE ===============================

    receive() external payable {}
}

// File: src/interfaces/IRateProvider.sol


// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

interface IRateProvider {
    function getRate() external view returns (uint256);
}

// File: src/interfaces/IPausable.sol


pragma solidity 0.8.21;

interface IPausable {
    function pause() external;
    function unpause() external;
}

// File: src/base/Roles/AccountantWithRateProviders.sol


pragma solidity 0.8.21;








contract AccountantWithRateProviders is Auth, IRateProvider, IPausable {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    // ========================================= STRUCTS =========================================

    /**
     * @param payoutAddress the address `claimFees` sends fees to
     * @param highwaterMark the highest value of the BoringVault's share price
     * @param feesOwedInBase total pending fees owed in terms of base
     * @param totalSharesLastUpdate total amount of shares the last exchange rate update
     * @param exchangeRate the current exchange rate in terms of base
     * @param allowedExchangeRateChangeUpper the max allowed change to exchange rate from an update
     * @param allowedExchangeRateChangeLower the min allowed change to exchange rate from an update
     * @param lastUpdateTimestamp the block timestamp of the last exchange rate update
     * @param isPaused whether or not this contract is paused
     * @param minimumUpdateDelayInSeconds the minimum amount of time that must pass between
     *        exchange rate updates, such that the update won't trigger the contract to be paused
     * @param platformFee the platform fee
     * @param performanceFee the performance fee
     */
    struct AccountantState {
        address payoutAddress;
        uint96 highwaterMark;
        uint128 feesOwedInBase;
        uint128 totalSharesLastUpdate;
        uint96 exchangeRate;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint64 lastUpdateTimestamp;
        bool isPaused;
        uint24 minimumUpdateDelayInSeconds;
        uint16 platformFee;
        uint16 performanceFee;
    }

    /**
     * @param isPeggedToBase whether or not the asset is 1:1 with the base asset
     * @param rateProvider the rate provider for this asset if `isPeggedToBase` is false
     */
    struct RateProviderData {
        bool isPeggedToBase;
        IRateProvider rateProvider;
    }

    // ========================================= STATE =========================================

    /**
     * @notice Store the accountant state in 3 packed slots.
     */
    AccountantState public accountantState;

    /**
     * @notice Maps ERC20s to their RateProviderData.
     */
    mapping(ERC20 => RateProviderData) public rateProviderData;

    //============================== ERRORS ===============================

    error AccountantWithRateProviders__UpperBoundTooSmall();
    error AccountantWithRateProviders__LowerBoundTooLarge();
    error AccountantWithRateProviders__PlatformFeeTooLarge();
    error AccountantWithRateProviders__PerformanceFeeTooLarge();
    error AccountantWithRateProviders__Paused();
    error AccountantWithRateProviders__ZeroFeesOwed();
    error AccountantWithRateProviders__OnlyCallableByBoringVault();
    error AccountantWithRateProviders__UpdateDelayTooLarge();
    error AccountantWithRateProviders__ExchangeRateAboveHighwaterMark();

    //============================== EVENTS ===============================

    event Paused();
    event Unpaused();
    event DelayInSecondsUpdated(uint24 oldDelay, uint24 newDelay);
    event UpperBoundUpdated(uint16 oldBound, uint16 newBound);
    event LowerBoundUpdated(uint16 oldBound, uint16 newBound);
    event PlatformFeeUpdated(uint16 oldFee, uint16 newFee);
    event PerformanceFeeUpdated(uint16 oldFee, uint16 newFee);
    event PayoutAddressUpdated(address oldPayout, address newPayout);
    event RateProviderUpdated(address asset, bool isPegged, address rateProvider);
    event ExchangeRateUpdated(uint96 oldRate, uint96 newRate, uint64 currentTime);
    event FeesClaimed(address indexed feeAsset, uint256 amount);
    event HighwaterMarkReset();

    //============================== IMMUTABLES ===============================

    /**
     * @notice The base asset rates are provided in.
     */
    ERC20 public immutable base;

    /**
     * @notice The decimals rates are provided in.
     */
    uint8 public immutable decimals;

    /**
     * @notice The BoringVault this accountant is working with.
     *         Used to determine share supply for fee calculation.
     */
    BoringVault public immutable vault;

    /**
     * @notice One share of the BoringVault.
     */
    uint256 internal immutable ONE_SHARE;

    constructor(
        address _owner,
        address _vault,
        address payoutAddress,
        uint96 startingExchangeRate,
        address _base,
        uint16 allowedExchangeRateChangeUpper,
        uint16 allowedExchangeRateChangeLower,
        uint24 minimumUpdateDelayInSeconds,
        uint16 platformFee,
        uint16 performanceFee
    ) Auth(_owner, Authority(address(0))) {
        base = ERC20(_base);
        decimals = ERC20(_base).decimals();
        vault = BoringVault(payable(_vault));
        ONE_SHARE = 10 ** vault.decimals();
        accountantState = AccountantState({
            payoutAddress: payoutAddress,
            highwaterMark: startingExchangeRate,
            feesOwedInBase: 0,
            totalSharesLastUpdate: uint128(vault.totalSupply()),
            exchangeRate: startingExchangeRate,
            allowedExchangeRateChangeUpper: allowedExchangeRateChangeUpper,
            allowedExchangeRateChangeLower: allowedExchangeRateChangeLower,
            lastUpdateTimestamp: uint64(block.timestamp),
            isPaused: false,
            minimumUpdateDelayInSeconds: minimumUpdateDelayInSeconds,
            platformFee: platformFee,
            performanceFee: performanceFee
        });
    }

    // ========================================= ADMIN FUNCTIONS =========================================
    /**
     * @notice Pause this contract, which prevents future calls to `updateExchangeRate`, and any safe rate
     *         calls will revert.
     * @dev Callable by MULTISIG_ROLE.
     */
    function pause() external requiresAuth {
        accountantState.isPaused = true;
        emit Paused();
    }

    /**
     * @notice Unpause this contract, which allows future calls to `updateExchangeRate`, and any safe rate
     *         calls will stop reverting.
     * @dev Callable by MULTISIG_ROLE.
     */
    function unpause() external requiresAuth {
        accountantState.isPaused = false;
        emit Unpaused();
    }

    /**
     * @notice Update the minimum time delay between `updateExchangeRate` calls.
     * @dev There are no input requirements, as it is possible the admin would want
     *      the exchange rate updated as frequently as needed.
     * @dev Callable by OWNER_ROLE.
     */
    function updateDelay(uint24 minimumUpdateDelayInSeconds) external requiresAuth {
        if (minimumUpdateDelayInSeconds > 14 days) revert AccountantWithRateProviders__UpdateDelayTooLarge();
        uint24 oldDelay = accountantState.minimumUpdateDelayInSeconds;
        accountantState.minimumUpdateDelayInSeconds = minimumUpdateDelayInSeconds;
        emit DelayInSecondsUpdated(oldDelay, minimumUpdateDelayInSeconds);
    }

    /**
     * @notice Update the allowed upper bound change of exchange rate between `updateExchangeRateCalls`.
     * @dev Callable by OWNER_ROLE.
     */
    function updateUpper(uint16 allowedExchangeRateChangeUpper) external requiresAuth {
        if (allowedExchangeRateChangeUpper < 1e4) revert AccountantWithRateProviders__UpperBoundTooSmall();
        uint16 oldBound = accountantState.allowedExchangeRateChangeUpper;
        accountantState.allowedExchangeRateChangeUpper = allowedExchangeRateChangeUpper;
        emit UpperBoundUpdated(oldBound, allowedExchangeRateChangeUpper);
    }

    /**
     * @notice Update the allowed lower bound change of exchange rate between `updateExchangeRateCalls`.
     * @dev Callable by OWNER_ROLE.
     */
    function updateLower(uint16 allowedExchangeRateChangeLower) external requiresAuth {
        if (allowedExchangeRateChangeLower > 1e4) revert AccountantWithRateProviders__LowerBoundTooLarge();
        uint16 oldBound = accountantState.allowedExchangeRateChangeLower;
        accountantState.allowedExchangeRateChangeLower = allowedExchangeRateChangeLower;
        emit LowerBoundUpdated(oldBound, allowedExchangeRateChangeLower);
    }

    /**
     * @notice Update the platform fee to a new value.
     * @dev Callable by OWNER_ROLE.
     */
    function updatePlatformFee(uint16 platformFee) external requiresAuth {
        if (platformFee > 0.2e4) revert AccountantWithRateProviders__PlatformFeeTooLarge();
        uint16 oldFee = accountantState.platformFee;
        accountantState.platformFee = platformFee;
        emit PlatformFeeUpdated(oldFee, platformFee);
    }

    /**
     * @notice Update the performance fee to a new value.
     * @dev Callable by OWNER_ROLE.
     */
    function updatePerformanceFee(uint16 performanceFee) external requiresAuth {
        if (performanceFee > 0.5e4) revert AccountantWithRateProviders__PerformanceFeeTooLarge();
        uint16 oldFee = accountantState.performanceFee;
        accountantState.performanceFee = performanceFee;
        emit PerformanceFeeUpdated(oldFee, performanceFee);
    }

    /**
     * @notice Update the payout address fees are sent to.
     * @dev Callable by OWNER_ROLE.
     */
    function updatePayoutAddress(address payoutAddress) external requiresAuth {
        address oldPayout = accountantState.payoutAddress;
        accountantState.payoutAddress = payoutAddress;
        emit PayoutAddressUpdated(oldPayout, payoutAddress);
    }

    /**
     * @notice Update the rate provider data for a specific `asset`.
     * @dev Rate providers must return rates in terms of `base` or
     * an asset pegged to base and they must use the same decimals
     * as `asset`.
     * @dev Callable by OWNER_ROLE.
     */
    function setRateProviderData(ERC20 asset, bool isPeggedToBase, address rateProvider) external requiresAuth {
        rateProviderData[asset] =
            RateProviderData({isPeggedToBase: isPeggedToBase, rateProvider: IRateProvider(rateProvider)});
        emit RateProviderUpdated(address(asset), isPeggedToBase, rateProvider);
    }

    /**
     * @notice Reset the highwater mark to the current exchange rate.
     * @dev Callable by OWNER_ROLE.
     */
    function resetHighwaterMark() external virtual requiresAuth {
        AccountantState storage state = accountantState;

        if (state.exchangeRate > state.highwaterMark) {
            revert AccountantWithRateProviders__ExchangeRateAboveHighwaterMark();
        }

        uint64 currentTime = uint64(block.timestamp);
        uint256 currentTotalShares = vault.totalSupply();
        _calculateFeesOwed(state, state.exchangeRate, state.exchangeRate, currentTotalShares, currentTime);
        state.totalSharesLastUpdate = uint128(currentTotalShares);
        state.highwaterMark = accountantState.exchangeRate;
        state.lastUpdateTimestamp = currentTime;

        emit HighwaterMarkReset();
    }

    // ========================================= UPDATE EXCHANGE RATE/FEES FUNCTIONS =========================================

    /**
     * @notice Updates this contract exchangeRate.
     * @dev If new exchange rate is outside of accepted bounds, or if not enough time has passed, this
     *      will pause the contract, and this function will NOT calculate fees owed.
     * @dev Callable by UPDATE_EXCHANGE_RATE_ROLE.
     */
    function updateExchangeRate(uint96 newExchangeRate) external virtual requiresAuth {
        (
            bool shouldPause,
            AccountantState storage state,
            uint64 currentTime,
            uint256 currentExchangeRate,
            uint256 currentTotalShares
        ) = _beforeUpdateExchangeRate(newExchangeRate);
        if (shouldPause) {
            // Instead of reverting, pause the contract. This way the exchange rate updater is able to update the exchange rate
            // to a better value, and pause it.
            state.isPaused = true;
        } else {
            _calculateFeesOwed(state, newExchangeRate, currentExchangeRate, currentTotalShares, currentTime);
        }

        newExchangeRate = _setExchangeRate(newExchangeRate, state);
        state.totalSharesLastUpdate = uint128(currentTotalShares);
        state.lastUpdateTimestamp = currentTime;

        emit ExchangeRateUpdated(uint96(currentExchangeRate), newExchangeRate, currentTime);
    }

    /**
     * @notice Claim pending fees.
     * @dev This function must be called by the BoringVault.
     * @dev This function will lose precision if the exchange rate
     *      decimals is greater than the feeAsset's decimals.
     */
    function claimFees(ERC20 feeAsset) external {
        if (msg.sender != address(vault)) revert AccountantWithRateProviders__OnlyCallableByBoringVault();

        AccountantState storage state = accountantState;
        if (state.isPaused) revert AccountantWithRateProviders__Paused();
        if (state.feesOwedInBase == 0) revert AccountantWithRateProviders__ZeroFeesOwed();

        // Determine amount of fees owed in feeAsset.
        uint256 feesOwedInFeeAsset;
        RateProviderData memory data = rateProviderData[feeAsset];
        if (address(feeAsset) == address(base)) {
            feesOwedInFeeAsset = state.feesOwedInBase;
        } else {
            uint8 feeAssetDecimals = ERC20(feeAsset).decimals();
            uint256 feesOwedInBaseUsingFeeAssetDecimals =
                _changeDecimals(state.feesOwedInBase, decimals, feeAssetDecimals);
            if (data.isPeggedToBase) {
                feesOwedInFeeAsset = feesOwedInBaseUsingFeeAssetDecimals;
            } else {
                uint256 rate = data.rateProvider.getRate();
                feesOwedInFeeAsset = feesOwedInBaseUsingFeeAssetDecimals.mulDivDown(10 ** feeAssetDecimals, rate);
            }
        }
        // Zero out fees owed.
        state.feesOwedInBase = 0;
        // Transfer fee asset to payout address.
        feeAsset.safeTransferFrom(msg.sender, state.payoutAddress, feesOwedInFeeAsset);

        emit FeesClaimed(address(feeAsset), feesOwedInFeeAsset);
    }

    // ========================================= VIEW FUNCTIONS =========================================

    /**
     * @notice Get this BoringVault's current rate in the base.
     */
    function getRate() public view returns (uint256 rate) {
        rate = accountantState.exchangeRate;
    }

    /**
     * @notice Get this BoringVault's current rate in the base.
     * @dev Revert if paused.
     */
    function getRateSafe() external view returns (uint256 rate) {
        if (accountantState.isPaused) revert AccountantWithRateProviders__Paused();
        rate = getRate();
    }

    /**
     * @notice Get this BoringVault's current rate in the provided quote.
     * @dev `quote` must have its RateProviderData set, else this will revert.
     * @dev This function will lose precision if the exchange rate
     *      decimals is greater than the quote's decimals.
     */
    function getRateInQuote(ERC20 quote) public view returns (uint256 rateInQuote) {
        if (address(quote) == address(base)) {
            rateInQuote = accountantState.exchangeRate;
        } else {
            RateProviderData memory data = rateProviderData[quote];
            uint8 quoteDecimals = ERC20(quote).decimals();
            uint256 exchangeRateInQuoteDecimals = _changeDecimals(accountantState.exchangeRate, decimals, quoteDecimals);
            if (data.isPeggedToBase) {
                rateInQuote = exchangeRateInQuoteDecimals;
            } else {
                uint256 quoteRate = data.rateProvider.getRate();
                uint256 oneQuote = 10 ** quoteDecimals;
                rateInQuote = oneQuote.mulDivDown(exchangeRateInQuoteDecimals, quoteRate);
            }
        }
    }

    /**
     * @notice Get this BoringVault's current rate in the provided quote.
     * @dev `quote` must have its RateProviderData set, else this will revert.
     * @dev Revert if paused.
     */
    function getRateInQuoteSafe(ERC20 quote) external view returns (uint256 rateInQuote) {
        if (accountantState.isPaused) revert AccountantWithRateProviders__Paused();
        rateInQuote = getRateInQuote(quote);
    }

    /**
     * @notice Preview the result of an update to the exchange rate.
     * @return updateWillPause Whether the update will pause the contract.
     * @return newFeesOwedInBase The new fees owed in base.
     * @return totalFeesOwedInBase The total fees owed in base.
     */
    function previewUpdateExchangeRate(uint96 newExchangeRate)
        external
        view
        virtual
        returns (bool updateWillPause, uint256 newFeesOwedInBase, uint256 totalFeesOwedInBase)
    {
        (
            bool shouldPause,
            AccountantState storage state,
            uint64 currentTime,
            uint256 currentExchangeRate,
            uint256 currentTotalShares
        ) = _beforeUpdateExchangeRate(newExchangeRate);
        updateWillPause = shouldPause;
        totalFeesOwedInBase = state.feesOwedInBase;
        if (!shouldPause) {
            (uint256 platformFeesOwedInBase, uint256 shareSupplyToUse) = _calculatePlatformFee(
                state.totalSharesLastUpdate,
                state.lastUpdateTimestamp,
                state.platformFee,
                newExchangeRate,
                currentExchangeRate,
                currentTotalShares,
                currentTime
            );

            uint256 performanceFeesOwedInBase;
            if (newExchangeRate > state.highwaterMark) {
                (performanceFeesOwedInBase,) = _calculatePerformanceFee(
                    newExchangeRate, shareSupplyToUse, state.highwaterMark, state.performanceFee
                );
            }
            newFeesOwedInBase = platformFeesOwedInBase + performanceFeesOwedInBase;
            totalFeesOwedInBase += newFeesOwedInBase;
        }
    }

    // ========================================= INTERNAL HELPER FUNCTIONS =========================================
    /**
     * @notice Used to change the decimals of precision used for an amount.
     */
    function _changeDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            return amount * 10 ** (toDecimals - fromDecimals);
        } else {
            return amount / 10 ** (fromDecimals - toDecimals);
        }
    }

    /**
     * @notice Check if the new exchange rate is outside of the allowed bounds or if not enough time has passed.
     */
    function _beforeUpdateExchangeRate(uint96 newExchangeRate)
        internal
        view
        returns (
            bool shouldPause,
            AccountantState storage state,
            uint64 currentTime,
            uint256 currentExchangeRate,
            uint256 currentTotalShares
        )
    {
        state = accountantState;
        if (state.isPaused) revert AccountantWithRateProviders__Paused();
        currentTime = uint64(block.timestamp);
        currentExchangeRate = state.exchangeRate;
        currentTotalShares = vault.totalSupply();
        shouldPause = currentTime < state.lastUpdateTimestamp + state.minimumUpdateDelayInSeconds
            || newExchangeRate > currentExchangeRate.mulDivDown(state.allowedExchangeRateChangeUpper, 1e4)
            || newExchangeRate < currentExchangeRate.mulDivDown(state.allowedExchangeRateChangeLower, 1e4);
    }

    /**
     * @notice Set the exchange rate.
     */
    function _setExchangeRate(uint96 newExchangeRate, AccountantState storage state)
        internal
        virtual
        returns (uint96)
    {
        state.exchangeRate = newExchangeRate;
        return newExchangeRate;
    }

    /**
     * @notice Calculate platform fees.
     */
    function _calculatePlatformFee(
        uint128 totalSharesLastUpdate,
        uint64 lastUpdateTimestamp,
        uint16 platformFee,
        uint96 newExchangeRate,
        uint256 currentExchangeRate,
        uint256 currentTotalShares,
        uint64 currentTime
    ) internal view returns (uint256 platformFeesOwedInBase, uint256 shareSupplyToUse) {
        shareSupplyToUse = currentTotalShares;
        // Use the minimum between current total supply and total supply for last update.
        if (totalSharesLastUpdate < shareSupplyToUse) {
            shareSupplyToUse = totalSharesLastUpdate;
        }

        // Determine platform fees owned.
        if (platformFee > 0) {
            uint256 timeDelta = currentTime - lastUpdateTimestamp;
            uint256 minimumAssets = newExchangeRate > currentExchangeRate
                ? shareSupplyToUse.mulDivDown(currentExchangeRate, ONE_SHARE)
                : shareSupplyToUse.mulDivDown(newExchangeRate, ONE_SHARE);
            uint256 platformFeesAnnual = minimumAssets.mulDivDown(platformFee, 1e4);
            platformFeesOwedInBase = platformFeesAnnual.mulDivDown(timeDelta, 365 days);
        }
    }

    /**
     * @notice Calculate performance fees.
     */
    function _calculatePerformanceFee(
        uint96 newExchangeRate,
        uint256 shareSupplyToUse,
        uint96 datum,
        uint16 performanceFee
    ) internal view returns (uint256 performanceFeesOwedInBase, uint256 yieldEarned) {
        uint256 changeInExchangeRate = newExchangeRate - datum;
        yieldEarned = changeInExchangeRate.mulDivDown(shareSupplyToUse, ONE_SHARE);
        if (performanceFee > 0) {
            performanceFeesOwedInBase = yieldEarned.mulDivDown(performanceFee, 1e4);
        }
    }

    /**
     * @notice Calculate fees owed in base.
     * @dev This function will update the highwater mark if the new exchange rate is higher.
     */
    function _calculateFeesOwed(
        AccountantState storage state,
        uint96 newExchangeRate,
        uint256 currentExchangeRate,
        uint256 currentTotalShares,
        uint64 currentTime
    ) internal virtual {
        // Only update fees if we are not paused.
        // Update fee accounting.
        (uint256 newFeesOwedInBase, uint256 shareSupplyToUse) = _calculatePlatformFee(
            state.totalSharesLastUpdate,
            state.lastUpdateTimestamp,
            state.platformFee,
            newExchangeRate,
            currentExchangeRate,
            currentTotalShares,
            currentTime
        );

        // Account for performance fees.
        if (newExchangeRate > state.highwaterMark) {
            (uint256 performanceFeesOwedInBase,) =
                _calculatePerformanceFee(newExchangeRate, shareSupplyToUse, state.highwaterMark, state.performanceFee);

            // Add performance fees to fees owed.
            newFeesOwedInBase += performanceFeesOwedInBase;

            // Always update the highwater mark if the new exchange rate is higher.
            // This way if we are not iniitiall taking performance fees, we can start taking them
            // without back charging them on past performance.
            state.highwaterMark = newExchangeRate;
        }

        state.feesOwedInBase += uint128(newFeesOwedInBase);
    }
}

// File: lib/solmate/src/utils/ReentrancyGuard.sol


pragma solidity >=0.8.0;

/// @notice Gas optimized reentrancy protection for smart contracts.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/ReentrancyGuard.sol)
/// @author Modified from OpenZeppelin (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol)
abstract contract ReentrancyGuard {
    uint256 private locked = 1;

    modifier nonReentrant() virtual {
        require(locked == 1, "REENTRANCY");

        locked = 2;

        _;

        locked = 1;
    }
}

// File: lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol


// OpenZeppelin Contracts (last updated v5.0.0) (utils/structs/EnumerableSet.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableSet.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }
}

// File: src/base/Roles/BoringQueue/IBoringSolver.sol


pragma solidity 0.8.21;

interface IBoringSolver {
    function boringSolve(
        address initiator,
        address boringVault,
        address solveAsset,
        uint256 totalShares,
        uint256 requiredAssets,
        bytes calldata solveData
    ) external;
}

// File: src/base/Roles/BoringQueue/BoringOnChainQueue.sol


pragma solidity 0.8.21;













contract BoringOnChainQueue is Auth, ReentrancyGuard, IPausable {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeTransferLib for BoringVault;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // ========================================= STRUCTS =========================================

    /**
     * @param allowWithdraws Whether or not withdraws are allowed for this asset.
     * @param secondsToMaturity The time in seconds it takes for the asset to mature.
     * @param minimumSecondsToDeadline The minimum time in seconds a withdraw request must be valid for before it is expired
     * @param minDiscount The minimum discount allowed for a withdraw request.
     * @param maxDiscount The maximum discount allowed for a withdraw request.
     * @param minimumShares The minimum amount of shares that can be withdrawn.
     * @param withdrawCapacity The maximum amount of total shares that can be withdrawn.
     *        - Can be set to type(uint256).max to allow unlimited withdraws.
     *        - Decremented when users make requests.
     *        - Incremented when users cancel requests.
     *        - Can be set by admin.
     */
    struct WithdrawAsset {
        bool allowWithdraws;
        uint24 secondsToMaturity;
        uint24 minimumSecondsToDeadline;
        uint16 minDiscount;
        uint16 maxDiscount;
        uint96 minimumShares;
        uint256 withdrawCapacity;
    }

    /**
     * @param nonce The nonce of the request, used to make it impossible for request Ids to be repeated.
     * @param user The user that made the request.
     * @param assetOut The asset that the user wants to withdraw.
     * @param amountOfShares The amount of shares the user wants to withdraw.
     * @param amountOfAssets The amount of assets the user will receive.
     * @param creationTime The time the request was made.
     * @param secondsToMaturity The time in seconds it takes for the asset to mature.
     * @param secondsToDeadline The time in seconds the request is valid for.
     */
    struct OnChainWithdraw {
        uint96 nonce; // read from state, used to make it impossible for request Ids to be repeated.
        address user; // msg.sender
        address assetOut; // input sanitized
        uint128 amountOfShares; // input transfered in
        uint128 amountOfAssets; // derived from amountOfShares and price
        uint40 creationTime; // time withdraw was made
        uint24 secondsToMaturity; // in contract, from withdrawAsset?
        uint24 secondsToDeadline; // in contract, from withdrawAsset? To get the deadline you take the creationTime add seconds to maturity, add the secondsToDeadline
    }

    // ========================================= CONSTANTS =========================================
    /**
     * @notice The maximum discount allowed for a withdraw asset.
     */
    uint16 internal constant MAX_DISCOUNT = 0.3e4;

    /**
     * @notice The maximum time in seconds a withdraw asset can take to mature.
     */
    uint24 internal constant MAXIMUM_SECONDS_TO_MATURITY = 30 days;

    /**
     * @notice Caps the minimum time in seconds a withdraw request must be valid for before it is expired.
     */
    uint24 internal constant MAXIMUM_MINIMUM_SECONDS_TO_DEADLINE = 30 days;

    // ========================================= MODIFIERS =========================================

    /**
     * @notice Ensure that the request user is the same as the message sender.
     */
    modifier onlyRequestUser(address requestUser, address msgSender) {
        if (requestUser != msgSender) revert BoringOnChainQueue__BadUser();
        _;
    }

    // ========================================= GLOBAL STATE =========================================

    /**
     * @notice Open Zeppelin EnumerableSet to store all withdraw requests, by there request Id.
     */
    EnumerableSet.Bytes32Set private _withdrawRequests;

    /**
     * @notice Mapping of asset addresses to WithdrawAssets.
     */
    mapping(address => WithdrawAsset) public withdrawAssets;

    /**
     * @notice The nonce of the next request.
     * @dev The purpose of this nonce is to prevent request Ids from being repeated.
     * @dev Start at 1, since 0 is considered invalid.
     * @dev When incrementing the nonce, an unchecked block is used to save gas.
     *      This is safe because you can not feasibly make a request, and then cause an overflow
     *      in the same block such that you can make 2 requests with the same request Id.
     *      And even if you did, the tx would revert with a keccak256 collision error.
     */
    uint96 public nonce = 1;

    /**
     * @notice Whether or not the contract is paused.
     */
    bool public isPaused;

    //============================== ERRORS ===============================

    error BoringOnChainQueue__Paused();
    error BoringOnChainQueue__WithdrawsNotAllowedForAsset();
    error BoringOnChainQueue__BadDiscount();
    error BoringOnChainQueue__BadShareAmount();
    error BoringOnChainQueue__BadDeadline();
    error BoringOnChainQueue__BadUser();
    error BoringOnChainQueue__DeadlinePassed();
    error BoringOnChainQueue__NotMatured();
    error BoringOnChainQueue__Keccak256Collision();
    error BoringOnChainQueue__RequestNotFound();
    error BoringOnChainQueue__PermitFailedAndAllowanceTooLow();
    error BoringOnChainQueue__MAX_DISCOUNT();
    error BoringOnChainQueue__MAXIMUM_MINIMUM_SECONDS_TO_DEADLINE();
    error BoringOnChainQueue__SolveAssetMismatch();
    error BoringOnChainQueue__Overflow();
    error BoringOnChainQueue__MAXIMUM_SECONDS_TO_MATURITY();
    error BoringOnChainQueue__BadInput();
    error BoringOnChainQueue__RescueCannotTakeSharesFromActiveRequests();
    error BoringOnChainQueue__NotEnoughWithdrawCapacity();

    //============================== EVENTS ===============================

    event OnChainWithdrawRequested(
        bytes32 indexed requestId,
        address indexed user,
        address indexed assetOut,
        uint96 nonce,
        uint128 amountOfShares,
        uint128 amountOfAssets,
        uint40 creationTime,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    );

    event OnChainWithdrawCancelled(bytes32 indexed requestId, address indexed user, uint256 timestamp);

    event OnChainWithdrawSolved(bytes32 indexed requestId, address indexed user, uint256 timestamp);

    event WithdrawAssetStopped(address indexed assetOut);

    event WithdrawAssetUpdated(
        address indexed assetOut,
        uint24 secondsToMaturity,
        uint24 minimumSecondsToDeadline,
        uint16 minDiscount,
        uint16 maxDiscount,
        uint96 minimumShares
    );

    event WithdrawCapacityUpdated(address indexed assetOut, uint256 withdrawCapacity);

    event Paused();

    event Unpaused();

    //============================== IMMUTABLES ===============================

    /**
     * @notice The BoringVault contract to withdraw from.
     */
    BoringVault public immutable boringVault;

    /**
     * @notice The AccountantWithRateProviders contract to get rates from.
     */
    AccountantWithRateProviders public immutable accountant;

    /**
     * @notice One BoringVault share.
     */
    uint256 public immutable ONE_SHARE;

    constructor(address _owner, address _auth, address payable _boringVault, address _accountant)
        Auth(_owner, Authority(_auth))
    {
        boringVault = BoringVault(_boringVault);
        ONE_SHARE = 10 ** boringVault.decimals();
        accountant = AccountantWithRateProviders(_accountant);
    }

    //=============================== ADMIN FUNCTIONS ================================

    /**
     * @notice Allows the owner to rescue tokens from the contract.
     * @dev The owner can only withdraw BoringVault shares if they are accidentally sent to this contract.
     *      Shares from active withdraw requests are not withdrawable.
     * @param token The token to rescue.
     * @param amount The amount to rescue.
     * @param to The address to send the rescued tokens to.
     * @param activeRequests The active withdraw requests, query `getWithdrawRequests`, or read events to get them.
     * @dev Provided activeRequests must match the order of active requests in the queue.
     */
    function rescueTokens(ERC20 token, uint256 amount, address to, OnChainWithdraw[] calldata activeRequests)
        external
        requiresAuth
    {
        if (address(token) == address(boringVault)) {
            bytes32[] memory requestIds = _withdrawRequests.values();
            uint256 requestIdsLength = requestIds.length;
            if (activeRequests.length != requestIdsLength) revert BoringOnChainQueue__BadInput();
            // Iterate through provided activeRequests, and hash each one to compare to the requestIds.
            // Also track the sum of shares to make sure it is less than or equal to the amount.
            uint256 activeRequestShareSum;
            for (uint256 i = 0; i < requestIdsLength; ++i) {
                if (keccak256(abi.encode(activeRequests[i])) != requestIds[i]) revert BoringOnChainQueue__BadInput();
                activeRequestShareSum += activeRequests[i].amountOfShares;
            }
            uint256 freeShares = boringVault.balanceOf(address(this)) - activeRequestShareSum;
            if (amount == type(uint256).max) amount = freeShares;
            else if (amount > freeShares) revert BoringOnChainQueue__RescueCannotTakeSharesFromActiveRequests();
        } else {
            if (amount == type(uint256).max) amount = token.balanceOf(address(this));
        }
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Pause this contract, which prevents future calls to any functions that
     *         create new requests, or solve active requests.
     * @dev Callable by MULTISIG_ROLE.
     */
    function pause() external requiresAuth {
        isPaused = true;
        emit Paused();
    }

    /**
     * @notice Unpause this contract, which allows future calls to any functions that
     *         create new requests, or solve active requests.
     * @dev Callable by MULTISIG_ROLE.
     */
    function unpause() external requiresAuth {
        isPaused = false;
        emit Unpaused();
    }

    /**
     * @notice Update a new withdraw asset or existing.
     * @dev Callable by MULTISIG_ROLE.
     * @param assetOut The asset to withdraw.
     * @param secondsToMaturity The time in seconds it takes for the withdraw to mature.
     * @param minimumSecondsToDeadline The minimum time in seconds a withdraw request must be valid for before it is expired.
     * @param minDiscount The minimum discount allowed for a withdraw request.
     * @param maxDiscount The maximum discount allowed for a withdraw request.
     * @param minimumShares The minimum amount of shares that can be withdrawn.
     */
    function updateWithdrawAsset(
        address assetOut,
        uint24 secondsToMaturity,
        uint24 minimumSecondsToDeadline,
        uint16 minDiscount,
        uint16 maxDiscount,
        uint96 minimumShares
    ) external requiresAuth {
        // Validate input.
        if (maxDiscount > MAX_DISCOUNT) revert BoringOnChainQueue__MAX_DISCOUNT();
        if (secondsToMaturity > MAXIMUM_SECONDS_TO_MATURITY) {
            revert BoringOnChainQueue__MAXIMUM_SECONDS_TO_MATURITY();
        }
        if (minimumSecondsToDeadline > MAXIMUM_MINIMUM_SECONDS_TO_DEADLINE) {
            revert BoringOnChainQueue__MAXIMUM_MINIMUM_SECONDS_TO_DEADLINE();
        }
        if (minDiscount > maxDiscount) revert BoringOnChainQueue__BadDiscount();
        // Make sure accountant can price it.
        accountant.getRateInQuoteSafe(ERC20(assetOut));

        withdrawAssets[assetOut] = WithdrawAsset({
            allowWithdraws: true,
            secondsToMaturity: secondsToMaturity,
            minimumSecondsToDeadline: minimumSecondsToDeadline,
            minDiscount: minDiscount,
            maxDiscount: maxDiscount,
            minimumShares: minimumShares,
            withdrawCapacity: type(uint256).max
        });

        emit WithdrawAssetUpdated(
            assetOut, secondsToMaturity, minimumSecondsToDeadline, minDiscount, maxDiscount, minimumShares
        );
    }

    /**
     * @notice Stop withdraws in an asset.
     * @dev Callable by MULTISIG_ROLE.
     * @param assetOut The asset to stop withdraws in.
     */
    function stopWithdrawsInAsset(address assetOut) external requiresAuth {
        withdrawAssets[assetOut].allowWithdraws = false;
        emit WithdrawAssetStopped(assetOut);
    }

    /**
     * @notice Set the withdraw capacity for an asset.
     * @dev Callable by STRATEGIST_MULTISIG_ROLE.
     * @param assetOut The asset to set the withdraw capacity for.
     * @param withdrawCapacity The new withdraw capacity.
     */
    function setWithdrawCapacity(address assetOut, uint256 withdrawCapacity) external requiresAuth {
        withdrawAssets[assetOut].withdrawCapacity = withdrawCapacity;
        emit WithdrawCapacityUpdated(assetOut, withdrawCapacity);
    }

    /**
     * @notice Cancel multiple user withdraws.
     * @dev Callable by STRATEGIST_MULTISIG_ROLE.
     */
    function cancelUserWithdraws(OnChainWithdraw[] calldata requests)
        external
        requiresAuth
        returns (bytes32[] memory canceledRequestIds)
    {
        uint256 requestsLength = requests.length;
        canceledRequestIds = new bytes32[](requestsLength);
        for (uint256 i = 0; i < requestsLength; ++i) {
            canceledRequestIds[i] = _cancelOnChainWithdraw(requests[i]);
        }
    }

    //=============================== USER FUNCTIONS ================================

    /**
     * @notice Request an on-chain withdraw.
     * @param assetOut The asset to withdraw.
     * @param amountOfShares The amount of shares to withdraw.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToDeadline The time in seconds the request is valid for.
     * @return requestId The request Id.
     */
    function requestOnChainWithdraw(address assetOut, uint128 amountOfShares, uint16 discount, uint24 secondsToDeadline)
        external
        virtual
        requiresAuth
        returns (bytes32 requestId)
    {
        _decrementWithdrawCapacity(assetOut, amountOfShares);
        WithdrawAsset memory withdrawAsset = withdrawAssets[assetOut];

        _beforeNewRequest(withdrawAsset, amountOfShares, discount, secondsToDeadline);

        boringVault.safeTransferFrom(msg.sender, address(this), amountOfShares);

        (requestId,) = _queueOnChainWithdraw(
            msg.sender, assetOut, amountOfShares, discount, withdrawAsset.secondsToMaturity, secondsToDeadline
        );
    }

    /**
     * @notice Request an on-chain withdraw with permit.
     * @param assetOut The asset to withdraw.
     * @param amountOfShares The amount of shares to withdraw.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToDeadline The time in seconds the request is valid for.
     * @param permitDeadline The deadline for the permit.
     * @param v The v value of the permit signature.
     * @param r The r value of the permit signature.
     * @param s The s value of the permit signature.
     * @return requestId The request Id.
     */
    function requestOnChainWithdrawWithPermit(
        address assetOut,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToDeadline,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual requiresAuth returns (bytes32 requestId) {
        _decrementWithdrawCapacity(assetOut, amountOfShares);
        WithdrawAsset memory withdrawAsset = withdrawAssets[assetOut];

        _beforeNewRequest(withdrawAsset, amountOfShares, discount, secondsToDeadline);

        try boringVault.permit(msg.sender, address(this), amountOfShares, permitDeadline, v, r, s) {}
        catch {
            if (boringVault.allowance(msg.sender, address(this)) < amountOfShares) {
                revert BoringOnChainQueue__PermitFailedAndAllowanceTooLow();
            }
        }

        boringVault.safeTransferFrom(msg.sender, address(this), amountOfShares);

        (requestId,) = _queueOnChainWithdraw(
            msg.sender, assetOut, amountOfShares, discount, withdrawAsset.secondsToMaturity, secondsToDeadline
        );
    }

    /**
     * @notice Cancel an on-chain withdraw.
     * @param request The request to cancel.
     * @return requestId The request Id.
     */
    function cancelOnChainWithdraw(OnChainWithdraw memory request)
        external
        virtual
        requiresAuth
        returns (bytes32 requestId)
    {
        requestId = _cancelOnChainWithdrawWithUserCheck(request);
    }

    /**
     * @notice Replace an on-chain withdraw.
     * @param oldRequest The request to replace.
     * @param discount The discount to apply to the new withdraw request in bps.
     * @param secondsToDeadline The time in seconds the new withdraw request is valid for.
     * @return oldRequestId The request Id of the old withdraw request.
     * @return newRequestId The request Id of the new withdraw request.
     */
    function replaceOnChainWithdraw(OnChainWithdraw memory oldRequest, uint16 discount, uint24 secondsToDeadline)
        external
        virtual
        requiresAuth
        returns (bytes32 oldRequestId, bytes32 newRequestId)
    {
        (oldRequestId, newRequestId) = _replaceOnChainWithdraw(oldRequest, discount, secondsToDeadline);
    }

    //============================== SOLVER FUNCTIONS ===============================

    /**
     * @notice Solve multiple on-chain withdraws.
     * @dev If `solveData` is empty, this contract will skip the callback function.
     * @param requests The requests to solve.
     * @param solveData The data to use to solve the requests.
     * @param solver The address of the solver.
     */
    function solveOnChainWithdraws(OnChainWithdraw[] calldata requests, bytes calldata solveData, address solver)
        external
        requiresAuth
    {
        if (isPaused) revert BoringOnChainQueue__Paused();

        ERC20 solveAsset = ERC20(requests[0].assetOut);
        uint256 requiredAssets;
        uint256 totalShares;
        uint256 requestsLength = requests.length;
        for (uint256 i = 0; i < requestsLength; ++i) {
            if (address(solveAsset) != requests[i].assetOut) revert BoringOnChainQueue__SolveAssetMismatch();
            uint256 maturity = requests[i].creationTime + requests[i].secondsToMaturity;
            if (block.timestamp < maturity) revert BoringOnChainQueue__NotMatured();
            uint256 deadline = maturity + requests[i].secondsToDeadline;
            if (block.timestamp > deadline) revert BoringOnChainQueue__DeadlinePassed();
            requiredAssets += requests[i].amountOfAssets;
            totalShares += requests[i].amountOfShares;
            bytes32 requestId = _dequeueOnChainWithdraw(requests[i]);
            emit OnChainWithdrawSolved(requestId, requests[i].user, block.timestamp);
        }

        // Transfer shares to solver.
        boringVault.safeTransfer(solver, totalShares);

        // Run callback function if data is provided.
        if (solveData.length > 0) {
            IBoringSolver(solver).boringSolve(
                msg.sender, address(boringVault), address(solveAsset), totalShares, requiredAssets, solveData
            );
        }

        for (uint256 i = 0; i < requestsLength; ++i) {
            solveAsset.safeTransferFrom(solver, requests[i].user, requests[i].amountOfAssets);
        }
    }

    //============================== VIEW FUNCTIONS ===============================

    /**
     * @notice Get all request Ids currently in the queue.
     * @dev Includes requests that are not mature, matured, and expired. But does not include requests that have been solved.
     * @return requestIds The request Ids.
     */
    function getRequestIds() public view returns (bytes32[] memory) {
        return _withdrawRequests.values();
    }

    /**
     * @notice Get the request Id for a request.
     * @param request The request.
     * @return requestId The request Id.
     */
    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32 requestId) {
        return keccak256(abi.encode(request));
    }

    /**
     * @notice Preview assets out from a withdraw request.
     */
    function previewAssetsOut(address assetOut, uint128 amountOfShares, uint16 discount)
        public
        view
        returns (uint128 amountOfAssets128)
    {
        uint256 price = accountant.getRateInQuoteSafe(ERC20(assetOut));
        price = price.mulDivDown(1e4 - discount, 1e4);
        uint256 amountOfAssets = uint256(amountOfShares).mulDivDown(price, ONE_SHARE);
        if (amountOfAssets > type(uint128).max) revert BoringOnChainQueue__Overflow();
        amountOfAssets128 = uint128(amountOfAssets);
    }

    //============================= INTERNAL FUNCTIONS ==============================

    /**
     * @notice Before a new request is made, validate the input.
     * @param withdrawAsset The withdraw asset.
     * @param amountOfShares The amount of shares to withdraw.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToDeadline The time in seconds the request is valid for.
     */
    function _beforeNewRequest(
        WithdrawAsset memory withdrawAsset,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToDeadline
    ) internal view virtual {
        if (isPaused) revert BoringOnChainQueue__Paused();

        if (!withdrawAsset.allowWithdraws) revert BoringOnChainQueue__WithdrawsNotAllowedForAsset();
        if (discount < withdrawAsset.minDiscount || discount > withdrawAsset.maxDiscount) {
            revert BoringOnChainQueue__BadDiscount();
        }
        if (amountOfShares < withdrawAsset.minimumShares) revert BoringOnChainQueue__BadShareAmount();
        if (secondsToDeadline < withdrawAsset.minimumSecondsToDeadline) revert BoringOnChainQueue__BadDeadline();
    }

    /**
     * @notice Cancel an on-chain withdraw.
     * @dev Verifies that the request user is the same as the msg.sender.
     * @param request The request to cancel.
     * @return requestId The request Id.
     */
    function _cancelOnChainWithdrawWithUserCheck(OnChainWithdraw memory request)
        internal
        virtual
        onlyRequestUser(request.user, msg.sender)
        returns (bytes32 requestId)
    {
        requestId = _cancelOnChainWithdraw(request);
    }

    /**
     * @notice Cancel an on-chain withdraw.
     * @param request The request to cancel.
     * @return requestId The request Id.
     */
    function _cancelOnChainWithdraw(OnChainWithdraw memory request) internal virtual returns (bytes32 requestId) {
        requestId = _dequeueOnChainWithdraw(request);
        _incrementWithdrawCapacity(request.assetOut, request.amountOfShares);
        boringVault.safeTransfer(request.user, request.amountOfShares);
        emit OnChainWithdrawCancelled(requestId, request.user, block.timestamp);
    }

    /**
     * @notice Replace an on-chain withdraw.
     * @dev Does not check withdraw capacity since it is replacing an existing request.
     * @param oldRequest The request to replace.
     * @param discount The discount to apply to the new withdraw request in bps.
     * @param secondsToDeadline The time in seconds the new withdraw request is valid for.
     * @return oldRequestId The request Id of the old withdraw request.
     * @return newRequestId The request Id of the new withdraw request.
     */
    function _replaceOnChainWithdraw(OnChainWithdraw memory oldRequest, uint16 discount, uint24 secondsToDeadline)
        internal
        virtual
        onlyRequestUser(oldRequest.user, msg.sender)
        returns (bytes32 oldRequestId, bytes32 newRequestId)
    {
        WithdrawAsset memory withdrawAsset = withdrawAssets[oldRequest.assetOut];

        _beforeNewRequest(withdrawAsset, oldRequest.amountOfShares, discount, secondsToDeadline);

        oldRequestId = _dequeueOnChainWithdraw(oldRequest);

        emit OnChainWithdrawCancelled(oldRequestId, oldRequest.user, block.timestamp);

        // Create new request.
        (newRequestId,) = _queueOnChainWithdraw(
            oldRequest.user,
            oldRequest.assetOut,
            oldRequest.amountOfShares,
            discount,
            withdrawAsset.secondsToMaturity,
            secondsToDeadline
        );
    }

    /**
     * @notice Decrement the withdraw capacity for an asset.
     * @param assetOut The asset to decrement the withdraw capacity for.
     * @param amountOfShares The amount of shares to decrement the withdraw capacity for.
     */
    function _decrementWithdrawCapacity(address assetOut, uint256 amountOfShares) internal {
        WithdrawAsset storage withdrawAsset = withdrawAssets[assetOut];
        if (withdrawAsset.withdrawCapacity < type(uint256).max) {
            if (withdrawAsset.withdrawCapacity < amountOfShares) revert BoringOnChainQueue__NotEnoughWithdrawCapacity();
            withdrawAsset.withdrawCapacity -= amountOfShares;
            emit WithdrawCapacityUpdated(assetOut, withdrawAsset.withdrawCapacity);
        }
    }

    /**
     * @notice Increment the withdraw capacity for an asset.
     * @param assetOut The asset to increment the withdraw capacity for.
     * @param amountOfShares The amount of shares to increment the withdraw capacity for.
     */
    function _incrementWithdrawCapacity(address assetOut, uint256 amountOfShares) internal {
        WithdrawAsset storage withdrawAsset = withdrawAssets[assetOut];
        if (withdrawAsset.withdrawCapacity < type(uint256).max) {
            withdrawAsset.withdrawCapacity += amountOfShares;
            emit WithdrawCapacityUpdated(assetOut, withdrawAsset.withdrawCapacity);
        }
    }

    /**
     * @notice Queue an on-chain withdraw.
     * @dev Reverts if the request is already in the queue. Though this should be impossible.
     * @param user The user that made the request.
     * @param assetOut The asset to withdraw.
     * @param amountOfShares The amount of shares to withdraw.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToMaturity The time in seconds it takes for the asset to mature.
     * @param secondsToDeadline The time in seconds the request is valid for.
     * @return requestId The request Id.
     */
    function _queueOnChainWithdraw(
        address user,
        address assetOut,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    ) internal virtual returns (bytes32 requestId, OnChainWithdraw memory req) {
        // Create new request.
        uint96 requestNonce;
        // See nonce definition for unchecked safety.
        unchecked {
            // Set request nonce as current nonce, then increment nonce.
            requestNonce = nonce++;
        }

        uint128 amountOfAssets128 = previewAssetsOut(assetOut, amountOfShares, discount);

        uint40 timeNow = uint40(block.timestamp); // Safe to cast to uint40 as it won't overflow for 10s of thousands of years
        req = OnChainWithdraw({
            nonce: requestNonce,
            user: user,
            assetOut: assetOut,
            amountOfShares: amountOfShares,
            amountOfAssets: amountOfAssets128,
            creationTime: timeNow,
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });

        requestId = keccak256(abi.encode(req));

        bool addedToSet = _withdrawRequests.add(requestId);

        if (!addedToSet) revert BoringOnChainQueue__Keccak256Collision();

        emit OnChainWithdrawRequested(
            requestId,
            user,
            assetOut,
            requestNonce,
            amountOfShares,
            amountOfAssets128,
            timeNow,
            secondsToMaturity,
            secondsToDeadline
        );
    }

    /**
     * @notice Dequeue an on-chain withdraw.
     * @dev Reverts if the request is not in the queue.
     * @dev Does not remove the request from the onChainWithdraws mapping, so that
     *      it can be referenced later by off-chain systems if needed.
     * @param request The request to dequeue.
     * @return requestId The request Id.
     */
    function _dequeueOnChainWithdraw(OnChainWithdraw memory request) internal virtual returns (bytes32 requestId) {
        // Remove request from queue.
        requestId = keccak256(abi.encode(request));
        bool removedFromSet = _withdrawRequests.remove(requestId);
        if (!removedFromSet) revert BoringOnChainQueue__RequestNotFound();
    }
}

// File: src/base/Roles/BoringQueue/BoringOnChainQueueWithTracking.sol


pragma solidity 0.8.21;


contract BoringOnChainQueueWithTracking is BoringOnChainQueue {
    // ========================================= GLOBAL STATE =========================================

    /**
     * @notice Whether or not to track withdraws on chain.
     */
    bool public trackWithdrawsOnChain;

    /**
     * @notice Mapping of request Ids to OnChainWithdraws.
     */
    mapping(bytes32 => OnChainWithdraw) internal onChainWithdraws;

    //============================== ERRORS ===============================

    error BoringOnChainQueueWithTracking__ZeroNonce();

    //============================== EVENTS ===============================

    event TrackWithdrawsOnChainToggled(bool newState);

    //============================== IMMUTABLES ===============================

    constructor(
        address _owner,
        address _auth,
        address payable _boringVault,
        address _accountant,
        bool _trackWithdrawsOnChain
    ) BoringOnChainQueue(_owner, _auth, _boringVault, _accountant) {
        trackWithdrawsOnChain = _trackWithdrawsOnChain;
    }

    //=============================== ADMIN FUNCTIONS ================================

    /**
     * @notice Toggle whether or not to track withdraws on chain.
     * @dev Callable by MULTISIG_ROLE.
     */
    function toggleTrackWithdrawsOnChain() external requiresAuth {
        bool oldState = trackWithdrawsOnChain;
        trackWithdrawsOnChain = !oldState;
        emit TrackWithdrawsOnChainToggled(!oldState);
    }

    //=============================== USER FUNCTIONS ================================

    /**
     * @notice Cancel an on-chain withdraw using the request Id.
     */
    function cancelOnChainWithdrawUsingRequestId(bytes32 requestId)
        external
        requiresAuth
        returns (OnChainWithdraw memory request)
    {
        request = getOnChainWithdraw(requestId);
        _cancelOnChainWithdrawWithUserCheck(request);
    }

    /**
     * @notice Replace an on-chain withdraw using the request Id.
     * @dev Reverts if the request is not mature.
     * @param oldRequestId The request Id to replace.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToDeadline The time in seconds the request is valid for.
     * @return oldRequest The old request.
     * @return newRequestId The new request Id.
     */
    function replaceOnChainWithdrawUsingRequestId(bytes32 oldRequestId, uint16 discount, uint24 secondsToDeadline)
        external
        requiresAuth
        returns (OnChainWithdraw memory oldRequest, bytes32 newRequestId)
    {
        oldRequest = getOnChainWithdraw(oldRequestId);
        (, newRequestId) = _replaceOnChainWithdraw(oldRequest, discount, secondsToDeadline);
    }

    //============================== VIEW FUNCTIONS ===============================

    /**
     * @notice Get all withdraw requests.
     * @dev Includes requests that are not mature, matured, and expired. But does not include requests that have been solved.
     * @dev Does not verify nonce is zero, as you could have not been tracking withdraws for a period of time.
     * @dev If withdraws are made when not tracking, they will show up as empty requests here.
     */
    function getWithdrawRequests()
        external
        view
        returns (bytes32[] memory requestIds, OnChainWithdraw[] memory requests)
    {
        requestIds = getRequestIds();
        uint256 requestsLength = requestIds.length;
        requests = new OnChainWithdraw[](requestsLength);
        for (uint256 i = 0; i < requestsLength; ++i) {
            requests[i] = onChainWithdraws[requestIds[i]];
        }
    }

    /**
     * @notice Get a withdraw request.
     * @dev Does verify nonce is non-zero.
     * @param requestId The request Id.
     * @return request The request.
     */
    function getOnChainWithdraw(bytes32 requestId) public view returns (OnChainWithdraw memory) {
        OnChainWithdraw memory request = onChainWithdraws[requestId];
        if (request.nonce == 0) revert BoringOnChainQueueWithTracking__ZeroNonce();
        return onChainWithdraws[requestId];
    }

    //============================= INTERNAL FUNCTIONS ==============================

    /**
     * @notice Queue an on-chain withdraw.
     * @dev Reverts if the request is already in the queue. Though this should be impossible.
     * @param user The user that made the request.
     * @param assetOut The asset to withdraw.
     * @param amountOfShares The amount of shares to withdraw.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToMaturity The time in seconds it takes for the asset to mature.
     * @param secondsToDeadline The time in seconds the request is valid for.
     * @return requestId The request Id.
     */
    function _queueOnChainWithdraw(
        address user,
        address assetOut,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    ) internal override returns (bytes32 requestId, OnChainWithdraw memory req) {
        (requestId, req) =
            super._queueOnChainWithdraw(user, assetOut, amountOfShares, discount, secondsToMaturity, secondsToDeadline);

        if (trackWithdrawsOnChain) {
            // Save withdraw request on chain.
            onChainWithdraws[requestId] = req;
        }
    }
}
