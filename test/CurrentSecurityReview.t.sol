// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {RampTest} from "./Ramp.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Models recipient blocklisting without disabling ordinary transfers or PoolManager.
contract ReviewRestrictedToken is MockERC20 {
    mapping(address => bool) public blocked;
    error RecipientBlocked(address recipient);

    constructor() MockERC20("Review token", "RVT", 18) {}

    function setBlocked(address recipient, bool value) external {
        blocked[recipient] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) revert RecipientBlocked(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) revert RecipientBlocked(to);
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Regression coverage for claims custody, Fables queries and recipient rotation.
contract CurrentSecurityReviewTest is RampTest {
    using PoolIdLibrary for PoolKey;

    function seedRestricted(uint16 bps) private returns (PoolKey memory key, uint256 id, ReviewRestrictedToken token0) {
        ReviewRestrictedToken a = new ReviewRestrictedToken();
        ReviewRestrictedToken b = new ReviewRestrictedToken();
        token0 = address(a) < address(b) ? a : b;
        ReviewRestrictedToken token1 = address(a) < address(b) ? b : a;
        key = _key();
        key.currency0 = Currency.wrap(address(token0));
        key.currency1 = Currency.wrap(address(token1));
        ramp.setPoolConfig(key, 100, 700, 6000);
        if (bps != 0) ramp.setClaimFee(key, new Currency[](0), bps, makeAddr("review treasury"));
        a.mint(address(this), 1e24);
        b.mint(address(this), 1e24);
        a.approve(address(ramp), type(uint256).max);
        b.approve(address(ramp), type(uint256).max);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        id = ramp.rangeId(key.toId(), -120, 120);
        swap(key, true, -int256(1e14), "");
    }

    function testFuzz_hookRestrictionDoesNotBlockUnpausedExitOrFees(bool pausedExit) public {
        (PoolKey memory key, uint256 id, ReviewRestrictedToken token0) = seedRestricted(0);
        token0.setBlocked(address(ramp), true);
        if (pausedExit) {
            ramp.setPaused(1 hours);
            vm.expectRevert(Ramp.LedgerPaused.selector);
            ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
            ramp.setPaused(0);
        }
        uint256 before = token0.balanceOf(address(this));
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        assertGt(token0.balanceOf(address(this)), before);
        assertEq(ramp.balanceOf(address(this), id), 0);
        assertEq(token0.balanceOf(address(ramp)), 0);
        uint256 owed = ramp.userPosition(id, address(this)).owed0;
        assertGt(owed, 0);
        uint256 held = manager.balanceOf(address(ramp), key.currency0.toId());
        assertGe(held, owed);
        address recipient = makeAddr("LP payout");
        ramp.claimFees(key, -120, 120, recipient, 0);
        assertEq(token0.balanceOf(recipient), owed);
        assertEq(manager.balanceOf(address(ramp), key.currency0.toId()), held - owed);
        assertTrue(token0.blocked(address(ramp)));
    }

    function test_blockedTreasuryCanBeReplacedWithoutSettlingItsCurrency() public {
        (PoolKey memory key,, ReviewRestrictedToken token0) = seedRestricted(1000);
        ramp.claimFees(key, -120, 120, address(this), 1000);
        address old = ramp.claimFeeRecipient();
        uint256 debt = ramp.claimFeeOwed(address(token0));
        uint256 held = manager.balanceOf(address(ramp), key.currency0.toId());
        assertGt(debt, 0);
        token0.setBlocked(old, true);
        address next = makeAddr("review replacement treasury");
        Currency[] memory settle = new Currency[](1);
        settle[0] = key.currency0;
        vm.expectRevert(); // PoolManager wraps the token's RecipientBlocked error.
        ramp.setClaimFee(key, settle, 1000, next);
        assertEq(ramp.claimFeeRecipient(), old);
        assertEq(ramp.claimFeeOwed(address(token0)), debt);
        assertEq(manager.balanceOf(address(ramp), key.currency0.toId()), held);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);

        ramp.setClaimFee(key, new Currency[](0), 1000, next);
        assertEq(ramp.claimFeeOwed(address(token0)), debt);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
        ramp.sweepClaimFee(key.currency0);
        assertEq(token0.balanceOf(old), 0);
        assertEq(token0.balanceOf(next), debt);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
        assertEq(manager.balanceOf(address(ramp), key.currency0.toId()), held - debt);
    }

    function test_liveGrowthMatchesPoolManagerAndStaysSeparateFromNetGrowth() public {
        (uint256 unknown0, uint256 unknown1) = ramp.rangeGrowth(42);
        assertEq(unknown0, 0);
        assertEq(unknown1, 0);
        (PoolKey memory key, uint256 id,) = seedRestricted(1000);
        (uint256 live0, uint256 live1) = StateLibrary.getFeeGrowthInside(manager, key.toId(), -120, 120);
        (uint256 reported0, uint256 reported1) = ramp.rangeGrowth(id);
        assertGt(live0, 0);
        assertEq(reported0, live0);
        assertEq(reported1, live1);
        assertEq(ramp.rangeState(id).accFee0X128, 0);
        assertEq(manager.balanceOf(address(ramp), key.currency0.toId()), 0, "view must not collect");
        ramp.transfer(address(this), id, 1);
        (reported0, reported1) = ramp.rangeGrowth(id);
        assertEq(reported0, live0);
        assertEq(reported1, live1);
        assertGt(ramp.rangeState(id).accFee0X128, 0);
        assertLt(ramp.rangeState(id).accFee0X128, reported0, "net growth excludes protocol skim");
    }

    function test_rotationSecondCurrencyFailureRollsBackFirstPayment() public {
        (PoolKey memory key,, ReviewRestrictedToken token0) = seedRestricted(1000);
        swap(key, false, -int256(1e14), "");
        ramp.claimFees(key, -120, 120, address(this), 1000);
        ReviewRestrictedToken token1 = ReviewRestrictedToken(Currency.unwrap(key.currency1));
        address old = ramp.claimFeeRecipient();
        token1.setBlocked(old, true);
        uint256 debt0 = ramp.claimFeeOwed(address(token0));
        uint256 debt1 = ramp.claimFeeOwed(address(token1));
        uint256 held0 = manager.balanceOf(address(ramp), key.currency0.toId());
        uint256 held1 = manager.balanceOf(address(ramp), key.currency1.toId());
        uint256 history = ramp.claimFeeHistoryLength(key.toId());
        assertGt(debt0, 0);
        assertGt(debt1, 0);
        Currency[] memory both = new Currency[](2);
        both[0] = key.currency0;
        both[1] = key.currency1;
        vm.expectRevert();
        ramp.setClaimFee(key, both, 1500, makeAddr("new treasury"));
        assertEq(token0.balanceOf(old), 0);
        assertEq(token1.balanceOf(old), 0);
        assertEq(ramp.claimFeeRecipient(), old);
        assertEq(ramp.claimFeeHistoryLength(key.toId()), history);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 2);
        assertEq(ramp.claimFeeOwed(address(token0)), debt0);
        assertEq(ramp.claimFeeOwed(address(token1)), debt1);
        assertEq(manager.balanceOf(address(ramp), key.currency0.toId()), held0);
        assertEq(manager.balanceOf(address(ramp), key.currency1.toId()), held1);
    }

    function test_failedSecondLegRollsBackBothClaimsAndUserDebt() public {
        (PoolKey memory key, uint256 id, ReviewRestrictedToken token0) = seedRestricted(0);
        ReviewRestrictedToken token1 = ReviewRestrictedToken(Currency.unwrap(key.currency1));
        swap(key, false, -int256(1e14), "");
        ramp.transfer(address(this), id, 1);
        uint256 owed0 = ramp.userPosition(id, address(this)).owed0;
        uint256 owed1 = ramp.userPosition(id, address(this)).owed1;
        uint256 held0 = manager.balanceOf(address(ramp), key.currency0.toId());
        uint256 held1 = manager.balanceOf(address(ramp), key.currency1.toId());
        assertGt(owed0, 0);
        assertGt(owed1, 0);
        address recipient = makeAddr("blocked LP payout");
        token1.setBlocked(recipient, true);
        vm.expectRevert();
        ramp.claimFees(key, -120, 120, recipient, 0);
        assertEq(token0.balanceOf(recipient), 0);
        assertEq(token1.balanceOf(recipient), 0);
        assertEq(ramp.userPosition(id, address(this)).owed0, owed0);
        assertEq(ramp.userPosition(id, address(this)).owed1, owed1);
        assertEq(manager.balanceOf(address(ramp), key.currency0.toId()), held0);
        assertEq(manager.balanceOf(address(ramp), key.currency1.toId()), held1);
        token1.setBlocked(recipient, false);
        ramp.claimFees(key, -120, 120, recipient, 0);
        assertEq(token0.balanceOf(recipient), owed0);
        assertEq(token1.balanceOf(recipient), owed1);
    }

    function test_lifecycleBaselinesAndOldFeesSurviveRecreation() public {
        vm.recordLogs();
        (PoolKey memory key, uint256 id, ReviewRestrictedToken token0) = seedRestricted(0);
        // Initial deposit baseline precedes seedRestricted's first swap, so growth is zero.
        checkLifecycle(vm.getRecordedLogs(), id, 1, 1e18, 0, 0);
        assertEq(ramp.rangeState(id).resetSeq, 1);
        ramp.deposit(key, -120, 120, 100, type(uint128).max, type(uint128).max, block.timestamp);
        ramp.withdraw(key, -120, 120, 100, address(this), 0, 0, block.timestamp);
        ramp.transfer(stranger, id, 1);
        vm.prank(stranger);
        ramp.transfer(address(this), id, 1);
        assertEq(ramp.rangeState(id).resetSeq, 1);
        vm.recordLogs();
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        (uint256 g0, uint256 g1) = ramp.rangeGrowth(id);
        checkLifecycle(vm.getRecordedLogs(), id, 2, 0, g0, g1);
        uint256 oldOwed = ramp.userPosition(id, address(this)).owed0;
        (uint128 oldFraction0, uint128 oldFraction1) = ramp.userFeeRemainder(id, address(this));
        assertGt(oldOwed, 0);
        address bob = makeAddr("new cycle LP");
        ReviewRestrictedToken token1 = ReviewRestrictedToken(Currency.unwrap(key.currency1));
        token0.mint(bob, 1e24);
        token1.mint(bob, 1e24);
        vm.startPrank(bob);
        token0.approve(address(ramp), type(uint256).max);
        token1.approve(address(ramp), type(uint256).max);
        vm.recordLogs();
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        vm.stopPrank();
        (g0, g1) = ramp.rangeGrowth(id);
        checkLifecycle(vm.getRecordedLogs(), id, 3, 1e18, g0, g1);
        assertEq(ramp.userPosition(id, bob).owed0, 0);
        assertEq(ramp.userPosition(id, address(this)).owed0, oldOwed);
        address payout = makeAddr("old cycle payout");
        ramp.claimFees(key, -120, 120, payout, 0);
        assertEq(token0.balanceOf(payout), oldOwed);
        (uint128 newFraction0, uint128 newFraction1) = ramp.userFeeRemainder(id, address(this));
        assertEq(newFraction0, oldFraction0);
        assertEq(newFraction1, oldFraction1);
        assertEq(ramp.rangeState(id).resetSeq, 3);
    }

    function checkLifecycle(Vm.Log[] memory logs, uint256 id, uint64 seq, uint128 shares, uint256 g0, uint256 g1)
        private
        view
    {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(ramp)
                    && logs[i].topics[0] == keccak256("RangeLifecycleChanged(uint256,uint64,uint128,uint256,uint256)")
            ) {
                assertEq(uint256(logs[i].topics[1]), id);
                (uint64 actualSeq, uint128 actualShares, uint256 actual0, uint256 actual1) =
                    abi.decode(logs[i].data, (uint64, uint128, uint256, uint256));
                assertEq(actualSeq, seq);
                assertEq(actualShares, shares);
                assertEq(actual0, g0);
                assertEq(actual1, g1);
                found++;
            }
        }
        assertEq(found, 1);
    }
}
