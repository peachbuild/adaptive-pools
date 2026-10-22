// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {RampTest} from "./Ramp.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract AuditRam4BhoTest is RampTest {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // Power-of-two liquidity makes feeGrowth * liquidity / Q128 exact.
    // One holder owns all Ramp shares, so LP checkpoint rounding is also isolated.
    uint128 private constant EXACT_LIQUIDITY = uint128(1) << 64;
    bytes32 private constant DIRECT_SALT = keccak256("independent BHO-1 position");

    function test_RAM4_currency0FrequentVersusBatchedSettlement() public {
        _roundingComparison(true);
    }

    function test_RAM4_currency1FrequentVersusBatchedSettlement() public {
        _roundingComparison(false);
    }

    function test_BHO1_independentCollectBeforeRampWithNonzeroSkim() public {
        _independentPosition(false);
    }

    function test_BHO1_independentCollectAfterRampWithNonzeroSkim() public {
        _independentPosition(true);
    }

    function _fixture() private returns (PoolKey memory key, uint256 id, address treasury) {
        key = _key();
        treasury = makeAddr("RAM4 BHO1 treasury");
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.setClaimFee(key, new Currency[](0), 1_000, treasury);
        ramp.deposit(key, -120, 120, EXACT_LIQUIDITY, type(uint128).max, type(uint128).max, block.timestamp);
        id = ramp.rangeId(key.toId(), -120, 120);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
    }

    function _roundingComparison(bool zeroForOne) private {
        (PoolKey memory key, uint256 id, address treasury) = _fixture();
        uint256 snapshot = vm.snapshotState();
        _roundingRun(key, id, treasury, zeroForOne, true);
        assertTrue(vm.revertToState(snapshot));
        _roundingRun(key, id, treasury, zeroForOne, false);
    }

    function _roundingRun(PoolKey memory key, uint256 id, address treasury, bool zeroForOne, bool frequent) private {
        for (uint256 i; i < 10; ++i) {
            (uint256 before0, uint256 before1) = StateLibrary.getFeeGrowthInside(manager, key.toId(), -120, 120);
            swap(key, zeroForOne, -int256(12_000), "");
            (uint256 after0, uint256 after1) = StateLibrary.getFeeGrowthInside(manager, key.toId(), -120, 120);
            assertEq(after0 - before0, zeroForOne ? uint256(9) << 64 : 0, "exact 9-unit currency0 fee");
            assertEq(after1 - before1, zeroForOne ? 0 : uint256(9) << 64, "exact 9-unit currency1 fee");
            if (frequent) {
                ramp.transfer(address(this), id, 1);
                assertEq(ramp.userPosition(id, address(this)).owed0, zeroForOne ? (i + 1) * 9 : 0);
                assertEq(ramp.userPosition(id, address(this)).owed1, zeroForOne ? 0 : (i + 1) * 9);
                assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency0)), 0);
                assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency1)), 0);
            }
        }
        if (!frequent) ramp.transfer(address(this), id, 1);
        uint256 cut = frequent ? 0 : 9;
        _payAndCheck(
            key, id, treasury, zeroForOne ? 90 : 0, zeroForOne ? 0 : 90, zeroForOne ? cut : 0, zeroForOne ? 0 : cut
        );
    }

    function _independentPosition(bool collectRampFirst) private {
        (PoolKey memory key, uint256 id, address treasury) = _fixture();
        address directLP = makeAddr("independent LP");
        wbnb.mint(directLP, 1e20);
        stable.mint(directLP, 1e20);
        bytes32 beforeAdd = _ledgerHash(key, id, directLP);
        vm.startPrank(directLP);
        wbnb.approve(address(modifyLiquidityRouter), type(uint256).max);
        stable.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-120, 120, int256(uint256(EXACT_LIQUIDITY)), DIRECT_SALT), ""
        );
        vm.stopPrank();
        assertEq(_ledgerHash(key, id, directLP), beforeAdd, "direct add does not enter Ramp ledger");
        assertEq(ramp.balanceOf(directLP, id), 0);
        assertEq(
            uint160(address(ramp)) & Hooks.ALL_HOOK_MASK, uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        );
        (uint128 directLiquidity,,) =
            StateLibrary.getPositionInfo(manager, key.toId(), address(modifyLiquidityRouter), -120, 120, DIRECT_SALT);
        assertEq(directLiquidity, EXACT_LIQUIDITY);
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), uint256(EXACT_LIQUIDITY) * 2);

        ramp.pokeFee(key.toId(), 350, 1_400, 1 hours);
        _swapWithEventFee(key, true, 350);
        _swapWithEventFee(key, false, 1_400);
        (uint256 growth0, uint256 growth1) = StateLibrary.getFeeGrowthInside(manager, key.toId(), -120, 120);
        assertEq(growth0, uint256(175_000_000) << 64, "exact fees per currency0 position");
        assertEq(growth1, uint256(700_000_000) << 64, "exact fees per currency1 position");
        if (collectRampFirst) ramp.transfer(address(this), id, 1);

        bytes32 beforeCollect = _ledgerHash(key, id, directLP);
        uint256 before0 = _balance(key.currency0, directLP);
        uint256 before1 = _balance(key.currency1, directLP);
        vm.prank(directLP);
        BalanceDelta directFees =
            modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, 0, DIRECT_SALT), "");
        assertEq(directFees.amount0(), 175_000_000);
        assertEq(directFees.amount1(), 700_000_000);
        assertEq(_balance(key.currency0, directLP) - before0, 175_000_000, "direct fees paid without Ramp skim");
        assertEq(_balance(key.currency1, directLP) - before1, 700_000_000, "direct fees paid without Ramp skim");
        assertEq(
            _ledgerHash(key, id, directLP), beforeCollect, "direct collection preserves Ramp accounting and claims"
        );
        if (!collectRampFirst) ramp.transfer(address(this), id, 1);
        _payAndCheck(key, id, treasury, 175_000_000, 700_000_000, 17_500_000, 70_000_000);
        // Independent payout + Ramp LP payout + protocol payout exhaust both swap fees.
        assertEq(uint256(uint128(directFees.amount0())) + 175_000_000, 350_000_000);
        assertEq(uint256(uint128(directFees.amount1())) + 700_000_000, 1_400_000_000);
    }

    function _swapWithEventFee(PoolKey memory key, bool zeroForOne, uint24 expectedFee) private {
        assertEq(ramp.currentFee(key.toId(), zeroForOne), expectedFee);
        vm.recordLogs();
        swap(key, zeroForOne, -int256(1e12), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, expectedFee, "PoolManager uses Hook directional fee");
                found = true;
            }
        }
        assertTrue(found, "real swap event observed");
    }

    function _payAndCheck(
        PoolKey memory key,
        uint256 id,
        address treasury,
        uint256 gross0,
        uint256 gross1,
        uint256 cut0,
        uint256 cut1
    ) private {
        assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency0)), cut0);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency1)), cut1);
        uint256 before0 = _balance(key.currency0, address(this));
        uint256 before1 = _balance(key.currency1, address(this));
        ramp.claimFees(key, -120, 120, address(this), 1_000);
        uint256 lp0 = _balance(key.currency0, address(this)) - before0;
        uint256 lp1 = _balance(key.currency1, address(this)) - before1;
        assertEq(lp0, gross0 - cut0);
        assertEq(lp1, gross1 - cut1);
        uint256 treasury0 = _balance(key.currency0, treasury);
        uint256 treasury1 = _balance(key.currency1, treasury);
        ramp.sweepClaimFee(key.currency0);
        ramp.sweepClaimFee(key.currency1);
        assertEq(_balance(key.currency0, treasury) - treasury0, cut0);
        assertEq(_balance(key.currency1, treasury) - treasury1, cut1);
        assertEq(lp0 + _balance(key.currency0, treasury) - treasury0, gross0, "currency0 conserved");
        assertEq(lp1 + _balance(key.currency1, treasury) - treasury1, gross1, "currency1 conserved");
        assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency0)), 0);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(key.currency1)), 0);
        assertEq(manager.balanceOf(address(ramp), uint160(Currency.unwrap(key.currency0))), 0);
        assertEq(manager.balanceOf(address(ramp), uint160(Currency.unwrap(key.currency1))), 0);
        assertEq(ramp.balanceOf(address(this), id), EXACT_LIQUIDITY);
        assertEq(ramp.rangeState(id).totalShares, EXACT_LIQUIDITY);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
        assertEq(ramp.userPosition(id, address(this)).owed1, 0);
    }

    function _ledgerHash(PoolKey memory key, uint256 id, address directLP) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                ramp.rangeState(id),
                ramp.userPosition(id, address(this)),
                ramp.userPosition(id, directLP),
                ramp.claimFeeSyncIndex(id),
                ramp.claimFeeOwed(Currency.unwrap(key.currency0)),
                ramp.claimFeeOwed(Currency.unwrap(key.currency1)),
                manager.balanceOf(address(ramp), uint160(Currency.unwrap(key.currency0))),
                manager.balanceOf(address(ramp), uint160(Currency.unwrap(key.currency1)))
            )
        );
    }

    function _balance(Currency currency, address owner) private view returns (uint256) {
        return MockERC20(Currency.unwrap(currency)).balanceOf(owner);
    }
}
