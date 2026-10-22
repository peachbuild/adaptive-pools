// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Test-only composition: no swap implementation or production Router.
contract ClaimExitRouter {
    using PoolIdLibrary for PoolKey;
    error LaterStepFailed();

    function exit(Ramp ramp, PoolKey calldata key, bool fail) external {
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        ramp.transferFrom(msg.sender, address(this), id, 1e18);
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        ramp.claimFeesFor(key, -120, 120, msg.sender, address(this), 0);
        if (fail) revert LaterStepFailed();
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));
        t0.transfer(msg.sender, t0.balanceOf(address(this)));
        t1.transfer(msg.sender, t1.balanceOf(address(this)));
    }
}

contract ClaimOperatorTest is RampTest {
    using PoolIdLibrary for PoolKey;
    event ClaimOperatorSet(address indexed owner, uint256 indexed rangeId, address indexed operator, bool approved);
    event FeesClaimed(address indexed owner, uint256 indexed rangeId, uint256 amount0, uint256 amount1, address to);

    function seed() internal returns (PoolKey memory key, uint256 id) {
        key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        id = ramp.rangeId(key.toId(), -120, 120);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        earn(key);
    }

    function earn(PoolKey memory key) internal {
        swap(key, true, -int256(1e14), "");
        swap(key, false, -int256(1e14), "");
    }

    function test_policyReadForwardingPreservesValuesAndReverts() public {
        (PoolKey memory key,) = seed();
        ramp.setClaimFee(key, new Currency[](0), 1000, keeper);
        vm.warp(block.timestamp + 10);
        ramp.setClaimFeeBps(key, 500);
        assertEq(ramp.claimFeeBps(key.toId()), 500);
        assertEq(ramp.claimFeeHistoryLength(key.toId()), 2);
        assertEq(ramp.claimFeeAllTimeMin(key.toId()), 500);
        assertEq(ramp.claimFeeChangeAt(key.toId(), 0).bps, 1000);
        assertEq(ramp.claimFeeChangeAt(key.toId(), 1).bps, 500);
        assertEq(ramp.claimFeeChangeAt(key.toId(), 1).fromTs, block.timestamp);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x32)));
        ramp.claimFeeChangeAt(key.toId(), 2);
    }

    function test_authorizeRepeatRevokeReauthorize() public {
        (PoolKey memory key, uint256 id) = seed();
        vm.expectEmit(true, true, true, true, address(ramp));
        emit ClaimOperatorSet(address(this), id, stranger, true);
        ramp.setClaimOperator(id, stranger, true);
        assertTrue(ramp.isClaimOperator(address(this), id, stranger));
        vm.prank(stranger);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
        uint256 first = MockERC20(Currency.unwrap(key.currency0)).balanceOf(keeper);
        assertGt(first, 0);
        earn(key);
        vm.prank(stranger);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(keeper), first);
        vm.expectEmit(true, true, true, true, address(ramp));
        emit ClaimOperatorSet(address(this), id, stranger, false);
        ramp.setClaimOperator(id, stranger, false);
        assertFalse(ramp.isClaimOperator(address(this), id, stranger));
        vm.prank(stranger);
        vm.expectRevert(Ramp.UnauthorizedClaimOperator.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
        ramp.setClaimOperator(id, stranger, true);
        earn(key);
        vm.prank(stranger);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
    }

    function test_shareApprovalsAndOtherOwnersOrRangesDoNotAuthorize() public {
        (PoolKey memory key, uint256 id) = seed();
        ramp.approve(stranger, id, type(uint256).max);
        ramp.setOperator(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(Ramp.UnauthorizedClaimOperator.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), stranger, 0);
        vm.prank(stranger);
        ramp.setClaimOperator(id, stranger, true);
        assertFalse(ramp.isClaimOperator(address(this), id, stranger));
        ramp.setClaimOperator(id, stranger, true);
        vm.prank(stranger);
        vm.expectRevert(Ramp.UnauthorizedClaimOperator.selector);
        ramp.claimFeesFor(key, -60, 60, address(this), stranger, 0);
        vm.prank(stranger);
        vm.expectRevert(Ramp.UnauthorizedClaimOperator.selector);
        ramp.claimFeesFor(key, -120, 120, keeper, stranger, 0);
    }

    function test_ownerCanClaimWithoutApproval() public {
        (PoolKey memory key,) = seed();
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(keeper), 0);
    }

    function test_historicalFeesAfterTransferAndNoDoubleClaim() public {
        (PoolKey memory key, uint256 id) = seed();
        ramp.setClaimOperator(id, stranger, true);
        ramp.transfer(keeper, id, 1e18);
        uint256 owed0 = ramp.userPosition(id, address(this)).owed0;
        uint256 owed1 = ramp.userPosition(id, address(this)).owed1;
        assertGt(owed0, 0);
        assertGt(owed1, 0);
        vm.expectEmit(true, true, false, true, address(ramp));
        emit FeesClaimed(address(this), id, owed0, owed1, stranger);
        vm.prank(stranger);
        ramp.claimFeesFor(key, -120, 120, address(this), stranger, 0);
        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(stranger), owed0);
        assertEq(MockERC20(Currency.unwrap(key.currency1)).balanceOf(stranger), owed1);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
        assertEq(ramp.userPosition(id, address(this)).owed1, 0);
        vm.prank(stranger);
        vm.expectRevert(Ramp.NothingToClaim.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), stranger, 0);
    }

    function test_pauseRecipientAndFeeCap() public {
        (PoolKey memory key, uint256 id) = seed();
        ramp.setClaimFee(key, new Currency[](0), 1000, keeper);
        ramp.claimFees(key, -120, 120, address(this), 2000);
        earn(key);
        ramp.setClaimOperator(id, stranger, true);
        vm.startPrank(stranger);
        vm.expectRevert(Ramp.InvalidRecipient.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), address(0), 2000);
        vm.expectRevert(Ramp.ClaimFeeAboveMax.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 999);
        vm.stopPrank();
        ramp.setPoolPaused(key, 100);
        vm.prank(stranger);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 2000);
        ramp.setPaused(100);
        ramp.setClaimOperator(id, stranger, false);
        assertFalse(ramp.isClaimOperator(address(this), id, stranger));
        ramp.setClaimOperator(id, stranger, true);
        vm.prank(stranger);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 2000);
        vm.warp(block.timestamp + 101);
        vm.prank(stranger);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 1000);
    }

    function test_atomicExitAndRollbackThenRedepositKeepsApproval() public {
        (PoolKey memory key, uint256 id) = seed();
        ClaimExitRouter router = new ClaimExitRouter();
        ramp.approve(address(router), id, 1e18);
        ramp.setClaimOperator(id, address(router), true);
        uint256 b0 = wbnb.balanceOf(address(this));
        uint256 b1 = stable.balanceOf(address(this));
        uint256 snap = vm.snapshotState();
        // Direct combined exit is the reference for principal plus both fees.
        ramp.withdrawAndClaim(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp, 0);
        uint256 expected0 = wbnb.balanceOf(address(this));
        uint256 expected1 = stable.balanceOf(address(this));
        assertTrue(vm.revertToState(snap));
        vm.expectRevert(ClaimExitRouter.LaterStepFailed.selector);
        router.exit(ramp, key, true);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        assertEq(ramp.rangeState(id).totalShares, 1e18);
        assertEq(ramp.allowance(address(this), address(router), id), 1e18);
        assertEq(wbnb.balanceOf(address(this)), b0);
        assertEq(stable.balanceOf(address(this)), b1);
        assertEq(wbnb.balanceOf(address(router)), 0);
        assertEq(stable.balanceOf(address(router)), 0);
        router.exit(ramp, key, false);
        assertEq(wbnb.balanceOf(address(this)), expected0);
        assertEq(stable.balanceOf(address(this)), expected1);
        assertEq(ramp.balanceOf(address(this), id), 0);
        assertEq(ramp.balanceOf(address(router), id), 0);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
        assertEq(ramp.userPosition(id, address(this)).owed1, 0);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        earn(key);
        assertTrue(ramp.isClaimOperator(address(this), id, address(router)));
        vm.prank(address(router));
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(keeper), 0);
    }
}
