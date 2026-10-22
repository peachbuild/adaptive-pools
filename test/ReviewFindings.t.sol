// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {RwaRampTest} from "./RwaRamp.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {RwaRamp} from "../src/rwa/RwaRamp.sol";
import {SessionLib} from "../src/rwa/SessionLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseHook} from "../src/hooks/BaseHook.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Regression coverage for the findings in REVIEW_2026-09-29.md.
/// @dev Uses the real local v4 PoolManager and swaps, with no mocked fee accounting.
contract LedgerReviewFindingsTest is RampTest {
    using PoolIdLibrary for PoolKey;

    function reviewKey() internal view returns (PoolKey memory key) {
        (address a, address b) =
            address(wbnb) < address(stable) ? (address(wbnb), address(stable)) : (address(stable), address(wbnb));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, ramp);
    }

    function seededFees() internal returns (PoolKey memory key, uint256 id) {
        key = reviewKey();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        swap(key, true, -int256(1e14), "");
        id = ramp.rangeId(key.toId(), -120, 120);
    }

    function sync(uint256 id) internal {
        address holder = makeAddr("sync holder");
        ramp.transfer(holder, id, 1);
        vm.prank(holder);
        ramp.transfer(address(this), id, 1);
    }

    function test_regression_newDepositorCannotReceiveExistingLpFees() public {
        (PoolKey memory key, uint256 id) = seededFees();
        address newcomer = makeAddr("newcomer");
        wbnb.mint(newcomer, 1e18);
        stable.mint(newcomer, 1e18);
        MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
        uint256 beforeBalance = token0.balanceOf(newcomer);
        vm.startPrank(newcomer);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
        ramp.deposit(key, -120, 120, 1, type(uint128).max, type(uint128).max, block.timestamp);
        vm.stopPrank();
        assertLe(token0.balanceOf(newcomer), beforeBalance);
        assertGt(ramp.rangeState(id).accFee0X128, 0);
        uint256 ownerBefore = token0.balanceOf(address(this));
        ramp.claimFees(key, -120, 120, address(this), 0);
        assertGt(token0.balanceOf(address(this)), ownerBefore + 1e9);
    }

    function test_regression_tinyWithdrawalCannotBypassProtocolSkim() public {
        ramp.setClaimFee(reviewKey(), new Currency[](0), 1000, makeAddr("treasury"));
        (PoolKey memory key, uint256 id) = seededFees();
        MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
        uint256 beforeBalance = token0.balanceOf(address(this));
        ramp.withdraw(key, -120, 120, 1, address(this), 0, 0, block.timestamp);
        assertLe(token0.balanceOf(address(this)), beforeBalance + 1);
        assertGt(ramp.claimFeeOwed(address(token0)), 0);
        assertGt(ramp.rangeState(id).accFee0X128, 0);
    }

    function test_regression_transferKeepsPastFeesWithSender() public {
        (PoolKey memory key, uint256 id) = seededFees();
        address receiver = makeAddr("new holder");
        ramp.transfer(receiver, id, 1e18);
        vm.prank(receiver);
        ramp.claimFees(key, -120, 120, receiver, 0);
        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(receiver), 0);
        ramp.claimFees(key, -120, 120, address(this), 0);
    }

    function test_regression_lastExitPreservesAccruedClaim() public {
        (PoolKey memory key, uint256 id) = seededFees();
        sync(id);
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        assertGt(ramp.userPosition(id, address(this)).owed0, 0);
        uint256 beforeBalance = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        ramp.claimFees(key, -120, 120, address(this), 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)), beforeBalance);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
    }

    function test_regression_claimFeeChangeCannotRetroactivelyTaxSyncedFees() public {
        ramp.setClaimFee(reviewKey(), new Currency[](0), 1000, makeAddr("treasury"));
        (PoolKey memory key, uint256 id) = seededFees();
        sync(id);
        // Protocol fees are banked at sync, never repriced when the LP claims.
        MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
        uint256 gross = manager.balanceOf(address(ramp), key.currency0.toId());
        assertGt(gross, 1e9);
        uint256 protocolCut = ramp.claimFeeOwed(address(token0));
        assertApproxEqAbs(protocolCut, gross * 1000 / 10000, 1);
        ramp.setClaimFee(key, new Currency[](0), 2000, makeAddr("treasury"));
        ramp.claimFees(key, -120, 120, address(this), 2000);
        assertEq(ramp.claimFeeOwed(address(token0)), protocolCut);
    }

    function test_regression_ledgerRejectsUnrelatedNonHookPool() public {
        PoolKey memory key = reviewKey();
        key.hooks = uninitializedKey.hooks; // Deployers' default zero hook.
        key.fee = 3000;
        assertEq(address(key.hooks), address(0));
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.PoolNotConfigured.selector);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
    }
}

contract CalendarReviewFindingsTest is RwaRampTest {
    using PoolIdLibrary for PoolKey;

    function reviewKey() internal view returns (PoolKey memory key) {
        (address a, address b) =
            address(stock) < address(stable) ? (address(stock), address(stable)) : (address(stable), address(stock));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, ramp);
    }

    function test_regression_livePokeRespectsNextOpeningProtection() public {
        PoolId id = reviewKey().toId();
        vm.warp(TUESDAY_OPEN + 10 minutes);
        ramp.pokeFee(id, 100, 100, 25 hours);
        vm.warp(TUESDAY_OPEN + 1 days);
        assertEq(ramp.pokeFloor(id), 100);
        assertEq(ramp.currentFee(id, true), 450);
    }

    function test_regression_pokeCannotUndercutMinimumConfiguredSessionFloor() public {
        PoolKey memory key = reviewKey();
        SessionLib.FloorConfig memory cfg = ramp.floorConfig(key.toId());
        cfg.openFloor = 1000;
        cfg.overnightFloor = 1000;
        cfg.closedFloor = 1000;
        cfg.closeFloor = 1000;
        ramp.setPoolConfig(key, cfg, 2000);
        vm.warp(TUESDAY_OPEN + 1 hours);
        vm.expectRevert(BaseHook.FeeBelowFloor.selector);
        ramp.pokeFee(key.toId(), 500, 500, 1 hours);
    }

    function test_regression_fridayAfterCloseIsClosed() public {
        vm.warp(TUESDAY_OPEN + 3 days + 7 hours);
        assertEq(uint8(ramp.sessionAt(reviewKey().toId(), block.timestamp)), uint8(SessionLib.Session.CLOSED));
        assertEq(ramp.currentFee(reviewKey().toId(), true), 700);
    }

    function test_regression_newYearsDayIsClosed() public {
        vm.warp(TUESDAY_OPEN - 5 days + 1 hours); // 2026-01-01 10:30 EST.
        assertEq(uint8(ramp.sessionAt(reviewKey().toId(), block.timestamp)), uint8(SessionLib.Session.CLOSED));
    }

    function test_regression_documentedSpyNoDescentConfigAccepted() public {
        SessionLib.FloorConfig memory cfg = SessionLib.FloorConfig(800, 500, 250, 0, 0, 0, 0, 0, 0);
        ramp.setPoolConfig(reviewKey(), cfg, 2000);
        vm.warp(TUESDAY_OPEN);
        assertEq(ramp.currentFee(reviewKey().toId(), true), 800);
    }

    function test_regression_closeHoldEndsAtBoundary() public {
        vm.warp(TUESDAY_OPEN + 6 hours + 35 minutes);
        assertEq(ramp.currentFee(reviewKey().toId(), true), 300);
    }

    function test_regression_runtimeFitsEip170Limit() public view {
        assertLe(address(ramp).code.length, 24576);
    }
}
