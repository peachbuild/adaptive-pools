// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CalendarLib} from "../src/rwa/CalendarLib.sol";
import {MarketCalendar} from "../src/rwa/MarketCalendar.sol";
import {SessionLib} from "../src/rwa/SessionLib.sol";
import {RwaRampTest} from "./RwaRamp.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract CalendarTimestampHarness {
    CalendarLib.Calendar private calendar;

    function setMode(SessionLib.DstMode mode) external {
        calendar.mode = mode;
    }

    function context(uint256 timestamp) external view returns (uint256, uint256, uint32, uint32) {
        return CalendarLib.context(calendar, timestamp);
    }

    function localDateTime(SessionLib.DstMode mode, uint256 timestamp)
        external
        pure
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        return CalendarLib.localDateTime(mode, timestamp);
    }
}

contract AuditCli1CalendarTest is Test {
    CalendarTimestampHarness private harness;
    MarketCalendar private calendar;
    PoolId private constant ID = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        harness = new CalendarTimestampHarness();
        calendar = new MarketCalendar(address(this));
    }

    function test_CLI1_fixedEstLowerBoundary() public {
        vm.warp(1_767_709_800); // January 2026: fixed EST is compatible with current AUTO clock.
        _boundaries(SessionLib.DstMode.FIXED_EST, 18_000);
    }

    function test_CLI1_fixedEdtLowerBoundary() public {
        vm.warp(1_782_864_000); // July 2026: fixed EDT is compatible with current AUTO clock.
        _boundaries(SessionLib.DstMode.FIXED_EDT, 14_400);
    }

    function test_CLI1_autoUsesQueriedEpochOffsetRatherThanCurrentSummerClock() public {
        vm.warp(1_782_864_000);
        _boundaries(SessionLib.DstMode.AUTO, 18_000);
    }

    function _boundaries(SessionLib.DstMode mode, uint256 offset) private {
        harness.setMode(mode);
        calendar.setDstMode(ID, mode);
        SessionLib.FloorConfig memory cfg = SessionLib.FloorConfig(100, 300, 700, 0, 0, 0, 0, 0, 0);
        uint256[7] memory timestamps = [uint256(0), 14_399, 14_400, 14_401, 17_999, 18_000, 18_001];
        for (uint256 i; i < timestamps.length; ++i) {
            uint256 timestamp = timestamps[i];
            if (timestamp < offset) {
                bytes memory errorData = abi.encodeWithSelector(CalendarLib.InvalidTimestamp.selector, timestamp);
                vm.expectRevert(errorData);
                harness.context(timestamp);
                vm.expectRevert(errorData);
                harness.localDateTime(mode, timestamp);
                vm.expectRevert(errorData);
                calendar.sessionAt(ID, timestamp);
                vm.expectRevert(errorData);
                calendar.feeFloorAt(ID, cfg, timestamp);
            } else {
                (uint256 dayIndex, uint256 second, uint32 open, uint32 close) = harness.context(timestamp);
                assertEq(dayIndex, 0);
                assertEq(second, timestamp - offset);
                assertEq(open, 34_200);
                assertEq(close, 57_600);
                (uint256 y, uint256 m, uint256 d, uint256 localSecond, uint256 weekday) =
                    harness.localDateTime(mode, timestamp);
                assertEq(y, 1970);
                assertEq(m, 1);
                assertEq(d, 1);
                assertEq(localSecond, timestamp - offset);
                assertEq(weekday, 4); // Thursday, January 1, 1970.
                assertEq(uint8(calendar.sessionAt(ID, timestamp)), uint8(SessionLib.Session.OVERNIGHT));
                assertEq(calendar.feeFloorAt(ID, cfg, timestamp), 300);
            }
        }
    }
}

contract AuditCli1RwaTest is RwaRampTest {
    using PoolIdLibrary for PoolKey;

    function test_CLI1_forwardedQueryErrorDoesNotChangeLiveSwapFeeOrLedger() public {
        vm.warp(TUESDAY_OPEN);
        PoolKey memory key = _key();
        PoolId pool = key.toId();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        uint256 id = ramp.rangeId(pool, -120, 120);
        bytes32 beforeState = keccak256(abi.encode(ramp.rangeState(id), ramp.userPosition(id, address(this))));
        SessionLib.FloorConfig memory cfg = ramp.floorConfig(pool);
        uint256[5] memory invalid = [uint256(0), 14_399, 14_400, 14_401, 17_999];
        for (uint256 i; i < invalid.length; ++i) {
            bytes memory errorData = abi.encodeWithSelector(CalendarLib.InvalidTimestamp.selector, invalid[i]);
            vm.expectRevert(errorData);
            ramp.sessionAt(pool, invalid[i]);
            vm.expectRevert(errorData);
            ramp.feeFloorAt(pool, cfg, invalid[i]);
        }
        assertEq(uint8(ramp.sessionAt(pool, 18_000)), uint8(SessionLib.Session.OVERNIGHT));
        assertEq(ramp.feeFloorAt(pool, cfg, 18_000), 300);
        assertEq(uint8(ramp.sessionAt(pool, 18_001)), uint8(SessionLib.Session.OVERNIGHT));
        assertEq(ramp.feeFloorAt(pool, cfg, 18_001), 300);
        assertEq(keccak256(abi.encode(ramp.rangeState(id), ramp.userPosition(id, address(this)))), beforeState);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        assertEq(block.timestamp, TUESDAY_OPEN);
        assertEq(ramp.currentFee(pool, true), 900);

        stock.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        vm.recordLogs();
        swap(key, true, -int256(1e14), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 900, "actual swap uses current block time after boundary queries");
                found = true;
            }
        }
        assertTrue(found);
    }
}
