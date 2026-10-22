// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RampETHTest} from "./RampETH.t.sol";
import {RwaRampTest} from "./RwaRamp.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

abstract contract AuditRam2RouteComparison is Test {
    using PoolIdLibrary for PoolKey;

    struct RouteResult {
        uint256 gross0;
        uint256 gross1;
        uint256 growth0;
        uint256 growth1;
        uint160 price;
        int24 tick;
    }

    function sequence(
        IPoolManager manager_,
        PoolSwapTest router,
        Ramp hook,
        PoolKey memory k,
        uint256 id,
        bool frequent
    ) private returns (RouteResult memory r) {
        for (uint256 i; i < 100; ++i) {
            bool direction = i % 2 == 0;
            uint256 value = direction && k.currency0.isAddressZero() ? 1e12 : 0;
            router.swap{value: value}(
                k,
                SwapParams(
                    direction, -int256(1e12), direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            if (frequent) hook.transfer(address(this), id, 1);
        }
        hook.transfer(address(this), id, 1);
        r.gross0 = manager_.balanceOf(address(hook), k.currency0.toId());
        r.gross1 = manager_.balanceOf(address(hook), k.currency1.toId());
        (r.growth0, r.growth1) = StateLibrary.getFeeGrowthInside(manager_, k.toId(), -120, 120);
        (r.price, r.tick,,) = StateLibrary.getSlot0(manager_, k.toId());
        assertEq(hook.rangeState(id).totalShares, 1e18);
    }

    function compareRoute(IPoolManager manager_, PoolSwapTest router, Ramp hook, PoolKey memory k) internal {
        uint256 id = hook.rangeId(k.toId(), -120, 120);
        uint256 checkpoint = vm.snapshotState();
        RouteResult memory single = sequence(manager_, router, hook, k, id, false);
        assertTrue(vm.revertToState(checkpoint));
        RouteResult memory frequent = sequence(manager_, router, hook, k, id, true);
        assertEq(frequent.price, single.price);
        assertEq(frequent.tick, single.tick);
        assertEq(frequent.growth0, single.growth0);
        assertEq(frequent.growth1, single.growth1);
        assertLe(frequent.gross0, single.gross0);
        assertLe(frequent.gross1, single.gross1);
        assertLe(single.gross0 - frequent.gross0, 49, "50 fee-bearing syncs per currency");
        assertLe(single.gross1 - frequent.gross1, 49);
        emit log_named_uint("route concentrated gross0", single.gross0);
        emit log_named_uint("route concentrated gross1", single.gross1);
        emit log_named_uint("route loss0", single.gross0 - frequent.gross0);
        emit log_named_uint("route loss1", single.gross1 - frequent.gross1);
    }
}

contract AuditRam2NativeTest is RampETHTest, AuditRam2RouteComparison {
    function test_RAM2_nativeRouteRoundingComparison() public {
        PoolKey memory k = _key();
        manager.initialize(k, Constants.SQRT_PRICE_1_1);
        ramp.deposit{value: 1 ether}(k, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        stable.approve(address(swapRouter), type(uint256).max);
        compareRoute(manager, swapRouter, Ramp(address(ramp)), k);
    }
}

contract AuditRam2RwaTest is RwaRampTest, AuditRam2RouteComparison {
    using PoolIdLibrary for PoolKey;

    function test_RAM2_rwaOpenOvernightClosedRoundingComparison() public {
        vm.warp(TUESDAY_OPEN + 10 minutes);
        PoolKey memory k = _key();
        manager.initialize(k, Constants.SQRT_PRICE_1_1);
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        stock.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        uint256 checkpoint = vm.snapshotState();
        uint256[3] memory times =
            [TUESDAY_OPEN + 10 minutes, TUESDAY_OPEN + 7 hours + 10 minutes, TUESDAY_OPEN + 4 days];
        uint24[3] memory fees = [uint24(100), 300, 700];
        for (uint256 i; i < times.length; ++i) {
            assertTrue(vm.revertToState(checkpoint));
            vm.warp(times[i]);
            assertEq(ramp.currentFee(k.toId(), true), fees[i]);
            emit log_named_uint("RWA fee pips", fees[i]);
            compareRoute(manager, swapRouter, Ramp(address(ramp)), k);
        }
    }
}
