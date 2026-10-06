// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Calendar helpers for timezone-aware daily and monthly spending windows.
 * @dev Adapted from ether.fi's cash-v3 `TimeLib`. Windows roll over at local midnight so a
 *      user's "daily limit" matches the day they experience, not a UTC day.
 */
library TimeLib {
    /**
     * @notice Timestamp of the next local midnight strictly after `timestamp`.
     * @param timestamp Reference UTC timestamp
     * @param timezoneOffset Offset from UTC in seconds (may be negative)
     */
    function getStartOfNextDay(uint256 timestamp, int256 timezoneOffset) internal pure returns (uint64) {
        int256 adjustedTimestamp = int256(timestamp) + timezoneOffset;
        uint256 currentDay = uint256(adjustedTimestamp / 1 days);
        uint256 startOfNextDay = (currentDay + 1) * 1 days;

        return uint64(uint256(int256(startOfNextDay) - timezoneOffset));
    }

    /**
     * @notice Timestamp of the first local midnight of the next calendar month.
     * @param timestamp Reference UTC timestamp
     * @param timezoneOffset Offset from UTC in seconds (may be negative)
     */
    function getStartOfNextMonth(uint256 timestamp, int256 timezoneOffset) internal pure returns (uint64) {
        int256 adjustedTimestamp = int256(timestamp) + timezoneOffset;
        (uint16 year, uint8 month,) = _daysToDate(uint256(adjustedTimestamp) / 1 days);

        month += 1;
        if (month > 12) {
            month = 1;
            year += 1;
        }

        uint256 startOfNextMonth = _daysFromDate(year, month, 1) * 1 days;

        return uint64(uint256(int256(startOfNextMonth) - timezoneOffset));
    }

    /// @dev Days since the Unix epoch for a proleptic Gregorian date.
    function _daysFromDate(uint16 year, uint8 month, uint8 day) internal pure returns (uint256) {
        int256 _year = int256(uint256(year));
        int256 _month = int256(uint256(month));
        int256 _day = int256(uint256(day));

        int256 __days = _day - 32_075 + (1461 * (_year + 4800 + (_month - 14) / 12)) / 4
            + (367 * (_month - 2 - ((_month - 14) / 12) * 12)) / 12
            - (3 * ((_year + 4900 + (_month - 14) / 12) / 100)) / 4 - 2_440_588;

        return uint256(__days);
    }

    /// @dev Inverse of `_daysFromDate`.
    function _daysToDate(uint256 _days) internal pure returns (uint16 year, uint8 month, uint8 day) {
        int256 __days = int256(_days);

        int256 L = __days + 68_569 + 2_440_588;
        int256 N = (4 * L) / 146_097;
        L = L - (146_097 * N + 3) / 4;
        int256 _year = (4000 * (L + 1)) / 1_461_001;
        L = L - (1461 * _year) / 4 + 31;
        int256 _month = (80 * L) / 2447;
        int256 _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint16(uint256(_year));
        month = uint8(uint256(_month));
        day = uint8(uint256(_day));
    }
}
