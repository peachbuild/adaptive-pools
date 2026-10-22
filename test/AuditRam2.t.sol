// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RampTest} from "./Ramp.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract AuditRam2Test is RampTest {
    using PoolIdLibrary for PoolKey;

    uint256 private constant Q128 = 1 << 128;
    address private attacker = makeAddr("RAM2 dust holder");
    PoolKey private auditKey;
    uint256 private auditId;
    int24 private lower;
    int24 private upper;
    uint128 private units;
    uint160 private initialPrice;

    struct Outcome {
        uint256 gross0;
        uint256 gross1;
        uint256 growth0;
        uint256 growth1;
        uint160 price;
        int24 tick;
        uint256 fraction0;
        uint256 fraction1;
        uint256 effectiveSyncs;
        uint256 gasTotal;
        uint256 gasMax;
        uint256 protocol0;
        uint256 protocol1;
        uint256 dust0;
        uint256 dust1;
    }

    function prepare(bool arc, uint16 bps) private {
        // Synthetic prices and liquidity; actual precision, not production-token compatibility.
        wbnb = new MockERC20("Audit Base", "BASE", arc ? 8 : 18);
        stable = new MockERC20("Audit Quote", "QUOTE", arc ? 6 : 18);
        wbnb.mint(address(this), 1e30);
        stable.mint(address(this), 1e30);
        auditKey = _key();
        ramp.setPoolConfig(auditKey, 100, 700, 6000);
        if (bps != 0) ramp.setClaimFee(auditKey, new Currency[](0), bps, makeAddr("audit treasury"));
        uint256 baseScale = arc ? 1e8 : 1e18;
        uint256 quoteScale = arc ? 1e6 : 1e18;
        uint256 humanPrice = arc ? 100_000 : 1_000;
        bool baseFirst = Currency.unwrap(auditKey.currency0) == address(wbnb);
        uint256 ratioX192 = baseFirst
            ? FullMath.mulDiv(humanPrice * quoteScale, 1 << 192, baseScale)
            : FullMath.mulDiv(baseScale, 1 << 192, humanPrice * quoteScale);
        initialPrice = uint160(Math.sqrt(ratioX192));
        int24 center = (TickMath.getTickAtSqrtPrice(initialPrice) / 10) * 10;
        lower = center - 6000;
        upper = center + 6000;
        units = arc ? uint128(1e10) : uint128(1e21);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        manager.initialize(auditKey, initialPrice);
        ramp.deposit(auditKey, lower, upper, units, type(uint128).max, type(uint128).max, block.timestamp);
        auditId = ramp.rangeId(auditKey.toId(), lower, upper);
        ramp.transfer(attacker, auditId, 1);
    }

    function synchronize(Outcome memory o) private {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            StateLibrary.getPositionInfo(manager, auditKey.toId(), address(ramp), lower, upper, bytes32(auditId));
        (uint256 now0, uint256 now1) = StateLibrary.getFeeGrowthInside(manager, auditKey.toId(), lower, upper);
        uint256 delta0 = now0 - last0;
        uint256 delta1 = now1 - last1;
        uint256 expected0 = FullMath.mulDiv(delta0, liquidity, Q128);
        uint256 expected1 = FullMath.mulDiv(delta1, liquidity, Q128);
        uint256 before0 = manager.balanceOf(address(ramp), auditKey.currency0.toId());
        uint256 before1 = manager.balanceOf(address(ramp), auditKey.currency1.toId());
        o.fraction0 += mulmod(delta0, liquidity, Q128);
        o.fraction1 += mulmod(delta1, liquidity, Q128);
        if (delta0 != 0 || delta1 != 0) o.effectiveSyncs++;
        vm.prank(attacker);
        uint256 gasBefore = gasleft();
        ramp.transfer(attacker, auditId, 1);
        uint256 used = gasBefore - gasleft();
        o.gasTotal += used;
        if (used > o.gasMax) o.gasMax = used;
        assertEq(manager.balanceOf(address(ramp), auditKey.currency0.toId()) - before0, expected0);
        assertEq(manager.balanceOf(address(ramp), auditKey.currency1.toId()) - before1, expected1);
        (uint128 afterL,,) =
            StateLibrary.getPositionInfo(manager, auditKey.toId(), address(ramp), lower, upper, bytes32(auditId));
        assertEq(afterL, units, "sync does not reduce principal liquidity");
    }

    function runSequence(uint256 count, uint256 divisor, uint256 interval, bool bidirectional)
        private
        returns (Outcome memory o)
    {
        for (uint256 i; i < count; ++i) {
            bool direction = !bidirectional || i % 2 == 0;
            uint256 amount = direction
                ? FullMath.mulDiv(units, 1 << 96, initialPrice) / divisor
                : FullMath.mulDiv(units, initialPrice, 1 << 96) / divisor;
            assertGt(amount, 0);
            swap(auditKey, direction, -int256(amount), "");
            if (interval != 0 && (i + 1) % interval == 0) synchronize(o);
        }
        synchronize(o);
        o.gross0 = manager.balanceOf(address(ramp), auditKey.currency0.toId());
        o.gross1 = manager.balanceOf(address(ramp), auditKey.currency1.toId());
        (o.growth0, o.growth1) = StateLibrary.getFeeGrowthInside(manager, auditKey.toId(), lower, upper);
        (o.price, o.tick,,) = StateLibrary.getSlot0(manager, auditKey.toId());
        o.protocol0 = ramp.claimFeeOwed(Currency.unwrap(auditKey.currency0));
        o.protocol1 = ramp.claimFeeOwed(Currency.unwrap(auditKey.currency1));
        vm.prank(attacker);
        ramp.claimFees(auditKey, lower, upper, attacker, 2000);
        o.dust0 = MockERC20(Currency.unwrap(auditKey.currency0)).balanceOf(attacker);
        o.dust1 = MockERC20(Currency.unwrap(auditKey.currency1)).balanceOf(attacker);
    }

    function compare(Outcome memory concentrated, Outcome memory split) private pure {
        assertEq(split.price, concentrated.price);
        assertEq(split.tick, concentrated.tick);
        assertEq(split.growth0, concentrated.growth0);
        assertEq(split.growth1, concentrated.growth1);
        assertLe(split.gross0, concentrated.gross0);
        assertLe(split.gross1, concentrated.gross1);
        // This exact identity isolates PoolManager position rounding from Ramp's ledger rounding.
        assertEq(concentrated.gross0 - split.gross0, split.fraction0 / Q128);
        assertEq(concentrated.gross1 - split.gross1, split.fraction1 / Q128);
        if (split.effectiveSyncs != 0) {
            assertLe(concentrated.gross0 - split.gross0, split.effectiveSyncs - 1);
            assertLe(concentrated.gross1 - split.gross1, split.effectiveSyncs - 1);
        }
        assertLe(split.dust0, concentrated.dust0);
        assertLe(split.dust1, concentrated.dust1);
    }

    function matrix(bool arc, uint256 count, uint256 divisor, bool bidirectional) private {
        prepare(arc, 0);
        uint256 checkpoint = vm.snapshotState();
        Outcome memory concentrated = runSequence(count, divisor, 0, bidirectional);
        for (uint256 cadence; cadence < 2; ++cadence) {
            assertTrue(vm.revertToState(checkpoint));
            Outcome memory split = runSequence(count, divisor, cadence == 0 ? 1 : 10, bidirectional);
            compare(concentrated, split);
            emit log_named_string("RAM2 precision", arc ? "8/6" : "18/18");
            emit log_named_uint("swaps", count);
            emit log_named_uint("amount divisor", divisor);
            emit log_named_uint("bidirectional", bidirectional ? 1 : 0);
            emit log_named_uint("sync interval", cadence == 0 ? 1 : 10);
            emit log_named_uint("currency0 is base", Currency.unwrap(auditKey.currency0) == address(wbnb) ? 1 : 0);
            emit log_named_uint("currency0 base decimals", MockERC20(Currency.unwrap(auditKey.currency0)).decimals());
            emit log_named_uint("currency1 base decimals", MockERC20(Currency.unwrap(auditKey.currency1)).decimals());
            emit log_named_uint("concentrated gross0", concentrated.gross0);
            emit log_named_uint("concentrated gross1", concentrated.gross1);
            emit log_named_uint("loss0", concentrated.gross0 - split.gross0);
            emit log_named_uint("loss1", concentrated.gross1 - split.gross1);
            emit log_named_uint("effective syncs", split.effectiveSyncs);
            emit log_named_uint("split sync gas total warm local", split.gasTotal);
            emit log_named_uint("split sync gas max warm local", split.gasMax);
        }
    }

    function test_RAM2_arc_10_small_oneWay() public {
        matrix(true, 10, 100000000, false);
    }

    function test_RAM2_arc_10_small_twoWay() public {
        matrix(true, 10, 100000000, true);
    }

    function test_RAM2_arc_10_medium_oneWay() public {
        matrix(true, 10, 1000000, false);
    }

    function test_RAM2_arc_10_medium_twoWay() public {
        matrix(true, 10, 1000000, true);
    }

    function test_RAM2_arc_10_large_oneWay() public {
        matrix(true, 10, 10000, false);
    }

    function test_RAM2_arc_10_large_twoWay() public {
        matrix(true, 10, 10000, true);
    }

    function test_RAM2_arc_100_small_oneWay() public {
        matrix(true, 100, 100000000, false);
    }

    function test_RAM2_arc_100_small_twoWay() public {
        matrix(true, 100, 100000000, true);
    }

    function test_RAM2_arc_100_medium_oneWay() public {
        matrix(true, 100, 1000000, false);
    }

    function test_RAM2_arc_100_medium_twoWay() public {
        matrix(true, 100, 1000000, true);
    }

    function test_RAM2_arc_100_large_oneWay() public {
        matrix(true, 100, 10000, false);
    }

    function test_RAM2_arc_100_large_twoWay() public {
        matrix(true, 100, 10000, true);
    }

    function test_RAM2_arc_1000_small_oneWay() public {
        matrix(true, 1000, 100000000, false);
    }

    function test_RAM2_arc_1000_small_twoWay() public {
        matrix(true, 1000, 100000000, true);
    }

    function test_RAM2_arc_1000_medium_oneWay() public {
        matrix(true, 1000, 1000000, false);
    }

    function test_RAM2_arc_1000_medium_twoWay() public {
        matrix(true, 1000, 1000000, true);
    }

    function test_RAM2_arc_1000_large_oneWay() public {
        matrix(true, 1000, 10000, false);
    }

    function test_RAM2_arc_1000_large_twoWay() public {
        matrix(true, 1000, 10000, true);
    }

    function test_RAM2_bsc_10_small_oneWay() public {
        matrix(false, 10, 100000000, false);
    }

    function test_RAM2_bsc_10_small_twoWay() public {
        matrix(false, 10, 100000000, true);
    }

    function test_RAM2_bsc_10_medium_oneWay() public {
        matrix(false, 10, 1000000, false);
    }

    function test_RAM2_bsc_10_medium_twoWay() public {
        matrix(false, 10, 1000000, true);
    }

    function test_RAM2_bsc_10_large_oneWay() public {
        matrix(false, 10, 10000, false);
    }

    function test_RAM2_bsc_10_large_twoWay() public {
        matrix(false, 10, 10000, true);
    }

    function test_RAM2_bsc_100_small_oneWay() public {
        matrix(false, 100, 100000000, false);
    }

    function test_RAM2_bsc_100_small_twoWay() public {
        matrix(false, 100, 100000000, true);
    }

    function test_RAM2_bsc_100_medium_oneWay() public {
        matrix(false, 100, 1000000, false);
    }

    function test_RAM2_bsc_100_medium_twoWay() public {
        matrix(false, 100, 1000000, true);
    }

    function test_RAM2_bsc_100_large_oneWay() public {
        matrix(false, 100, 10000, false);
    }

    function test_RAM2_bsc_100_large_twoWay() public {
        matrix(false, 100, 10000, true);
    }

    function test_RAM2_bsc_1000_small_oneWay() public {
        matrix(false, 1000, 100000000, false);
    }

    function test_RAM2_bsc_1000_small_twoWay() public {
        matrix(false, 1000, 100000000, true);
    }

    function test_RAM2_bsc_1000_medium_oneWay() public {
        matrix(false, 1000, 1000000, false);
    }

    function test_RAM2_bsc_1000_medium_twoWay() public {
        matrix(false, 1000, 1000000, true);
    }

    function test_RAM2_bsc_1000_large_oneWay() public {
        matrix(false, 1000, 10000, false);
    }

    function test_RAM2_bsc_1000_large_twoWay() public {
        matrix(false, 1000, 10000, true);
    }

    function test_RAM2_protocolEnabledDoesNotChangeGrossRounding() public {
        prepare(false, 1000);
        uint256 checkpoint = vm.snapshotState();
        Outcome memory concentrated = runSequence(100, 1_000_000, 0, true);
        assertEq(concentrated.protocol0, concentrated.gross0 / 10);
        assertEq(concentrated.protocol1, concentrated.gross1 / 10);
        assertTrue(vm.revertToState(checkpoint));
        Outcome memory split = runSequence(100, 1_000_000, 1, true);
        compare(concentrated, split);
        assertLe(split.protocol0, split.gross0 / 10);
        assertLe(split.protocol1, split.gross1 / 10);
    }

    function test_RAM2_emptySyncsPreserveAccountedFeesAndRemainders() public {
        prepare(false, 0);
        runSequence(10, 1_000_000, 1, true);
        bytes32 beforeState = keccak256(abi.encode(ramp.rangeState(auditId), ramp.userPosition(auditId, attacker)));
        (uint128 r0, uint128 r1) = ramp.userFeeRemainder(auditId, attacker);
        uint256 before0 = manager.balanceOf(address(ramp), auditKey.currency0.toId());
        uint256 before1 = manager.balanceOf(address(ramp), auditKey.currency1.toId());
        Outcome memory o;
        for (uint256 i; i < 100; ++i) {
            synchronize(o);
        }
        assertEq(o.effectiveSyncs, 0);
        assertEq(manager.balanceOf(address(ramp), auditKey.currency0.toId()), before0);
        assertEq(manager.balanceOf(address(ramp), auditKey.currency1.toId()), before1);
        assertEq(keccak256(abi.encode(ramp.rangeState(auditId), ramp.userPosition(auditId, attacker))), beforeState);
        (uint128 after0, uint128 after1) = ramp.userFeeRemainder(auditId, attacker);
        assertEq(after0, r0);
        assertEq(after1, r1);
    }
}

contract AuditRam2PositionTest is Test {
    using Position for Position.State;
    Position.State private position;

    function test_RAM2_v4ExactAndFractionalPositionUpdates() public {
        uint256 q = 1 << 128;
        position.update(3, 0, 0);
        (uint256 exact0, uint256 exact1) = position.update(0, q, 2 * q);
        assertEq(exact0, 3);
        assertEq(exact1, 6);
        (uint256 fractional0, uint256 fractional1) = position.update(0, q + q / 2, 2 * q + q / 2);
        assertEq(fractional0, 1);
        assertEq(fractional1, 1);
        assertEq(mulmod(q / 2, 3, q), q / 2);
        (uint256 empty0, uint256 empty1) = position.update(0, q + q / 2, 2 * q + q / 2);
        assertEq(empty0, 0);
        assertEq(empty1, 0);
    }
}
