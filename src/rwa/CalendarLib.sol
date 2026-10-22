// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SessionLib} from "./SessionLib.sol";

/// @notice Per-pool calendar and fee evaluation. Date tables are the reference's 2026-2030 schedule.
library CalendarLib {
    error InvalidTimestamp(uint256 timestamp);
    uint32 internal constant SECONDS_PER_DAY = 86_400;
    uint32 internal constant EST_OFFSET = 5 hours;
    uint32 internal constant EDT_OFFSET = 4 hours;

    struct Calendar {
        uint32 open;
        uint32 close;
        SessionLib.DstMode mode;
        mapping(uint256 => uint64) overrides;
        mapping(uint256 => uint32) early;
    }

    function hoursOf(Calendar storage c) internal view returns (uint32 o, uint32 e) {
        return c.open == 0 ? (uint32(34200), uint32(57600)) : (c.open, c.close);
    }

    function fullyClosed(Calendar storage c, uint256 dayIndex) internal view returns (bool) {
        (uint256 y, uint256 m, uint256 d) = _civilFromDays(dayIndex);
        uint256 mark = (c.overrides[y * 100 + m] >> ((d - 1) * 2)) & 3;
        if (mark == 2) return false;
        uint256 weekday = (dayIndex + 4) % 7;
        return mark == 1 || weekday == 0 || weekday == 6 || holiday(y, m * 100 + d);
    }

    function context(Calendar storage c, uint256 timestamp)
        internal
        view
        returns (uint256 dayIndex, uint256 second, uint32 o, uint32 e)
    {
        uint256 local = _localTimestamp(c.mode, timestamp);
        dayIndex = local / SECONDS_PER_DAY;
        second = local % SECONDS_PER_DAY;
        (o, e) = hoursOf(c);
        (uint256 y, uint256 m, uint256 d) = _civilFromDays(dayIndex);
        uint32 halfDay = c.early[y * 10000 + m * 100 + d];
        // Revalidate against current hours: an earlier valid override may have become stale.
        if (halfDay > o && halfDay <= e && halfDay - o >= 3 hours) e = halfDay;
    }

    function classify(Calendar storage c, uint256 dayIndex, uint256 second, uint32 o, uint32 e)
        internal
        view
        returns (SessionLib.Session)
    {
        if (((dayIndex + 4) % 7 == 5 && second >= e) || fullyClosed(c, dayIndex)) return SessionLib.Session.CLOSED;
        return second >= o && second < e ? SessionLib.Session.OPEN : SessionLib.Session.OVERNIGHT;
    }

    function sessionAt(Calendar storage c, uint256 timestamp) internal view returns (SessionLib.Session) {
        (uint256 dayIndex, uint256 second, uint32 o, uint32 e) = context(c, timestamp);
        return classify(c, dayIndex, second, o, e);
    }

    function feeFloorAt(Calendar storage c, SessionLib.FloorConfig memory cfg, uint256 timestamp)
        internal
        view
        returns (uint256 fee)
    {
        (uint256 dayIndex, uint256 second, uint32 o, uint32 e) = context(c, timestamp);
        SessionLib.Session session = classify(c, dayIndex, second, o, e);
        if (session == SessionLib.Session.CLOSED) {
            fee = cfg.closedFloor;
        } else if (session == SessionLib.Session.OVERNIGHT) {
            fee = cfg.overnightFloor;
        } else {
            uint256 peak = dayIndex != 0 && fullyClosed(c, dayIndex - 1)
                ? cfg.closedSpike
                : uint256(cfg.overnightFloor) * cfg.spikeMult;
            fee = SessionLib.descending(peak, cfg.openFloor, second - o, cfg.descentWindow);
        }
        // Friday post-close is CLOSED, but that trading day's closing hold still applies.
        if (cfg.closeFloor != 0 && second >= o && !fullyClosed(c, dayIndex)) {
            uint256 window = cfg.closeBefore;
            if (window > e - o) window = e - o;
            uint256 ramp;
            if (window != 0 && second >= e - window && second <= e) {
                ramp = cfg.closeFloor <= cfg.openFloor
                    ? cfg.openFloor
                    : SessionLib.ascending(cfg.openFloor, cfg.closeFloor, second - (e - window), window);
            } else if (second >= e && second < uint256(e) + cfg.closeAfter) {
                ramp = cfg.closeFloor;
            }
            if (ramp > fee) fee = ramp;
        }
    }

    function holiday(uint256 year, uint256 md) internal pure returns (bool) {
        // Calendar facts, encoded as sorted four-digit month/day entries (16 bits each).
        uint256 dates;
        if (year == 2026) dates = 0x000065007700d80193020d026b02bf038b046604c9;
        else if (year == 2027) dates = 0x000065007600d701460213026a02c1038a046504c8;
        else if (year == 2028) dates = 0x00007500dd019e0211026b02c00388046304c9;
        else if (year == 2029) dates = 0x000065007300db014a0210026b02c00387046204c9;
        else if (year == 2030) dates = 0x000065007900da01a3020f026b02c00386046804c9;
        while (dates != 0) {
            if (dates & 0xffff == md) return true;
            dates >>= 16;
        }
        return false;
    }

    function localDateTime(SessionLib.DstMode mode, uint256 timestamp)
        internal
        pure
        returns (uint256 year, uint256 month, uint256 day, uint256 secondOfDay, uint256 weekday)
    {
        uint256 localTimestamp = _localTimestamp(mode, timestamp);
        uint256 daysSinceEpoch = localTimestamp / SECONDS_PER_DAY;
        (year, month, day) = _civilFromDays(daysSinceEpoch);
        secondOfDay = localTimestamp % SECONDS_PER_DAY;
        weekday = (daysSinceEpoch + 4) % 7;
    }

    /// @dev Literal Unix seconds; zero is not a sentinel for the current time.
    function _localTimestamp(SessionLib.DstMode mode, uint256 timestamp) private pure returns (uint256) {
        uint256 offset = utcOffset(mode, timestamp);
        if (timestamp < offset) revert InvalidTimestamp(timestamp);
        return timestamp - offset;
    }

    function daysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 2) {
            return _isLeapYear(year) ? 29 : 28;
        }
        return month == 4 || month == 6 || month == 9 || month == 11 ? 30 : 31;
    }

    function utcOffset(SessionLib.DstMode mode, uint256 timestamp) internal pure returns (uint256) {
        if (mode == SessionLib.DstMode.FIXED_EST) {
            return EST_OFFSET;
        }
        if (mode == SessionLib.DstMode.FIXED_EDT) {
            return EDT_OFFSET;
        }

        (uint256 year,,) = _civilFromDays(timestamp / SECONDS_PER_DAY);
        uint256 marchSunday = _firstSunday(year, 3) + 7;
        uint256 novemberSunday = _firstSunday(year, 11);
        // Match the reference calendar: AUTO changes on the UTC date of the DST Sunday.
        uint256 startsAt = _timestampForDate(year, 3, marchSunday, 0);
        uint256 endsAt = _timestampForDate(year, 11, novemberSunday, 0);
        return timestamp >= startsAt && timestamp < endsAt ? EDT_OFFSET : EST_OFFSET;
    }

    function _firstSunday(uint256 year, uint256 month) private pure returns (uint256) {
        uint256 weekday = (_daysFromCivil(year, month, 1) + 4) % 7;
        return 1 + (7 - weekday) % 7;
    }

    function _timestampForDate(uint256 year, uint256 month, uint256 day, uint256 secondOfDay)
        private
        pure
        returns (uint256)
    {
        return _daysFromCivil(year, month, day) * SECONDS_PER_DAY + secondOfDay;
    }

    function _daysFromCivil(uint256 year, uint256 month, uint256 day) private pure returns (uint256) {
        uint256 adjustedYear = month <= 2 ? year - 1 : year;
        uint256 era = adjustedYear / 400;
        uint256 yoe = adjustedYear - era * 400;
        uint256 adjustedMonth = month > 2 ? month - 3 : month + 9;
        uint256 doy = (153 * adjustedMonth + 2) / 5 + day - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    function _civilFromDays(uint256 daysSinceEpoch) private pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 z = daysSinceEpoch + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
        year = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 monthPrime = (5 * doy + 2) / 153;
        day = doy - (153 * monthPrime + 2) / 5 + 1;
        month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
        if (month <= 2) {
            year++;
        }
    }

    function _isLeapYear(uint256 year) private pure returns (bool) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }
}
