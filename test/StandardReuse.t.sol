// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {stdError} from "forge-std/StdError.sol";

/// @dev Exercise SafeERC20 and the guard through actual PoolManager settlement.
contract SettlementToken is MockERC20 {
    enum Behavior {
        Normal,
        NoReturn,
        ReturnFalse,
        Reenter
    }
    Behavior public behavior;
    address public target;
    bytes public callback;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() MockERC20("Settlement token", "SET", 18) {}

    function configure(Behavior value, address target_, bytes calldata callback_) external {
        behavior = value;
        target = target_;
        callback = callback_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (behavior == Behavior.ReturnFalse) return false;
        if (behavior == Behavior.Reenter) {
            (callbackSucceeded, callbackResult) = target.call(callback);
        }
        bool success = super.transferFrom(from, to, amount);
        if (behavior == Behavior.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return success;
    }
}

contract StandardReuseTest is RampTest {
    using PoolIdLibrary for PoolKey;

    function seed() private returns (PoolKey memory key, uint256 id) {
        key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        id = ramp.rangeId(key.toId(), -120, 120);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        swap(key, true, -int256(1e14), "");
    }

    function test_transferFromSettlesPastFeesAndUsesInheritedAllowance() public {
        (PoolKey memory key, uint256 id) = seed();
        address receiver = makeAddr("receiver");
        ramp.approve(stranger, id, 1e18);
        vm.prank(stranger);
        ramp.transferFrom(address(this), receiver, id, 1e18);
        assertEq(ramp.allowance(address(this), stranger, id), 0);
        assertEq(ramp.balanceOf(receiver, id), 1e18);
        assertGt(ramp.userPosition(id, address(this)).owed0, 0);
        assertEq(ramp.userPosition(id, receiver).owed0, 0);
        vm.prank(receiver);
        ramp.claimFees(key, -120, 120, receiver, 0);
        assertEq(MockERC20(Currency.unwrap(key.currency0)).balanceOf(receiver), 0);
        uint256 before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        ramp.claimFees(key, -120, 120, address(this), 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)), before);
    }

    function test_infiniteAllowanceOperatorAndOwnerTransferFrom() public {
        (, uint256 id) = seed();
        ramp.approve(stranger, id, type(uint256).max);
        vm.prank(stranger);
        ramp.transferFrom(address(this), stranger, id, 1);
        assertEq(ramp.allowance(address(this), stranger, id), type(uint256).max);
        ramp.approve(stranger, id, 0);
        ramp.setOperator(stranger, true);
        vm.prank(stranger);
        ramp.transferFrom(address(this), stranger, id, 2);
        assertEq(ramp.allowance(address(this), stranger, id), 0);
        ramp.setOperator(stranger, false);
        vm.prank(stranger);
        vm.expectRevert(stdError.arithmeticError);
        ramp.transferFrom(address(this), stranger, id, 1);
        ramp.transferFrom(address(this), stranger, id, 3);
        assertEq(ramp.balanceOf(stranger, id), 6);
        assertEq(ramp.rangeState(id).totalShares, 1e18);
    }

    function test_failedAuthorizationRollsBackFeeSynchronization() public {
        (PoolKey memory key, uint256 id) = seed();
        uint256 sequence = ramp.rangeState(id).collectionSeq;
        ramp.approve(stranger, id, 1);
        vm.prank(stranger);
        vm.expectRevert(stdError.arithmeticError);
        ramp.transferFrom(address(this), stranger, id, 2);
        assertEq(ramp.rangeState(id).collectionSeq, sequence);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
        assertEq(ramp.allowance(address(this), stranger, id), 1);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        assertEq(ramp.balanceOf(stranger, id), 0);
        ramp.claimFees(key, -120, 120, address(this), 0);
        assertGt(ramp.rangeState(id).collectionSeq, sequence);
    }

    function test_selfTransferDoesNotDuplicateAccruedFees() public {
        (, uint256 id) = seed();
        ramp.transfer(address(this), id, 1e18);
        uint256 owed = ramp.userPosition(id, address(this)).owed0;
        assertGt(owed, 0);
        ramp.transferFrom(address(this), address(this), id, 1e18);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        assertEq(ramp.userPosition(id, address(this)).owed0, owed);
    }

    function test_inheritedTransferStillEnforcesBusinessRestrictions() public {
        (PoolKey memory key, uint256 id) = seed();
        ramp.setOperator(stranger, true);
        vm.expectRevert(Ramp.InvalidRecipient.selector);
        ramp.transfer(address(0), id, 1);
        vm.expectRevert(Ramp.ZeroShares.selector);
        ramp.transfer(stranger, id, 0);
        ramp.setPoolPaused(key, 1 hours);
        vm.prank(stranger);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.transferFrom(address(this), stranger, id, 1);
    }

    function test_managerCallbacksRequireManagerAndActiveGuard() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        ramp.beforeInitialize(address(this), _key(), Constants.SQRT_PRICE_1_1);
        vm.expectRevert(Ramp.NotPoolManagerCallback.selector);
        ramp.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(Ramp.NotPoolManagerCallback.selector);
        ramp.unlockCallback("");
    }

    function settlementPool() private returns (SettlementToken token, PoolKey memory key) {
        token = new SettlementToken();
        wbnb = token;
        token.mint(address(this), 1e30);
        token.approve(address(ramp), type(uint256).max);
        key = _key();
        ramp.setPoolConfig(key, 100, 700, 6000);
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function test_safeERC20AcceptsNoReturnAndRejectsFalseDuringDeposit() public {
        (SettlementToken token, PoolKey memory key) = settlementPool();
        token.configure(SettlementToken.Behavior.ReturnFalse, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        assertEq(ramp.balanceOf(address(this), id), 0);
        token.configure(SettlementToken.Behavior.NoReturn, address(0), "");
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        assertEq(ramp.balanceOf(address(this), id), 0);
    }

    function test_standardGuardRejectsReentryFromSettlementToken() public {
        (SettlementToken token, PoolKey memory key) = settlementPool();
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        token.configure(
            SettlementToken.Behavior.Reenter, address(ramp), abi.encodeCall(ramp.transfer, (stranger, id, 1))
        );
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        ramp.transfer(stranger, id, 1);
        assertEq(ramp.balanceOf(stranger, id), 1, "guard resets after settlement");
    }
}
