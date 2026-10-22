// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {RwaRampTest} from "./RwaRamp.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {BaseHook} from "../src/hooks/BaseHook.sol";
import {RwaRamp} from "../src/rwa/RwaRamp.sol";
import {MarketCalendar} from "../src/rwa/MarketCalendar.sol";
import {SessionLib} from "../src/rwa/SessionLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract FeeAlignmentTest is RampTest {
    using PoolIdLibrary for PoolKey;

    function test_oneSidedPokePremiumExpiryAndReplacement() public {
        PoolKey memory k = _key();
        PoolId id = k.toId();
        ramp.setPoolAsymmetry(k, 600, true);
        assertEq(ramp.currentFee(id, true), 1300);
        assertEq(ramp.currentFee(id, false), 700);
        ramp.pokeFee(id, 100, 0, 1 hours);
        assertEq(ramp.currentFee(id, true), 650);
        assertEq(ramp.currentFee(id, false), 700);
        ramp.pokeFee(id, 0, 2000, 1 hours);
        assertEq(ramp.currentFee(id, true), 1300);
        assertEq(ramp.currentFee(id, false), 2000);
        vm.warp(block.timestamp + 1 hours);
        assertEq(ramp.currentFee(id, false), 700);
    }

    function test_capBeforeDiscountAndReconfigureDoesNotErasePoke() public {
        PoolKey memory k = _key();
        PoolId id = k.toId();
        ramp.setPoolAsymmetry(k, 5900, true); // raw 6600, capped 6000.
        ramp.pokeFee(id, 100, 100, 72 hours);
        assertEq(ramp.currentFee(id, true), 3000);
        vm.expectRevert(BaseHook.PremiumExceedsFeeBand.selector);
        ramp.setPoolConfig(k, 100, 700, 1000);
        ramp.setPoolAsymmetry(k, 0, true);
        ramp.setPoolConfig(k, 600, 1000, 2000);
        assertEq(ramp.currentFee(id, true), 600); // live poke is clamped to new floor.
        (uint24 side,,) = ramp.pokeOf(id);
        assertEq(side, 100);
        ramp.clearPoke(id);
        assertEq(ramp.currentFee(id, true), 1000);
    }

    function test_constructorAndEmptyPokeBounds() public {
        vm.expectRevert(BaseHook.InvalidMaxFee.selector);
        new Ramp(manager, address(access), 0);
        vm.expectRevert(BaseHook.InvalidMaxFee.selector);
        new Ramp(manager, address(access), 1000001);
        PoolId id = _key().toId();
        vm.expectRevert(BaseHook.EmptyPoke.selector);
        ramp.pokeFee(id, 0, 0, 1);
        vm.expectRevert(BaseHook.InvalidTtl.selector);
        ramp.pokeFee(id, 100, 0, 0);
    }

    function testFuzz_directionalResolverMatchesFormula(
        uint24 rawBase,
        uint24 rawPremium,
        uint24 rawPoke,
        bool direction
    ) public {
        uint24 base = uint24(bound(rawBase, 100, 6000));
        uint24 premium = uint24(bound(rawPremium, 0, 5900));
        uint24 poked = uint24(bound(rawPoke, 100, 6000));
        PoolKey memory k = _key();
        PoolId id = k.toId();
        ramp.setPoolConfig(k, 100, base, 6000);
        ramp.setPoolAsymmetry(k, premium, true);
        ramp.pokeFee(id, poked, poked, 1 hours);
        uint256 autonomous = base + (direction ? uint256(premium) : 0);
        uint256 capped = autonomous > 6000 ? 6000 : autonomous;
        uint256 floor = capped / 2 > 100 ? capped / 2 : 100;
        uint256 expected = poked > floor ? poked : floor;
        assertEq(ramp.currentFee(id, direction), expected);
    }

    function test_realSwapEventCarriesResolvedDirectionalFee() public {
        PoolKey memory k = _key();
        manager.initialize(k, Constants.SQRT_PRICE_1_1);
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        ramp.setPoolAsymmetry(k, 600, true);
        ramp.pokeFee(k.toId(), 100, 0, 1 hours);
        vm.recordLogs();
        swap(k, true, -int256(1e14), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 650);
                found = true;
            }
        }
        assertTrue(found);
    }
}

contract CalendarRoleAlignmentTest is RwaRampTest {
    using PoolIdLibrary for PoolKey;

    function test_calendarRoleIsSeparateFromFeeKeeper() public {
        PoolId id = _key().toId();
        bytes4[] memory fees = new bytes4[](2);
        fees[0] = BaseHook.pokeFee.selector;
        fees[1] = BaseHook.clearPoke.selector;
        access.grantRole(1, keeper, 0);
        access.setTargetFunctionRole(address(ramp), fees, 1);
        vm.prank(keeper);
        vm.expectRevert();
        ramp.setSessionHours(id, 34200, 57600);
        bytes4[] memory calendar = new bytes4[](1);
        calendar[0] = RwaRamp.setSessionHours.selector;
        access.grantRole(2, keeper, 0);
        access.setTargetFunctionRole(address(ramp), calendar, 2);
        vm.prank(keeper);
        ramp.setSessionHours(id, 34200, 57600);
        SessionLib.FloorConfig memory cfg = ramp.floorConfig(id);
        vm.prank(keeper);
        vm.expectRevert();
        ramp.setPoolConfig(_key(), cfg, 2000);
        MarketCalendar component = ramp.marketCalendar();
        vm.prank(keeper);
        vm.expectRevert(MarketCalendar.NotController.selector);
        component.setSessionHours(id, 34200, 57600);
    }

    function test_poolCalendarIsolationAndHookEvent() public {
        PoolKey memory second = _key();
        second.tickSpacing = 20;
        SessionLib.FloorConfig memory c = ramp.floorConfig(_key().toId());
        ramp.setPoolConfig(second, c, 2000);
        vm.recordLogs(); // Jan6 closed.
        ramp.setDayOverrides(_key().toId(), 202601, uint64(1) << 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(ramp));
        assertEq(logs[0].topics[0], keccak256("DayOverridesSet(bytes32,uint256,uint64)"));
        assertEq(uint256(ramp.sessionAt(_key().toId(), TUESDAY_OPEN)), 2);
        assertEq(uint256(ramp.sessionAt(second.toId(), TUESDAY_OPEN)), 0);
    }

    function test_calendarFacadePreservesReferenceReadAbi() public {
        PoolId id = _key().toId();
        MarketCalendar component = ramp.marketCalendar();
        ramp.setEarlyClose(id, 2026, 1, 6, 46800);
        assertEq(ramp.openSec(id), component.openSec(id));
        assertEq(ramp.closeSec(id), component.closeSec(id));
        assertEq(uint256(ramp.dstMode(id)), uint256(component.dstMode(id)));
        assertEq(ramp.earlyClose(id, 2026, 1, 6), component.earlyClose(id, 2026, 1, 6));
        assertEq(uint256(ramp.dayOverride(id, 2026, 1, 6)), uint256(component.dayOverride(id, 2026, 1, 6)));
        SessionLib.FloorConfig memory cfg = ramp.floorConfig(id);
        assertEq(ramp.feeFloorAt(id, cfg, TUESDAY_OPEN), component.feeFloorAt(id, cfg, TUESDAY_OPEN));
    }
}
