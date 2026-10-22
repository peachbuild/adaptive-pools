// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {BaseHook} from "../src/hooks/BaseHook.sol";
import {MarketCalendar} from "../src/rwa/MarketCalendar.sol";
import {RwaRamp} from "../src/rwa/RwaRamp.sol";
import {SessionLib} from "../src/rwa/SessionLib.sol";

contract RwaRampTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint64 internal constant KEEPER_ROLE = 1;
    uint256 internal constant TUESDAY_OPEN = 1_767_709_800; // 2026-01-06 09:30 EST

    AccessManager internal access;
    RwaRamp internal ramp;
    MockERC20 internal stock;
    MockERC20 internal stable;
    address internal keeper = makeAddr("rwa keeper");

    function setUp() public {
        deployFreshManagerAndRouters();
        stock = new MockERC20("Ramp QQQ", "rQQQ", 18);
        stable = new MockERC20("USD Stable", "USDX", 18);
        stock.mint(address(this), 1e30);
        stable.mint(address(this), 1e30);

        access = new AccessManager(address(this));
        bytes memory args = abi.encode(manager, address(access), uint24(2_000));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
            type(RwaRamp).creationCode,
            args
        );
        ramp = new RwaRamp{salt: salt}(manager, address(access), 2_000);
        assertEq(address(ramp), predicted, "mined RWA hook address");

        ramp.setPoolConfig(_key(), _floorConfig(), 2_000);
        stock.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
    }

    function test_rwaCalendarAppliesOpenCloseAndWeekendCurves() public {
        PoolId id = _key().toId();

        vm.warp(TUESDAY_OPEN);
        assertEq(uint8(ramp.sessionAt(_key().toId(), block.timestamp)), uint8(SessionLib.Session.OPEN));
        assertEq(ramp.currentFee(id, true), 900, "routine opening spike");

        vm.warp(TUESDAY_OPEN + 10 minutes);
        assertEq(ramp.currentFee(id, true), 100, "opening descent reaches open floor");

        vm.warp(TUESDAY_OPEN + 6 hours + 30 minutes);
        assertEq(ramp.currentFee(id, true), 800, "close peak remains after close");

        vm.warp(TUESDAY_OPEN + 6 hours + 35 minutes + 1);
        assertEq(uint8(ramp.sessionAt(_key().toId(), block.timestamp)), uint8(SessionLib.Session.OVERNIGHT));
        assertEq(ramp.currentFee(id, true), 300, "overnight floor resumes after close window");

        vm.warp(1_768_046_400); // 2026-01-10 12:00 UTC, Saturday
        assertEq(uint8(ramp.sessionAt(_key().toId(), block.timestamp)), uint8(SessionLib.Session.CLOSED));
        assertEq(ramp.currentFee(id, true), 700, "weekend closed floor");
    }

    function test_rwaDayOverrideAndDstConfiguration() public {
        // Day seven of January is forced closed: two bits per day, value one.
        ramp.setDayOverrides(_key().toId(), 202601, uint64(1) << 12);
        vm.warp(1_767_794_400); // 2026-01-07 09:00 EST
        assertEq(uint8(ramp.dayOverride(_key().toId(), 2026, 1, 7)), 1);
        assertEq(uint8(ramp.sessionAt(_key().toId(), block.timestamp)), uint8(SessionLib.Session.CLOSED));

        ramp.setDstMode(_key().toId(), SessionLib.DstMode.FIXED_EST);
        assertEq(uint8(ramp.dstMode(_key().toId())), uint8(SessionLib.DstMode.FIXED_EST));

        vm.expectRevert(MarketCalendar.InvalidSessionHours.selector);
        ramp.setSessionHours(_key().toId(), 8 hours, 16 hours);
    }

    function test_rwaLimitsMonthlyDateOverrides() public {
        uint64 elevenOverrides;
        for (uint256 day; day < 11; day++) {
            elevenOverrides |= uint64(uint256(1) << (day * 2));
        }

        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.TooManyDayOverrides.selector, 11));
        ramp.setDayOverrides(_key().toId(), 202601, elevenOverrides);
    }

    function test_rwaKeeperFloorUsesCurrentAutonomousFee() public {
        PoolId id = _key().toId();
        vm.warp(TUESDAY_OPEN);
        _assignKeeper();

        assertEq(ramp.pokeFloor(id), 100);
        vm.startPrank(keeper);
        vm.expectRevert(BaseHook.FeeBelowFloor.selector);
        ramp.pokeFee(id, 99, 99, 1 hours);
        ramp.pokeFee(id, 450, 450, 1 hours);
        vm.stopPrank();
        assertEq(ramp.currentFee(id, true), 450);
    }

    function test_rwaRampUsesSharedLpLedger() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp + 1);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
    }

    function _assignKeeper() private {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BaseHook.pokeFee.selector;
        selectors[1] = BaseHook.clearPoke.selector;
        access.grantRole(KEEPER_ROLE, keeper, 0);
        access.setTargetFunctionRole(address(ramp), selectors, KEEPER_ROLE);
    }

    function _floorConfig() private pure returns (SessionLib.FloorConfig memory) {
        return SessionLib.FloorConfig({
            openFloor: 100,
            overnightFloor: 300,
            closedFloor: 700,
            spikeMult: 3,
            closedSpike: 1_200,
            descentWindow: 10 minutes,
            closeFloor: 800,
            closeBefore: 10 minutes,
            closeAfter: 5 minutes
        });
    }

    function _key() internal view returns (PoolKey memory key) {
        Currency a = Currency.wrap(address(stock));
        Currency b = Currency.wrap(address(stable));
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 10, hooks: ramp});
    }
}
