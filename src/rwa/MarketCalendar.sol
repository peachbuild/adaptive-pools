// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CalendarLib} from "./CalendarLib.sol";
import {SessionLib} from "./SessionLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface ICalendarFeeController {
    function ABSOLUTE_MAX_FEE() external view returns (uint24);
}

/// @notice Calendar storage/evaluation component owned by one immutable hook.
/// @dev Split out to respect BSC's EIP-170 limit; users still use the hook's calendar ABI.
contract MarketCalendar {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    address public immutable controller;
    error NotController();
    error InvalidMaxFee();
    error PoolNotConfigured();

    constructor(address controller_) {
        controller = controller_;
    }
    uint32 public constant DEFAULT_OPEN_SEC = 34200;
    uint32 public constant DEFAULT_CLOSE_SEC = 57600;
    uint32 public constant MIN_SESSION_LENGTH = 1 hours;
    uint32 public constant MAX_SESSION_LENGTH = 12 hours;
    uint32 public constant MAX_SESSION_SHIFT = 30 minutes;
    uint32 public constant MIN_EARLY_CLOSE_LENGTH = 3 hours;
    uint256 public constant MAX_DAY_OVERRIDES = 10;
    enum DayOverride {
        NONE,
        FORCE_CLOSED,
        FORCE_OPEN
    }
    mapping(PoolId => CalendarLib.Calendar) private calendars;
    mapping(PoolId => SessionLib.FloorConfig) private floorConfigs;
    error InvalidDayOverride();
    error InvalidSessionHours();
    error TooManyDayOverrides(uint256 count);
    error DstModeDisagreesWithClock();

    function _authorizeCalendar(PoolId) internal view {
        if (msg.sender != controller) revert NotController();
    }

    function openSec(PoolId id) public view returns (uint32 o) {
        (o,) = CalendarLib.hoursOf(calendars[id]);
    }

    function closeSec(PoolId id) public view returns (uint32 e) {
        (, e) = CalendarLib.hoursOf(calendars[id]);
    }

    function dstMode(PoolId id) public view returns (SessionLib.DstMode) {
        return calendars[id].mode;
    }

    function earlyClose(PoolId id, uint256 y, uint256 m, uint256 d) external view returns (uint32) {
        return calendars[id].early[y * 10000 + m * 100 + d];
    }

    function dayOverride(PoolId id, uint256 y, uint256 m, uint256 d) public view returns (DayOverride) {
        if (d == 0 || d > 31) revert InvalidDayOverride();
        return DayOverride((calendars[id].overrides[y * 100 + m] >> ((d - 1) * 2)) & 3);
    }

    function sessionAt(PoolId id, uint256 timestamp) public view returns (SessionLib.Session) {
        return CalendarLib.sessionAt(calendars[id], timestamp);
    }

    function feeFloorAt(PoolId id, SessionLib.FloorConfig memory cfg, uint256 timestamp) public view returns (uint256) {
        return CalendarLib.feeFloorAt(calendars[id], cfg, timestamp);
    }

    function floorConfig(PoolId id) external view returns (SessionLib.FloorConfig memory) {
        if (floorConfigs[id].openFloor == 0) revert PoolNotConfigured();
        return floorConfigs[id];
    }

    function poolFeeAt(PoolId id, uint256 timestamp) external view returns (uint256) {
        if (floorConfigs[id].openFloor == 0) revert PoolNotConfigured();
        return CalendarLib.feeFloorAt(calendars[id], floorConfigs[id], timestamp);
    }

    function setPoolConfig(PoolKey calldata key, SessionLib.FloorConfig calldata cfg, uint24 cap)
        external
        returns (uint24 floor)
    {
        PoolId id = key.toId();
        _authorizeCalendar(id);
        if (!key.fee.isDynamicFee() || cap < 100 || cap > ICalendarFeeController(controller).ABSOLUTE_MAX_FEE()) {
            revert InvalidMaxFee();
        }
        validateFloorConfig(cfg, cap);
        floorConfigs[id] = cfg;
        floor = cfg.openFloor;
        if (cfg.overnightFloor < floor) floor = cfg.overnightFloor;
        if (cfg.closedFloor < floor) floor = cfg.closedFloor;
    }

    function setSessionHours(PoolId id, uint32 o, uint32 e) external {
        _authorizeCalendar(id);
        if (
            o < DEFAULT_OPEN_SEC - MAX_SESSION_SHIFT || o > DEFAULT_OPEN_SEC + MAX_SESSION_SHIFT
                || e < DEFAULT_CLOSE_SEC - MAX_SESSION_SHIFT || e > DEFAULT_CLOSE_SEC + MAX_SESSION_SHIFT || e <= o
                || e - o < MIN_SESSION_LENGTH || e - o > MAX_SESSION_LENGTH
        ) revert InvalidSessionHours();
        calendars[id].open = o;
        calendars[id].close = e;
    }

    function setDstMode(PoolId id, SessionLib.DstMode mode) external {
        _authorizeCalendar(id);
        if (
            mode != SessionLib.DstMode.AUTO
                && CalendarLib.utcOffset(mode, block.timestamp)
                    != CalendarLib.utcOffset(SessionLib.DstMode.AUTO, block.timestamp)
        ) revert DstModeDisagreesWithClock();
        calendars[id].mode = mode;
    }

    function setDayOverrides(PoolId id, uint256 yearMonth, uint64 packed) external {
        _authorizeCalendar(id);
        uint256 y = yearMonth / 100;
        uint256 m = yearMonth % 100;
        if (y < 1970 || m == 0 || m > 12) revert InvalidDayOverride();
        uint256 n = CalendarLib.daysInMonth(y, m);
        if (packed >> (n * 2) != 0) revert InvalidDayOverride();
        uint256 count;
        for (uint256 i; i < n; i++) {
            uint256 mark = (packed >> (i * 2)) & 3;
            if (mark == 3) revert InvalidDayOverride();
            if (mark != 0) count++;
        }
        if (count > MAX_DAY_OVERRIDES) revert TooManyDayOverrides(count);
        calendars[id].overrides[yearMonth] = packed;
    }

    function setEarlyClose(PoolId id, uint256 y, uint256 m, uint256 d, uint32 e) external {
        _authorizeCalendar(id);
        if (y < 1970 || m == 0 || m > 12 || d == 0 || d > CalendarLib.daysInMonth(y, m)) revert InvalidDayOverride();
        uint32 o = openSec(id);
        if (e != 0 && (e <= o || e > closeSec(id) || e - o < MIN_EARLY_CLOSE_LENGTH)) revert InvalidSessionHours();
        calendars[id].early[y * 10000 + m * 100 + d] = e;
    }

    error InvalidFloorConfig();

    function validateFloorConfig(SessionLib.FloorConfig calldata c, uint24 cap) public pure {
        if (
            c.openFloor < 100 || c.overnightFloor < 100 || c.closedFloor < 100 || c.openFloor > cap
                || c.overnightFloor > cap || c.closedFloor > cap || c.spikeMult > 20 || c.descentWindow > 6 hours
                || (c.descentWindow == 0 && (c.spikeMult != 0 || c.closedSpike != 0))
                || (c.descentWindow != 0
                    && (uint256(c.overnightFloor) * c.spikeMult <= c.openFloor || c.closedSpike <= c.openFloor))
                || c.closeFloor > cap || (c.closeFloor == 0 && (c.closeBefore != 0 || c.closeAfter != 0))
                || (c.closeFloor != 0
                    && (c.closeFloor < c.openFloor
                        || (c.closeBefore == 0 && c.closeAfter == 0)
                        || c.closeBefore > 6 hours
                        || c.closeAfter > 6 hours))
        ) revert InvalidFloorConfig();
    }
}
