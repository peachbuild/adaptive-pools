// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketCalendar} from "../src/rwa/MarketCalendar.sol";
import {SessionLib} from "../src/rwa/SessionLib.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CalendarParityTest is Test {
    MarketCalendar calendar;

    function setUp() public {
        calendar = new MarketCalendar(address(this));
        for (uint256 i = 3; i < 5; i++) {
            PoolId id = PoolId.wrap(bytes32(i + 1));
            calendar.setDayOverrides(id, 202601, (uint64(1) << 12) | (uint64(2) << 18));
            calendar.setEarlyClose(id, 2026, 1, 9, 46800);
        }
    }

    function config(uint256 profile) internal pure returns (SessionLib.FloorConfig memory c) {
        if (profile == 1) return SessionLib.FloorConfig(800, 500, 250, 0, 0, 0, 0, 0, 0);
        if (profile == 2) return SessionLib.FloorConfig(2500, 2500, 6000, 0, 0, 0, 0, 0, 0);
        c = SessionLib.FloorConfig(1000, 800, 300, 5, 4000, 7200, 2200, 1800, 1800);
        if (profile == 4) c.closeBefore = 21600;
    }

    function test_verifiedFablesCalendarVectors() public view {
        uint256[] memory vectors =
            vm.parseJsonUintArray(vm.readFile("test/fixtures/fables-calendar-vectors.json"), ".vectors");
        assertEq(vectors.length % 4, 0);
        for (uint256 i; i < vectors.length; i += 4) {
            PoolId id = PoolId.wrap(bytes32(vectors[i + 1] + 1));
            assertEq(uint256(calendar.sessionAt(id, vectors[i])), vectors[i + 2], "reference session");
            assertEq(calendar.feeFloorAt(id, config(vectors[i + 1]), vectors[i]), vectors[i + 3], "reference fee");
        }
    }

    function test_calendarWritesRequireOwningHook() public {
        vm.prank(address(0x1234));
        vm.expectRevert(MarketCalendar.NotController.selector);
        calendar.setSessionHours(PoolId.wrap(bytes32(uint256(1))), 34200, 57600);
    }

    function test_staleEarlyCloseRevalidatedAfterMovingOpen() public {
        PoolId id = PoolId.wrap(bytes32(uint256(1)));
        calendar.setEarlyClose(id, 2026, 1, 6, 45000); // 12:30: exactly three hours from default open.
        calendar.setSessionHours(id, 36000, 57600); // Leaves an invalid 2.5h shortened session.
        // 2026-01-06 13:00 EST remains OPEN because invalid early-close falls back to regular close.
        assertEq(uint256(calendar.sessionAt(id, 1767722400)), uint256(SessionLib.Session.OPEN));
    }

    function test_monthDateAndFixedClockValidation() public {
        PoolId id = PoolId.wrap(bytes32(uint256(1)));
        vm.expectRevert(MarketCalendar.InvalidDayOverride.selector);
        calendar.setDayOverrides(id, 202602, uint64(1) << 58);
        vm.expectRevert(MarketCalendar.InvalidDayOverride.selector);
        calendar.setEarlyClose(id, 2026, 2, 29, 46800);
        vm.warp(1767709800);
        vm.expectRevert(MarketCalendar.DstModeDisagreesWithClock.selector);
        calendar.setDstMode(id, SessionLib.DstMode.FIXED_EDT);
        calendar.setDstMode(id, SessionLib.DstMode.FIXED_EST);
        calendar.setDstMode(id, SessionLib.DstMode.AUTO);
    }

    function test_floorValidationAndOverCapOpeningSpike() public {
        SessionLib.FloorConfig memory c = config(0);
        c.closedSpike = 16000; // Legal; the hook resolves against its cap afterwards.
        calendar.validateFloorConfig(c, 8000);
        c.descentWindow = 21600;
        calendar.validateFloorConfig(c, 8000);
        c.descentWindow++;
        vm.expectRevert(MarketCalendar.InvalidFloorConfig.selector);
        calendar.validateFloorConfig(c, 8000);
        c = config(0);
        c.closeFloor = 999;
        vm.expectRevert(MarketCalendar.InvalidFloorConfig.selector);
        calendar.validateFloorConfig(c, 8000);
        c = config(0);
        c.closeFloor = 0;
        vm.expectRevert(MarketCalendar.InvalidFloorConfig.selector);
        calendar.validateFloorConfig(c, 8000);
    }

    function test_allSeventeenProductConfigSamplesValidate() public view {
        uint256[] memory v = vm.parseJsonUintArray(vm.readFile("test/fixtures/product-market-configs.json"), ".values");
        assertEq(v.length, 17 * 12);
        for (uint256 i; i < v.length; i += 12) {
            SessionLib.FloorConfig memory c = SessionLib.FloorConfig(
                uint24(v[i]),
                uint24(v[i + 1]),
                uint24(v[i + 2]),
                uint8(v[i + 3]),
                uint24(v[i + 4]),
                uint32(v[i + 5]),
                uint24(v[i + 6]),
                uint32(v[i + 7]),
                uint32(v[i + 8])
            );
            calendar.validateFloorConfig(c, uint24(v[i + 9]));
            assertLe(v[i + 9], v[i + 10]);
        }
    }
}
