// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Settable stand-in for a Chainlink aggregator.
 * @dev Covers the four shapes `ChainlinkQuoteAdapter` has to survive, because three of them are
 *      real production states rather than hypotheticals:
 *
 *        - a normal answer;
 *        - a **non-positive** answer, which a feed can return when its aggregator is
 *          misconfigured or deprecated;
 *        - a **stale** answer, which is the ordinary state of a feed whose heartbeat has lapsed;
 *        - a **reverting** feed, which is what a deprecated proxy does.
 *
 *      It also serves as the sequencer uptime feed, where the convention is inverted: `answer` is
 *      0 for up and 1 for down, and `startedAt` is when that status began.
 */
contract MockAggregatorV3 {
    uint8 public decimals;

    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;
    bool internal _reverts;
    /// @dev Returns fewer words than the interface promises, which is the no-code case's shape.
    bool internal _returnsShort;

    constructor(uint8 _decimals, int256 answer_) {
        decimals = _decimals;
        _answer = answer_;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    /// @dev Sets the answer without touching the timestamp, to age a feed deliberately.
    function setAnswerStale(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        _startedAt = startedAt_;
    }

    function setReverts(bool value) external {
        _reverts = value;
    }

    function setReturnsShort(bool value) external {
        _returnsShort = value;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        if (_reverts) revert("feed down");

        if (_returnsShort) {
            assembly {
                // One word where five are promised: the adapter must reject on length, not decode.
                mstore(0, 1)
                return(0, 32)
            }
        }

        return (1, _answer, _startedAt, _updatedAt, 1);
    }
}
