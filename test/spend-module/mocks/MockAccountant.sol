// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Stand-in for `AccountantWithRateProviders`, matching the packed `accountantState`
 *         tuple layout the spend module decodes.
 * @dev Only the four fields the module reads are meaningful (`exchangeRate`,
 *      `lastUpdateTimestamp`, `isPaused`, plus `decimals`/`vault` at construction); the rest are
 *      present so the ABI tuple lines up with the real contract.
 */
contract MockAccountant {
    address public payoutAddress;
    uint96 public highwaterMark;
    uint128 public feesOwedInBase;
    uint128 public totalSharesLastUpdate;
    uint96 public exchangeRate;
    uint16 public allowedExchangeRateChangeUpper = 10_100;
    uint16 public allowedExchangeRateChangeLower = 9_900;
    uint64 public lastUpdateTimestamp;
    bool public isPaused;
    uint24 public minimumUpdateDelayInSeconds = 1_000;
    uint16 public platformFee;
    uint16 public performanceFee;

    uint8 public immutable decimals;
    address public immutable vault;

    /**
     * @dev The asset `exchangeRate` is denominated in. Not always dollar-like: soUSD's base is USDC
     *      (6 decimals, ~$1) while soETH's is WETH (18 decimals, ~$3000).
     */
    address public immutable base;

    constructor(address _vault, uint8 _decimals, uint96 _exchangeRate, address _base) {
        vault = _vault;
        decimals = _decimals;
        exchangeRate = _exchangeRate;
        base = _base;
        lastUpdateTimestamp = uint64(block.timestamp);
    }

    function accountantState()
        external
        view
        returns (address, uint96, uint128, uint128, uint96, uint16, uint16, uint64, bool, uint24, uint16, uint16)
    {
        return (
            payoutAddress,
            highwaterMark,
            feesOwedInBase,
            totalSharesLastUpdate,
            exchangeRate,
            allowedExchangeRateChangeUpper,
            allowedExchangeRateChangeLower,
            lastUpdateTimestamp,
            isPaused,
            minimumUpdateDelayInSeconds,
            platformFee,
            performanceFee
        );
    }

    function getRate() external view returns (uint256) {
        return exchangeRate;
    }

    function setRate(uint96 _exchangeRate) external {
        exchangeRate = _exchangeRate;
        lastUpdateTimestamp = uint64(block.timestamp);
    }

    /// @dev Sets the rate without refreshing `lastUpdateTimestamp`, to test staleness handling.
    function setRateWithoutTouchingTimestamp(uint96 _exchangeRate) external {
        exchangeRate = _exchangeRate;
    }

    function setLastUpdateTimestamp(uint64 _lastUpdateTimestamp) external {
        lastUpdateTimestamp = _lastUpdateTimestamp;
    }

    function setIsPaused(bool _isPaused) external {
        isPaused = _isPaused;
    }
}
