// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {SettlementToken} from "./StandardReuse.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Models a consumer reading receipt backing from a token callback.
/// It does not model or assert an exploit against a deployed lending protocol.
contract BackingObserver {
    Ramp internal immutable ramp;
    IPoolManager internal immutable manager;
    PoolId internal immutable pool;
    uint256 internal immutable id;
    uint128 public observedShares;
    uint128 public observedLiquidity;
    bool public observedSettling;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor(Ramp ramp_, IPoolManager manager_, PoolId pool_, uint256 id_) {
        ramp = ramp_;
        manager = manager_;
        pool = pool_;
        id = id_;
    }

    function observe() external {
        observedShares = ramp.rangeState(id).totalShares;
        (observedLiquidity,,) = StateLibrary.getPositionInfo(manager, pool, address(ramp), -120, 120, bytes32(id));
        observedSettling = ramp.isSettling();
        (reentrySucceeded, reentryResult) = address(ramp).call(abi.encodeCall(ramp.transfer, (address(this), id, 1)));
    }
}

/// @notice Regression coverage: PASS confirms corrected settlement and empty-range behavior.
contract ParitySecurityReviewTest is RampTest {
    using PoolIdLibrary for PoolKey;

    function test_regression_emptyRangeClaimsAtZeroMaxFeeWithoutNewSkim() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.setClaimFee(key, new Currency[](0), 1000, makeAddr("review treasury"));
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        swap(key, true, -int256(1e14), "");
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        assertEq(ramp.rangeState(id).totalShares, 0);
        uint256 owed = ramp.userPosition(id, address(this)).owed0;
        assertGt(owed, 0);
        uint256 protocolOwed = ramp.claimFeeOwed(Currency.unwrap(key.currency0));
        assertEq(ramp.effectiveClaimFee(id), 0, "empty range has no taxable backlog");
        uint256 beforeBalance = key.currency0.balanceOf(address(this));
        ramp.claimFees(key, -120, 120, address(this), 0);
        assertEq(key.currency0.balanceOf(address(this)) - beforeBalance, owed);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency0)), protocolOwed);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);

        // Recreating the range restores the rate and must not bypass pre-exit consent.
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertEq(ramp.effectiveClaimFee(id), 1000);
        swap(key, true, -int256(1e14), "");
        vm.expectRevert(Ramp.ClaimFeeAboveMax.selector);
        ramp.claimFees(key, -120, 120, address(this), 0);
        vm.expectRevert(Ramp.ClaimFeeAboveMax.selector);
        ramp.withdrawAndClaim(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp, 0);
        assertEq(ramp.rangeState(id).totalShares, 1e18);
        ramp.withdrawAndClaim(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp, 1000);
        assertGt(ramp.claimFeeOwed(Currency.unwrap(key.currency0)), protocolOwed);
        assertEq(ramp.effectiveClaimFee(id), 0);
        assertFalse(ramp.isSettling());
    }

    function test_regression_firstAndAdditionalDepositCallbacksSeeConsistentBacking() public {
        SettlementToken token = new SettlementToken();
        wbnb = token;
        token.mint(address(this), 1e30);
        token.approve(address(ramp), type(uint256).max);
        PoolKey memory key = _key();
        ramp.setPoolConfig(key, 100, 700, 6000);
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        BackingObserver observer = new BackingObserver(ramp, manager, key.toId(), id);
        token.configure(SettlementToken.Behavior.Reenter, address(observer), abi.encodeCall(observer.observe, ()));
        assertFalse(ramp.isSettling());
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertTrue(token.callbackSucceeded());
        assertEq(observer.observedLiquidity(), 1e18);
        assertEq(observer.observedShares(), 1e18);
        assertTrue(observer.observedSettling());
        assertFalse(observer.reentrySucceeded());
        assertEq(
            observer.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertFalse(ramp.isSettling());

        ramp.deposit(key, -120, 120, 9e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertTrue(token.callbackSucceeded());
        assertEq(observer.observedLiquidity(), 10e18);
        assertEq(observer.observedShares(), 10e18);
        assertTrue(observer.observedSettling());
        assertFalse(observer.reentrySucceeded());
        assertEq(
            observer.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertFalse(ramp.isSettling());
        assertEq(ramp.rangeState(id).totalShares, 10e18, "end-of-transaction state is consistent");
        assertEq(ramp.balanceOf(address(this), id), 10e18);
    }

    function test_regression_failedSecondTokenPaymentRollsBackPremintedShares() public {
        _assertDepositRollback(false);
    }

    function test_regression_secondPrincipalAboveMaxRollsBackPremintedShares() public {
        _assertDepositRollback(true);
    }

    function _assertDepositRollback(bool invalidMax) private {
        wbnb = new SettlementToken();
        stable = new SettlementToken();
        wbnb.mint(address(this), 1e30);
        stable.mint(address(this), 1e30);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
        PoolKey memory key = _key();
        ramp.setPoolConfig(key, 100, 700, 6000);
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.setClaimFee(key, new Currency[](0), 1000, makeAddr("rollback treasury"));
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        swap(key, true, -int256(1e14), "");
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        // Fail on the second leg, after sync, premint and a real first-token payment.
        SettlementToken second = SettlementToken(Currency.unwrap(key.currency1));
        if (!invalidMax) second.configure(SettlementToken.Behavior.ReturnFalse, address(0), "");
        bytes32 beforeState = _snapshot(key, id);
        uint128 maximum1 = invalidMax ? 0 : type(uint128).max;
        vm.expectRevert();
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, maximum1, block.timestamp);
        assertEq(_snapshot(key, id), beforeState, "all accounting and both token legs roll back");
        assertFalse(ramp.isSettling());
        second.configure(SettlementToken.Behavior.Normal, address(0), "");
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertEq(ramp.rangeState(id).totalShares, 2e18);
        assertEq(ramp.balanceOf(address(this), id), 2e18);
        assertFalse(ramp.isSettling());
    }

    function _snapshot(PoolKey memory key, uint256 id) private view returns (bytes32) {
        (uint128 liquidity, uint256 g0, uint256 g1) =
            StateLibrary.getPositionInfo(manager, key.toId(), address(ramp), -120, 120, bytes32(id));
        return keccak256(
            abi.encode(
                ramp.rangeState(id),
                ramp.userPosition(id, address(this)),
                ramp.balanceOf(address(this), id),
                ramp.claimFeeSyncIndex(id),
                liquidity,
                g0,
                g1,
                _currencySnapshot(key.currency0),
                _currencySnapshot(key.currency1)
            )
        );
    }

    function _currencySnapshot(Currency currency) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                currency.balanceOf(address(this)),
                currency.balanceOf(address(manager)),
                manager.balanceOf(address(ramp), currency.toId()),
                ramp.claimFeeOwed(Currency.unwrap(currency))
            )
        );
    }
}
