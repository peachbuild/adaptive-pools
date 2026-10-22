// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Local Arc-precision sensitivity tests; no production token interactions.
contract AuditRam2ArcTest is RampTest {
    using PoolIdLibrary for PoolKey;

    uint256 private constant Q128 = 1 << 128;
    uint128 private constant TOTAL_LIQUIDITY = 1e11;
    bytes32 private constant DIRECT_SALT = bytes32("independent Arc LP");
    address private holderA = makeAddr("Arc dust A");
    address private holderB = makeAddr("Arc dust B");
    PoolKey private k;
    uint256 private id;
    int24 private lower;
    int24 private upper;
    uint128 private managed;
    uint128 private independent;
    bool private baseFirst;
    address private holder;

    struct Result {
        uint256 gross0;
        uint256 gross1;
        uint256 fraction0;
        uint256 fraction1;
        uint256 growth0;
        uint256 growth1;
        uint160 price;
        int24 tick;
        uint256 effective0;
        uint256 effective1;
        uint256 syncCalls;
        uint256 gasTotal;
        uint256 directGrowth0;
        uint256 directGrowth1;
    }

    function prepare(uint256 shareDenominator) private {
        wbnb = new MockERC20("Arc precision base", "CIRBTC", 8);
        stable = new MockERC20("Arc precision quote", "USDC", 6);
        wbnb.mint(address(this), 1e30);
        stable.mint(address(this), 1e30);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        wbnb.approve(address(modifyLiquidityRouter), type(uint256).max);
        stable.approve(address(modifyLiquidityRouter), type(uint256).max);
        k = _key();
        ramp.setPoolConfig(k, 100, 700, 6000);
        assertEq(ramp.currentFee(k.toId(), true), 700);
        assertEq(ramp.currentFee(k.toId(), false), 700);
        baseFirst = Currency.unwrap(k.currency0) == address(wbnb);
        // Human initial price = 100,000 USDC/CIRBTC. currency ordering is explicit.
        uint160 price = uint160(Math.sqrt(baseFirst ? (uint256(1000) << 192) : (uint256(1) << 192) / 1000));
        int24 center = (TickMath.getTickAtSqrtPrice(price) / 10) * 10;
        lower = center - 6000;
        upper = center + 6000;
        managed = uint128(uint256(TOTAL_LIQUIDITY) / shareDenominator);
        independent = TOTAL_LIQUIDITY - managed;
        manager.initialize(k, price);
        ramp.deposit(k, lower, upper, managed, type(uint128).max, type(uint128).max, block.timestamp);
        if (independent != 0) {
            modifyLiquidityRouter.modifyLiquidity(
                k, ModifyLiquidityParams(lower, upper, int256(uint256(independent)), DIRECT_SALT), ""
            );
        }
        assertEq(StateLibrary.getLiquidity(manager, k.toId()), TOTAL_LIQUIDITY);
        id = ramp.rangeId(k.toId(), lower, upper);
        ramp.transfer(holderA, id, 1);
        holder = holderA;
    }

    function sync(Result memory r, uint256 route) private {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            StateLibrary.getPositionInfo(manager, k.toId(), address(ramp), lower, upper, bytes32(id));
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthInside(manager, k.toId(), lower, upper);
        uint256 delta0 = growth0 - last0;
        uint256 delta1 = growth1 - last1;
        r.fraction0 += mulmod(delta0, liquidity, Q128);
        r.fraction1 += mulmod(delta1, liquidity, Q128);
        if (delta0 != 0) r.effective0++;
        if (delta1 != 0) r.effective1++;
        uint256 before0 = manager.balanceOf(address(ramp), k.currency0.toId());
        uint256 before1 = manager.balanceOf(address(ramp), k.currency1.toId());
        vm.prank(holder);
        uint256 gasBefore = gasleft();
        if (route == 0) {
            ramp.transfer(holder, id, 1);
        } else if (route == 1) {
            ramp.claimFees(k, lower, upper, holder, 0);
        } else {
            address next = holder == holderA ? holderB : holderA;
            ramp.transfer(next, id, 1);
            holder = next;
        }
        r.gasTotal += gasBefore - gasleft();
        r.syncCalls++;
        assertEq(
            manager.balanceOf(address(ramp), k.currency0.toId()) - before0, FullMath.mulDiv(delta0, liquidity, Q128)
        );
        assertEq(
            manager.balanceOf(address(ramp), k.currency1.toId()) - before1, FullMath.mulDiv(delta1, liquidity, Q128)
        );
        assertEq(ramp.balanceOf(holderA, id) + ramp.balanceOf(holderB, id), 1);
        // One-liquidity-unit callers have no integer payout in this matrix, so claims cannot hide gross collection.
        assertEq(wbnb.balanceOf(holderA) + wbnb.balanceOf(holderB), 0);
        assertEq(stable.balanceOf(holderA) + stable.balanceOf(holderB), 0);
    }

    function run(uint256 notionalUsdc, uint256 interval, uint256 route) private returns (Result memory r) {
        for (uint256 i; i < 1000; ++i) {
            bool inputBase = i % 2 == 0;
            // Initial-price notional: $1/$10/$100/$1,000; no claim about actual production volume distribution.
            uint256 amount = inputBase ? notionalUsdc * 1000 : notionalUsdc * 1e6;
            swap(k, inputBase == baseFirst, -int256(amount), "");
            assertEq(StateLibrary.getLiquidity(manager, k.toId()), TOTAL_LIQUIDITY, "both positions remain in range");
            if (interval != 0 && (i + 1) % interval == 0) sync(r, route);
        }
        // Same final collection method in every branch; may have no new growth after the last trigger.
        sync(r, 0);
        r.gross0 = manager.balanceOf(address(ramp), k.currency0.toId());
        r.gross1 = manager.balanceOf(address(ramp), k.currency1.toId());
        (r.growth0, r.growth1) = StateLibrary.getFeeGrowthInside(manager, k.toId(), lower, upper);
        (r.price, r.tick,,) = StateLibrary.getSlot0(manager, k.toId());
        (uint128 finalManaged,,) =
            StateLibrary.getPositionInfo(manager, k.toId(), address(ramp), lower, upper, bytes32(id));
        assertEq(finalManaged, managed);
        if (independent != 0) {
            (uint128 finalIndependent, uint256 last0, uint256 last1) = StateLibrary.getPositionInfo(
                manager, k.toId(), address(modifyLiquidityRouter), lower, upper, DIRECT_SALT
            );
            assertEq(finalIndependent, independent);
            r.directGrowth0 = last0;
            r.directGrowth1 = last1;
        }
    }

    function scenario(uint256 shareDenominator, uint256 notionalUsdc, uint256 route) private {
        prepare(shareDenominator);
        uint256 checkpoint = vm.snapshotState();
        Result memory concentrated = run(notionalUsdc, 0, 0);
        for (uint256 cadence; cadence < 2; ++cadence) {
            assertTrue(vm.revertToState(checkpoint));
            uint256 interval = cadence == 0 ? 1 : 10;
            Result memory split = run(notionalUsdc, interval, route);
            assertEq(split.price, concentrated.price);
            assertEq(split.tick, concentrated.tick);
            assertEq(split.growth0, concentrated.growth0);
            assertEq(split.growth1, concentrated.growth1);
            assertEq(split.directGrowth0, concentrated.directGrowth0);
            assertEq(split.directGrowth1, concentrated.directGrowth1);
            assertLe(split.gross0, concentrated.gross0);
            assertLe(split.gross1, concentrated.gross1);
            uint256 loss0 = concentrated.gross0 - split.gross0;
            uint256 loss1 = concentrated.gross1 - split.gross1;
            assertEq(loss0, split.fraction0 / Q128);
            assertEq(loss1, split.fraction1 / Q128);
            assertLe(loss0, split.effective0 == 0 ? 0 : split.effective0 - 1);
            assertLe(loss1, split.effective1 == 0 ? 0 : split.effective1 - 1);
            emit log_named_string("ARC extension", "8/6");
            emit log_named_uint("share denominator", shareDenominator);
            emit log_named_uint("notional USDC initial price", notionalUsdc);
            emit log_named_uint("route 0 self 1 claim 2 shuttle", route);
            emit log_named_uint("sync interval", interval);
            emit log_named_uint("swaps", 1000);
            emit log_named_uint("base first", baseFirst ? 1 : 0);
            emit log_named_uint("managed liquidity", managed);
            emit log_named_uint("independent liquidity", independent);
            emit log_named_uint("concentrated gross0", concentrated.gross0);
            emit log_named_uint("concentrated gross1", concentrated.gross1);
            emit log_named_uint("loss0", loss0);
            emit log_named_uint("loss1", loss1);
            emit log_named_uint("effective syncs0", split.effective0);
            emit log_named_uint("effective syncs1", split.effective1);
            emit log_named_uint("sync calls", split.syncCalls);
            emit log_named_uint("sync gas warm local", split.gasTotal);
        }
    }

    function test_RAM2_arcShare1_usdc1_self() public {
        scenario(1, 1, 0);
    }

    function test_RAM2_arcShare1_usdc1_claim() public {
        scenario(1, 1, 1);
    }

    function test_RAM2_arcShare1_usdc1_shuttle() public {
        scenario(1, 1, 2);
    }

    function test_RAM2_arcShare1_usdc10_self() public {
        scenario(1, 10, 0);
    }

    function test_RAM2_arcShare1_usdc10_claim() public {
        scenario(1, 10, 1);
    }

    function test_RAM2_arcShare1_usdc10_shuttle() public {
        scenario(1, 10, 2);
    }

    function test_RAM2_arcShare1_usdc100_self() public {
        scenario(1, 100, 0);
    }

    function test_RAM2_arcShare1_usdc100_claim() public {
        scenario(1, 100, 1);
    }

    function test_RAM2_arcShare1_usdc100_shuttle() public {
        scenario(1, 100, 2);
    }

    function test_RAM2_arcShare1_usdc1000_self() public {
        scenario(1, 1000, 0);
    }

    function test_RAM2_arcShare1_usdc1000_claim() public {
        scenario(1, 1000, 1);
    }

    function test_RAM2_arcShare1_usdc1000_shuttle() public {
        scenario(1, 1000, 2);
    }

    function test_RAM2_arcShare10_usdc1_self() public {
        scenario(10, 1, 0);
    }

    function test_RAM2_arcShare10_usdc1_claim() public {
        scenario(10, 1, 1);
    }

    function test_RAM2_arcShare10_usdc1_shuttle() public {
        scenario(10, 1, 2);
    }

    function test_RAM2_arcShare10_usdc10_self() public {
        scenario(10, 10, 0);
    }

    function test_RAM2_arcShare10_usdc10_claim() public {
        scenario(10, 10, 1);
    }

    function test_RAM2_arcShare10_usdc10_shuttle() public {
        scenario(10, 10, 2);
    }

    function test_RAM2_arcShare10_usdc100_self() public {
        scenario(10, 100, 0);
    }

    function test_RAM2_arcShare10_usdc100_claim() public {
        scenario(10, 100, 1);
    }

    function test_RAM2_arcShare10_usdc100_shuttle() public {
        scenario(10, 100, 2);
    }

    function test_RAM2_arcShare10_usdc1000_self() public {
        scenario(10, 1000, 0);
    }

    function test_RAM2_arcShare10_usdc1000_claim() public {
        scenario(10, 1000, 1);
    }

    function test_RAM2_arcShare10_usdc1000_shuttle() public {
        scenario(10, 1000, 2);
    }

    function test_RAM2_arcShare100_usdc1_self() public {
        scenario(100, 1, 0);
    }

    function test_RAM2_arcShare100_usdc1_claim() public {
        scenario(100, 1, 1);
    }

    function test_RAM2_arcShare100_usdc1_shuttle() public {
        scenario(100, 1, 2);
    }

    function test_RAM2_arcShare100_usdc10_self() public {
        scenario(100, 10, 0);
    }

    function test_RAM2_arcShare100_usdc10_claim() public {
        scenario(100, 10, 1);
    }

    function test_RAM2_arcShare100_usdc10_shuttle() public {
        scenario(100, 10, 2);
    }

    function test_RAM2_arcShare100_usdc100_self() public {
        scenario(100, 100, 0);
    }

    function test_RAM2_arcShare100_usdc100_claim() public {
        scenario(100, 100, 1);
    }

    function test_RAM2_arcShare100_usdc100_shuttle() public {
        scenario(100, 100, 2);
    }

    function test_RAM2_arcShare100_usdc1000_self() public {
        scenario(100, 1000, 0);
    }

    function test_RAM2_arcShare100_usdc1000_claim() public {
        scenario(100, 1000, 1);
    }

    function test_RAM2_arcShare100_usdc1000_shuttle() public {
        scenario(100, 1000, 2);
    }

    function test_RAM2_arcShare1000_usdc1_self() public {
        scenario(1000, 1, 0);
    }

    function test_RAM2_arcShare1000_usdc1_claim() public {
        scenario(1000, 1, 1);
    }

    function test_RAM2_arcShare1000_usdc1_shuttle() public {
        scenario(1000, 1, 2);
    }

    function test_RAM2_arcShare1000_usdc10_self() public {
        scenario(1000, 10, 0);
    }

    function test_RAM2_arcShare1000_usdc10_claim() public {
        scenario(1000, 10, 1);
    }

    function test_RAM2_arcShare1000_usdc10_shuttle() public {
        scenario(1000, 10, 2);
    }

    function test_RAM2_arcShare1000_usdc100_self() public {
        scenario(1000, 100, 0);
    }

    function test_RAM2_arcShare1000_usdc100_claim() public {
        scenario(1000, 100, 1);
    }

    function test_RAM2_arcShare1000_usdc100_shuttle() public {
        scenario(1000, 100, 2);
    }

    function test_RAM2_arcShare1000_usdc1000_self() public {
        scenario(1000, 1000, 0);
    }

    function test_RAM2_arcShare1000_usdc1000_claim() public {
        scenario(1000, 1000, 1);
    }

    function test_RAM2_arcShare1000_usdc1000_shuttle() public {
        scenario(1000, 1000, 2);
    }
}
