// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {RampETH} from "../src/core/RampETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "../src/hooks/BaseHook.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {MidBlockFeeMath} from "../src/hooks/MidBlockFeeMath.sol";
import {MarketCalendar} from "../src/rwa/MarketCalendar.sol";
import {RwaRamp} from "../src/rwa/RwaRamp.sol";
import {SessionLib} from "../src/rwa/SessionLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";

contract MidBlockFeeTest is RampTest {
    using PoolIdLibrary for PoolKey;

    RampETH internal nativeHook;
    RwaRamp internal rwaHook;

    function seed() internal returns (PoolKey memory key) {
        key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -60000, 60000, 1e22, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function token(Currency c) internal pure returns (MockERC20) {
        return MockERC20(Currency.unwrap(c));
    }

    function multiPools() internal returns (PoolKey memory plain, PoolKey memory nativeKey, PoolKey memory rwaKey) {
        vm.warp(1_767_710_400); // A regular RWA trading session, after the calendar epoch.
        plain = seed();
        bytes memory args = abi.encode(manager, address(access), uint24(20_000));
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (, bytes32 nativeSalt) = HookMiner.find(address(this), flags, type(RampETH).creationCode, args);
        nativeHook = new RampETH{salt: nativeSalt}(manager, address(access), 20_000);
        (, bytes32 rwaSalt) = HookMiner.find(address(this), flags, type(RwaRamp).creationCode, args);
        rwaHook = new RwaRamp{salt: rwaSalt}(manager, address(access), 20_000);

        nativeKey = PoolKey(Currency.wrap(address(0)), plain.currency1, plain.fee, plain.tickSpacing, nativeHook);
        nativeHook.setPoolConfig(nativeKey, 100, 700, 6_000);
        token(nativeKey.currency1).approve(address(nativeHook), type(uint256).max);
        manager.initialize(nativeKey, Constants.SQRT_PRICE_1_1);
        vm.deal(address(this), 1e26);
        nativeHook.deposit{value: 1e22}(nativeKey, -60000, 60000, 1e22, 1e22, type(uint128).max, block.timestamp);

        rwaKey = PoolKey(plain.currency0, plain.currency1, plain.fee, plain.tickSpacing, rwaHook);
        SessionLib.FloorConfig memory config = SessionLib.FloorConfig({
            openFloor: 100,
            overnightFloor: 300,
            closedFloor: 700,
            spikeMult: 3,
            closedSpike: 1200,
            descentWindow: 10 minutes,
            closeFloor: 800,
            closeBefore: 10 minutes,
            closeAfter: 5 minutes
        });
        rwaHook.setPoolConfig(rwaKey, config, 6_000);
        token(rwaKey.currency0).approve(address(rwaHook), type(uint256).max);
        token(rwaKey.currency1).approve(address(rwaHook), type(uint256).max);
        manager.initialize(rwaKey, Constants.SQRT_PRICE_1_1);
        rwaHook.deposit(rwaKey, -60000, 60000, 1e22, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function policy() private pure returns (BaseHook.MidBlockConfig memory) {
        return BaseHook.MidBlockConfig(true, 1, 500000, 15000);
    }

    function move(PoolKey memory key, bool direction, int256 amount) private returns (uint24 fee) {
        token(key.currency1).approve(address(swapRouter), type(uint256).max);
        if (Currency.unwrap(key.currency0) != address(0)) {
            token(key.currency0).approve(address(swapRouter), type(uint256).max);
        }
        vm.recordLogs();
        if (Currency.unwrap(key.currency0) == address(0)) {
            swapNativeInput(key, direction, amount, "", direction ? 1e22 : 0);
        } else {
            swap(key, direction, amount, "");
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found);
    }

    function assertState(Ramp hook, PoolId id, uint160 price, uint256 blockNo) private view {
        (uint160 actual, uint96 observed) = hook.midBlockState(id);
        assertEq(actual, price);
        assertEq(observed, blockNo);
    }

    function test_midBlock_threeHooksDirectionsBlocksAndCaps() public {
        (PoolKey memory a, PoolKey memory b, PoolKey memory c) = multiPools();
        PoolKey[3] memory keys = [a, b, c];
        for (uint256 kind; kind < 3; ++kind) {
            for (uint256 direction; direction < 2; ++direction) {
                uint256 snapshot = vm.snapshotState();
                PoolKey memory key = keys[kind];
                PoolId id = key.toId();
                Ramp hook = Ramp(address(key.hooks));
                assertEq(hook.executionFee(id, true), hook.currentFee(id, true), "default disabled");
                hook.setMidBlockConfig(key, policy());
                (uint160 open,,,) = StateLibrary.getSlot0(manager, id);
                bool up = direction == 1;
                assertEq(move(key, !up, -int256(1e19)), hook.currentFee(id, !up), "first swap baseline");
                assertState(hook, id, open, block.number);
                assertEq(hook.executionFee(id, !up), hook.currentFee(id, !up), "outward fee zero");
                uint24 total = hook.executionFee(id, up);
                assertGt(total, hook.currentFee(id, up), "return direction charged");
                assertLe(total, hook.maxFee(id));
                assertEq(move(key, up, -int256(1e18)), total, "real swap fee matches view");
                assertLt(hook.executionFee(id, up), total, "partial return reduces fee");
                uint24 exactOutputFee = hook.executionFee(id, up);
                assertEq(move(key, up, int256(1e20)), exactOutputFee, "exact-output fee uses pre-swap price");
                assertEq(hook.executionFee(id, up), hook.currentFee(id, up), "crossing flips surcharge direction");
                // Read the opening state before first swap after a multi-block gap.
                vm.roll(block.number + 5);
                (uint160 nextOpen,,,) = StateLibrary.getSlot0(manager, id);
                assertEq(hook.executionFee(id, true), hook.currentFee(id, true));
                assertEq(move(key, true, -int256(1e18)), hook.currentFee(id, true));
                assertState(hook, id, nextOpen, block.number);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_midBlock_configResetDisablePermissionsAndBounds() public {
        PoolKey memory key = seed();
        PoolId id = key.toId();
        bytes4[] memory keeperSelectors = new bytes4[](1);
        keeperSelectors[0] = BaseHook.pokeFee.selector;
        access.setTargetFunctionRole(address(ramp), keeperSelectors, 1);
        access.grantRole(1, keeper, 0);
        vm.prank(keeper);
        vm.expectRevert();
        ramp.setMidBlockConfig(key, policy());
        BaseHook.MidBlockConfig memory p = policy();
        p.midThresholdPips = 0;
        vm.expectRevert(BaseHook.InvalidConfig.selector);
        ramp.setMidBlockConfig(key, p);
        p = policy();
        p.captureFractionE6 = 1000001;
        vm.expectRevert(BaseHook.InvalidConfig.selector);
        ramp.setMidBlockConfig(key, p);
        p = policy();
        p.midCap = 20001;
        vm.expectRevert(BaseHook.InvalidConfig.selector);
        ramp.setMidBlockConfig(key, p);
        ramp.setMidBlockConfig(key, policy());
        move(key, false, -int256(1e20));
        assertGt(ramp.executionFee(id, true), ramp.currentFee(id, true));
        ramp.setMidBlockConfig(key, policy());
        assertState(ramp, id, 0, 0);
        assertEq(ramp.executionFee(id, true), ramp.currentFee(id, true));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, id);
        move(key, false, -int256(1e20));
        assertState(ramp, id, price, block.number);
        p = policy();
        p.enabled = false;
        ramp.setMidBlockConfig(key, p);
        assertEq(ramp.executionFee(id, true), ramp.currentFee(id, true));
    }

    function test_midBlock_moduleFailuresFallbackWithoutErasingBaseline() public {
        PoolKey memory key = seed();
        PoolId id = key.toId();
        ramp.setMidBlockConfig(key, policy());
        move(key, false, -int256(1e20));
        (uint160 open, uint96 blockNo) = ramp.midBlockState(id);
        address target = address(ramp.midBlockFeeMath());
        bytes memory original = target.code;
        bytes[5] memory bad;
        bad[0] = hex"60006000fd";
        bad[1] = hex"5b600056";
        bad[2] = hex"60006000f3";
        bad[3] = hex"600060005360016000f3";
        bad[4] = hex"600160005260406000f3";
        for (uint256 i; i < bad.length; ++i) {
            vm.etch(target, bad[i]);
            assertEq(ramp.executionFee(id, true), ramp.currentFee(id, true));
            assertEq(move(key, true, -int256(1e16)), ramp.currentFee(id, true));
            assertState(ramp, id, open, blockNo);
        }
        // Correct length but a value outside the admitted cap must also fail open.
        vm.etch(target, hex"62ffffff60005260206000f3");
        assertEq(ramp.executionFee(id, true), ramp.currentFee(id, true));
        vm.etch(target, original);
        assertGt(ramp.executionFee(id, true), ramp.currentFee(id, true));
        ramp.setPaused(100);
        vm.expectRevert();
        swap(key, true, -int256(1e16), "");
    }

    function test_midBlock_pokeCapAndLiquidityChanges() public {
        PoolKey memory key = seed();
        PoolId id = key.toId();
        ramp.setMidBlockConfig(key, policy());
        move(key, false, -int256(1e20));
        (uint160 open, uint96 n) = ramp.midBlockState(id);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        assertState(ramp, id, open, n);
        ramp.pokeFee(id, 5000, 5000, 1 hours);
        assertEq(ramp.currentFee(id, true), 5000);
        assertEq(ramp.executionFee(id, true), 6000, "final pool cap");
        ramp.setPoolConfig(key, 100, 700, 1000);
        assertEq(ramp.executionFee(id, true), 1000, "lowered pool cap applied live");
    }

    error SimulatedFee(uint24 fee);

    function simulateSwap(PoolKey memory key, bool direction, int256 amount) external {
        require(msg.sender == address(this));
        uint24 fee = move(key, direction, amount);
        revert SimulatedFee(fee);
    }

    function test_midBlock_revertedSimulationDoesNotObserve() public {
        (PoolKey memory a, PoolKey memory b, PoolKey memory c) = multiPools();
        PoolKey[3] memory keys = [a, b, c];
        for (uint256 i; i < keys.length; ++i) {
            PoolKey memory key = keys[i];
            Ramp hook = Ramp(address(key.hooks));
            PoolId id = key.toId();
            hook.setMidBlockConfig(key, policy());
            (uint160 price,,,) = StateLibrary.getSlot0(manager, id);
            vm.expectRevert(abi.encodeWithSelector(SimulatedFee.selector, hook.currentFee(id, false)));
            this.simulateSwap(key, false, -int256(1e20));
            assertState(hook, id, 0, 0);
            (uint160 afterSimulation,,,) = StateLibrary.getSlot0(manager, id);
            assertEq(afterSimulation, price);
            move(key, false, -int256(1e20));
            assertState(hook, id, price, block.number);
            uint24 reverseFee = hook.executionFee(id, true);
            vm.expectRevert(abi.encodeWithSelector(SimulatedFee.selector, reverseFee));
            this.simulateSwap(key, true, -int256(1e18));
            assertState(hook, id, price, block.number);
            assertEq(move(key, true, -int256(1e18)), reverseFee);
        }
    }

    function test_midBlock_failedSettlementAndPoolIsolation() public {
        PoolKey memory key = seed();
        PoolId id = key.toId();
        ramp.setMidBlockConfig(key, policy());
        // Hook runs, but callback settlement from an unfunded/unapproved trader fails.
        vm.prank(stranger);
        vm.expectRevert();
        swap(key, true, -int256(1e18), "");
        assertState(ramp, id, 0, 0);
        PoolKey memory other = PoolKey(key.currency0, key.currency1, key.fee, 20, key.hooks);
        ramp.setPoolConfig(other, 100, 700, 6000);
        manager.initialize(other, Constants.SQRT_PRICE_1_1);
        ramp.deposit(other, -60000, 60000, 1e22, type(uint128).max, type(uint128).max, block.timestamp);
        ramp.setMidBlockConfig(other, policy());
        move(key, false, -int256(1e20));
        assertState(ramp, other.toId(), 0, 0);
        assertEq(ramp.executionFee(other.toId(), true), ramp.currentFee(other.toId(), true));
        uint24 fee = ramp.executionFee(id, true);
        move(other, true, -int256(1e20));
        assertEq(ramp.executionFee(id, true), fee, "other pool cannot change this fee");
    }

    function test_midBlock_configEventsAndCalendarOwnership() public {
        (PoolKey memory key,, PoolKey memory rwaKey) = multiPools();
        BaseHook.MidBlockConfig memory p = policy();
        vm.expectEmit(true, false, false, true, address(ramp));
        emit BaseHook.MidBlockConfigSet(key.toId(), p);
        vm.recordLogs();
        ramp.setMidBlockConfig(key, p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[logs.length - 1].topics[0], keccak256("MidBlockConfigSet(bytes32,(bool,uint24,uint24,uint24))"));
        assertEq(logs[logs.length - 1].topics[1], PoolId.unwrap(key.toId()));
        assertEq(logs[logs.length - 1].data, abi.encode(p));
        SessionLib.FloorConfig memory config = rwaHook.floorConfig(rwaKey.toId());
        config.openFloor = 200;
        vm.expectEmit(true, false, false, true, address(rwaHook));
        emit RwaRamp.PoolConfigured(rwaKey.toId(), config, 6000);
        vm.recordLogs();
        rwaHook.setPoolConfig(rwaKey, config, 6000);
        logs = vm.getRecordedLogs();
        assertEq(logs[logs.length - 1].emitter, address(rwaHook));
        assertEq(
            logs[logs.length - 1].topics[0],
            keccak256("PoolConfigured(bytes32,(uint24,uint24,uint24,uint8,uint24,uint32,uint24,uint32,uint32),uint24)")
        );
        assertEq(logs[logs.length - 1].data, abi.encode(config, uint24(6000)));
        assertEq(abi.encode(rwaHook.floorConfig(rwaKey.toId())), abi.encode(config));
        MarketCalendar calendar = rwaHook.marketCalendar();
        vm.expectRevert(MarketCalendar.NotController.selector);
        calendar.setPoolConfig(rwaKey, config, 6000);
        // An inconsistent asymmetry must roll back the calendar write too.
        rwaHook.setPoolAsymmetry(rwaKey, 5800, true);
        config.openFloor = 300;
        config.overnightFloor = 300;
        config.closedFloor = 700;
        vm.expectRevert(BaseHook.PremiumExceedsFeeBand.selector);
        rwaHook.setPoolConfig(rwaKey, config, 6000);
        assertEq(rwaHook.floorConfig(rwaKey.toId()).openFloor, 200);
    }

    function test_midBlock_rejectsNonCanonicalEventInputs() public {
        PoolKey memory key = seed();
        bytes memory payload = abi.encodeCall(BaseHook.setMidBlockConfig, (key, policy()));
        // Static configuration starts after the selector and five PoolKey words.
        assembly ("memory-safe") { mstore(add(payload, 196), 2) }
        (bool ok,) = address(ramp).call(payload);
        assertFalse(ok, "noncanonical bool must not reach the raw event encoder");
        payload = abi.encodeCall(BaseHook.setMidBlockConfig, (key, policy()));
        assembly ("memory-safe") { mstore(add(payload, 228), shl(24, 1)) }
        (ok,) = address(ramp).call(payload);
        assertFalse(ok, "noncanonical uint24 must not reach the raw event encoder");
    }
}
