// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {ClaimFeePolicy} from "../src/ledger/ClaimFeePolicy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract LedgerAlignmentTest is RampTest {
    using PoolIdLibrary for PoolKey;

    function seed() internal returns (PoolKey memory k, uint256 id) {
        k = _key();
        manager.initialize(k, Constants.SQRT_PRICE_1_1);
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        id = ramp.rangeId(k.toId(), -120, 120);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
    }

    function sync(uint256 id) internal {
        address holder = makeAddr("sync holder");
        ramp.transfer(holder, id, 1);
        vm.prank(holder);
        ramp.transfer(address(this), id, 1);
    }

    function rate(uint16 bps) internal {
        ramp.setClaimFee(_key(), new Currency[](0), bps, makeAddr("treasury"));
    }

    function test_backlogUsesMinimumRateAndFutureFeesUseNewRate() public {
        rate(1000);
        (PoolKey memory k, uint256 id) = seed();
        swap(k, true, -int256(1e14), "");
        rate(2000);
        assertEq(ramp.effectiveClaimFee(id), 1000);
        sync(id);
        MockERC20 t = MockERC20(Currency.unwrap(k.currency0));
        uint256 firstCut = ramp.claimFeeOwed(address(t));
        assertGt(firstCut, 0);
        assertEq(ramp.effectiveClaimFee(id), 2000);
        uint256 grossBefore = manager.balanceOf(address(ramp), k.currency0.toId());
        swap(k, true, -int256(1e14), "");
        sync(id);
        uint256 secondGross = manager.balanceOf(address(ramp), k.currency0.toId()) - grossBefore;
        assertEq(ramp.claimFeeOwed(address(t)) - firstCut, secondGross * 2000 / 10000);
        ramp.setClaimFeeBps(k, 0);
        rate(2000);
        assertEq(ramp.effectiveClaimFee(id), 0);
    }

    function test_historyWalkBoundFallbackAndPoolIsolation() public {
        rate(1000);
        (PoolKey memory k, uint256 id) = seed();
        rate(500);
        rate(2000);
        for (uint256 i; i < 40; i++) {
            rate(1500);
        }
        assertEq(ramp.effectiveClaimFee(id), 500);
        assertEq(ramp.claimFeeHistoryLength(k.toId()), 43);
        PoolKey memory second = _key();
        second.tickSpacing = 20;
        ramp.setPoolConfig(second, 100, 700, 6000);
        ramp.setClaimFee(second, new Currency[](0), 0, makeAddr("treasury"));
        assertEq(ramp.claimFeeBps(second.toId()), 0);
        assertEq(ramp.claimFeeBps(k.toId()), 1500);
        ClaimFeePolicy policy = ramp.claimFeePolicy();
        vm.prank(stranger);
        vm.expectRevert(ClaimFeePolicy.Unauthorized.selector);
        policy.record(k.toId(), 2000);
    }

    function test_feeRecipientRotationSettlesOldRecipient() public {
        rate(1000);
        (PoolKey memory k, uint256 id) = seed();
        swap(k, true, -int256(1e14), "");
        sync(id);
        uint256 owed = ramp.claimFeeOwed(Currency.unwrap(k.currency0));
        Currency[] memory settle = new Currency[](1);
        settle[0] = k.currency0;
        address old = makeAddr("treasury");
        address next = makeAddr("next treasury");
        ramp.setClaimFee(k, settle, 1000, next);
        assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(old), owed);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), 0);
        vm.expectRevert(Ramp.InvalidClaimFee.selector);
        ramp.setClaimFee(k, new Currency[](0), 0, address(0));
    }

    function testFuzz_twoOwnersReceiveOnlyTheirShareAndNoDoubleClaim(uint128 bobUnits) public {
        bobUnits = uint128(bound(bobUnits, 1e12, 1e18));
        (PoolKey memory k, uint256 id) = seed();
        address bob = makeAddr("bob");
        wbnb.mint(bob, 1e24);
        stable.mint(bob, 1e24);
        vm.startPrank(bob);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
        ramp.deposit(k, -120, 120, bobUnits, type(uint128).max, type(uint128).max, block.timestamp);
        vm.stopPrank();
        swap(k, true, -int256(1e14), "");
        sync(id);
        MockERC20 t = MockERC20(Currency.unwrap(k.currency0));
        uint256 gross = manager.balanceOf(address(ramp), k.currency0.toId());
        uint256 beforeA = t.balanceOf(address(this));
        uint256 beforeB = t.balanceOf(bob);
        ramp.claimFees(k, -120, 120, address(this), 0);
        vm.prank(bob);
        ramp.claimFees(k, -120, 120, bob, 0);
        uint256 earnedA = t.balanceOf(address(this)) - beforeA;
        uint256 earnedB = t.balanceOf(bob) - beforeB;
        assertApproxEqAbs(earnedA, gross * 1e18 / (uint256(bobUnits) + 1e18), 1);
        assertApproxEqAbs(earnedB, gross * bobUnits / (uint256(bobUnits) + 1e18), 1);
        assertLe(earnedA + earnedB, gross);
        ramp.claimFees(k, -120, 120, address(this), 0);
        assertEq(t.balanceOf(address(this)) - beforeA, earnedA);
        assertEq(ramp.rangeState(id).totalShares, uint256(bobUnits) + 1e18);
    }

    function test_withdrawSync_partialExitPreservesBothOwnersPendingFees() public {
        _assertWithdrawalFeeOwnership(2e18, 4e17);
    }

    function test_withdrawSync_fullOwnerExitPreservesBothOwnersPendingFees() public {
        _assertWithdrawalFeeOwnership(2e18, 1e18);
    }

    function test_withdrawSync_lastExitPreservesPendingFeesAndProtocolSkim() public {
        _assertWithdrawalFeeOwnership(0, 1e18);
    }

    function _assertWithdrawalFeeOwnership(uint128 bobUnits, uint128 withdrawn) private {
        rate(1000);
        (PoolKey memory k, uint256 id) = seed();
        address bob = makeAddr("withdraw sync bob");
        if (bobUnits != 0) {
            wbnb.mint(bob, 1e24);
            stable.mint(bob, 1e24);
            vm.startPrank(bob);
            wbnb.approve(address(ramp), type(uint256).max);
            stable.approve(address(ramp), type(uint256).max);
            ramp.deposit(k, -120, 120, bobUnits, type(uint128).max, type(uint128).max, block.timestamp);
            vm.stopPrank();
        }

        // Read the position baseline without collecting. No claim, deposit or share
        // transfer may hide a missing withdrawal sync after these two swaps.
        (uint128 oldLiquidity, uint256 last0, uint256 last1) =
            StateLibrary.getPositionInfo(manager, k.toId(), address(ramp), -120, 120, bytes32(id));
        assertEq(oldLiquidity, 1e18 + uint256(bobUnits));
        swap(k, true, -int256(1e14), "");
        swap(k, false, -int256(2e14), "");
        (uint256 live0, uint256 live1) = StateLibrary.getFeeGrowthInside(manager, k.toId(), -120, 120);
        uint256 q128 = 1 << 128;
        uint256[2] memory gross;
        unchecked {
            gross[0] = FullMath.mulDiv(live0 - last0, oldLiquidity, q128);
            gross[1] = FullMath.mulDiv(live1 - last1, oldLiquidity, q128);
        }
        Currency[2] memory currencies = [k.currency0, k.currency1];
        for (uint256 i; i < 2; ++i) {
            assertGt(gross[i], 0, "both currencies must have uncollected fees");
            assertEq(manager.balanceOf(address(ramp), currencies[i].toId()), 0, "fees must remain unsynced");
        }

        // Keep principal separate from fee recipients so payout assertions cannot
        // mistake a successful principal withdrawal for correct fee accounting.
        ramp.withdraw(k, -120, 120, withdrawn, makeAddr("withdraw sync principal"), 0, 0, block.timestamp);
        assertEq(ramp.balanceOf(address(this), id), 1e18 - withdrawn);
        assertEq(ramp.balanceOf(bob, id), bobUnits);
        assertEq(ramp.rangeState(id).totalShares, uint256(oldLiquidity) - withdrawn);

        uint256[2] memory expectedA;
        uint256[2] memory expectedB;
        for (uint256 i; i < 2; ++i) {
            uint256 cut = gross[i] * 1000 / 10000;
            // Expected amounts come from pre-withdrawal PoolManager growth and
            // ownership, including the ledger's two Q128 rounding steps.
            uint256 netGrowth = FullMath.mulDiv(gross[i] - cut, q128, oldLiquidity);
            expectedA[i] = FullMath.mulDiv(1e18, netGrowth, q128);
            expectedB[i] = FullMath.mulDiv(bobUnits, netGrowth, q128);
            assertGt(expectedA[i], 0);
            assertEq(
                i == 0 ? ramp.userPosition(id, address(this)).owed0 : ramp.userPosition(id, address(this)).owed1,
                expectedA[i],
                "withdrawing owner must retain all pre-withdrawal fees"
            );
            assertEq(ramp.claimFeeOwed(Currency.unwrap(currencies[i])), cut, "protocol skim must survive exit");
            assertEq(manager.balanceOf(address(ramp), currencies[i].toId()), gross[i]);
        }

        address payoutA = makeAddr("withdraw sync payout A");
        address payoutB = makeAddr("withdraw sync payout B");
        ramp.claimFees(k, -120, 120, payoutA, 1000);
        if (bobUnits != 0) {
            vm.prank(bob);
            ramp.claimFees(k, -120, 120, payoutB, 1000);
        }
        for (uint256 i; i < 2; ++i) {
            uint256 cut = gross[i] * 1000 / 10000;
            assertEq(currencies[i].balanceOf(payoutA), expectedA[i], "exiting LP payout");
            assertEq(currencies[i].balanceOf(payoutB), expectedB[i], "remaining LP cannot inherit past fees");
            assertEq(ramp.claimFeeOwed(Currency.unwrap(currencies[i])), cut, "claims must not charge another skim");
            ramp.sweepClaimFee(currencies[i]);
            assertEq(currencies[i].balanceOf(ramp.claimFeeRecipient()), cut);
            assertEq(
                manager.balanceOf(address(ramp), currencies[i].toId()),
                gross[i] - cut - expectedA[i] - expectedB[i],
                "only rounding dust remains after all payouts"
            );
        }
    }

    function test_slippageDeadlineAndPauseScope() public {
        (PoolKey memory k,) = seed();
        vm.expectRevert();
        ramp.deposit(k, -120, 120, 1e18, 0, 0, block.timestamp);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(Ramp.DeadlineExpired.selector);
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp - 1);
        ramp.setPoolPaused(k, 1 hours);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.withdraw(k, -120, 120, 1, address(this), 0, 0, block.timestamp);
        vm.expectRevert(); // PoolManager wraps the Hook's LedgerPaused error.
        swap(k, true, -int256(1e14), "");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        swap(k, true, -int256(1e14), "");
        vm.expectRevert();
        ramp.withdraw(k, -120, 120, 1, address(this), type(uint128).max, 0, block.timestamp);
        ramp.withdraw(k, -120, 120, 1, address(this), 0, 0, block.timestamp);
    }

    function test_lpEventsContainPoolTicksAmountsAndRecipient() public {
        PoolKey memory k = _key();
        manager.initialize(k, Constants.SQRT_PRICE_1_1);
        vm.recordLogs();
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 depositTopic = keccak256("Deposited(address,uint256,bytes32,int24,int24,uint128,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ramp) && logs[i].topics[0] == depositTopic) {
                assertEq(logs[i].topics[3], PoolId.unwrap(k.toId()));
                (int24 lo, int24 hi, uint128 units, uint256 a0, uint256 a1) =
                    abi.decode(logs[i].data, (int24, int24, uint128, uint256, uint256));
                assertEq(lo, -120);
                assertEq(hi, 120);
                assertEq(units, 1e18);
                assertGt(a0, 0);
                assertGt(a1, 0);
                found = true;
            }
        }
        assertTrue(found);
        found = false;
        address receiver = makeAddr("recipient");
        vm.recordLogs();
        ramp.withdraw(k, -120, 120, 1e18, receiver, 0, 0, block.timestamp);
        logs = vm.getRecordedLogs();
        bytes32 withdrawTopic =
            keccak256("Withdrawn(address,uint256,bytes32,int24,int24,uint128,uint256,uint256,address)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ramp) && logs[i].topics[0] == withdrawTopic) {
                (,,, uint256 a0, uint256 a1, address to) =
                    abi.decode(logs[i].data, (int24, int24, uint128, uint256, uint256, address));
                assertEq(to, receiver);
                assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(receiver), a0);
                assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(receiver), a1);
                found = true;
            }
        }
        assertTrue(found);
        assertTrue(ramp.supportsInterface(0x0f632fb3));
    }

    function test_claimEventReportsActualNetPaymentAndReceiver() public {
        rate(1000);
        (PoolKey memory k,) = seed();
        swap(k, true, -int256(1e14), "");
        address receiver = makeAddr("claim receiver");
        vm.recordLogs();
        ramp.claimFees(k, -120, 120, receiver, 1000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(ramp)
                    && logs[i].topics[0] == keccak256("FeesClaimed(address,uint256,uint256,uint256,address)")
            ) {
                (uint256 a0, uint256 a1, address to) = abi.decode(logs[i].data, (uint256, uint256, address));
                assertEq(to, receiver);
                assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(receiver), a0);
                assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(receiver), a1);
                assertGt(a0, 0);
                found = true;
            }
        }
        assertTrue(found);
        assertGt(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), 0);
    }
}
