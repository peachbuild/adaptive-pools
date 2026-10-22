// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LedgerAlignmentTest} from "./LedgerAlignment.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract AuditRam13Test is LedgerAlignmentTest {
    using PoolIdLibrary for PoolKey;

    function test_RAM1_nativeValueRejectsBeforeDepositAndPreservesState() public {
        (PoolKey memory k, uint256 id) = seed();
        vm.deal(address(this), 1 ether);
        bytes32 beforeState = keccak256(abi.encode(ramp.rangeState(id), ramp.userPosition(id, address(this))));
        uint256 shares = ramp.balanceOf(address(this), id);
        uint256 token0 = MockERC20(Currency.unwrap(k.currency0)).balanceOf(address(this));
        uint256 token1 = MockERC20(Currency.unwrap(k.currency1)).balanceOf(address(this));
        uint256 claims0 = manager.balanceOf(address(ramp), k.currency0.toId());
        uint256 claims1 = manager.balanceOf(address(ramp), k.currency1.toId());
        uint256 nativeBefore = address(this).balance;
        vm.expectRevert(bytes4(keccak256("NativeNotSupported()")));
        ramp.deposit{value: 1}(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertEq(address(this).balance, nativeBefore);
        assertEq(address(ramp).balance, 0);
        assertEq(ramp.balanceOf(address(this), id), shares);
        assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(address(this)), token0);
        assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(address(this)), token1);
        assertEq(manager.balanceOf(address(ramp), k.currency0.toId()), claims0);
        assertEq(manager.balanceOf(address(ramp), k.currency1.toId()), claims1);
        assertEq(keccak256(abi.encode(ramp.rangeState(id), ramp.userPosition(id, address(this)))), beforeState);
    }

    function test_RAM3_dipAndRecoveryChargeBacklogAtMinimum() public {
        rate(1000);
        (PoolKey memory k, uint256 id) = seed();
        swap(k, true, -int256(1e14), "");
        rate(500);
        swap(k, true, -int256(1e14), "");
        rate(1500);
        swap(k, true, -int256(1e14), "");
        assertEq(ramp.effectiveClaimFee(id), 500);
        sync(id);
        uint256 gross = manager.balanceOf(address(ramp), k.currency0.toId());
        assertGt(gross, 0);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), gross * 500 / 10000);
        assertEq(ramp.effectiveClaimFee(id), 1500);
    }

    function test_RAM3_zeroDipThenRecoveryWaivesOnlyFirstWindow() public {
        rate(1000);
        (PoolKey memory k, uint256 id) = seed();
        swap(k, true, -int256(1e14), "");
        rate(0);
        rate(2000);
        swap(k, true, -int256(1e14), "");
        assertEq(ramp.effectiveClaimFee(id), 0);
        sync(id);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), 0);
        uint256 beforeGross = manager.balanceOf(address(ramp), k.currency0.toId());
        assertEq(ramp.effectiveClaimFee(id), 2000);
        swap(k, true, -int256(1e14), "");
        sync(id);
        uint256 gross = manager.balanceOf(address(ramp), k.currency0.toId()) - beforeGross;
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), gross * 2000 / 10000);
    }

    function test_RAM3_32EntriesExactAnd33FallbackToEarlierMinimum() public {
        rate(100); // Outside the later backlog window.
        rate(1000);
        (, uint256 id) = seed();
        for (uint256 i; i < 31; ++i) {
            rate(1500);
        }
        assertEq(ramp.effectiveClaimFee(id), 1000, "32 entries cover the window exactly");
        rate(1500);
        assertEq(ramp.effectiveClaimFee(id), 100, "33 entries fall back outside the window");
        sync(id);
        assertEq(ramp.effectiveClaimFee(id), 1500, "sync advances the cursor even without earnings");
    }

    function test_RAM3_earlierZeroIsUsedOnlyWhenWalkTruncates() public {
        rate(0);
        rate(1000);
        (, uint256 id) = seed();
        for (uint256 i; i < 31; ++i) {
            rate(1500);
        }
        assertEq(ramp.effectiveClaimFee(id), 1000);
        rate(1500);
        assertEq(ramp.effectiveClaimFee(id), 0);
    }

    function test_RAM3_rangesHaveIndependentSyncCursors() public {
        rate(1000);
        (PoolKey memory k, uint256 first) = seed();
        ramp.deposit(k, -240, 240, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        uint256 second = ramp.rangeId(k.toId(), -240, 240);
        rate(500);
        sync(first);
        rate(1500);
        assertEq(ramp.effectiveClaimFee(first), 500);
        assertEq(ramp.effectiveClaimFee(second), 500);
        sync(first);
        assertEq(ramp.effectiveClaimFee(first), 1500);
        assertEq(ramp.effectiveClaimFee(second), 500);
    }

    function test_RAM3_firstEnableWithoutHistoryPreservesZeroBacklog() public {
        (PoolKey memory k, uint256 id) = seed();
        swap(k, true, -int256(1e14), "");
        rate(1000);
        swap(k, true, -int256(1e14), "");
        assertEq(ramp.effectiveClaimFee(id), 0);
        sync(id);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), 0);
        assertEq(ramp.effectiveClaimFee(id), 1000);
        uint256 beforeGross = manager.balanceOf(address(ramp), k.currency0.toId());
        swap(k, true, -int256(1e14), "");
        sync(id);
        uint256 gross = manager.balanceOf(address(ramp), k.currency0.toId()) - beforeGross;
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), gross / 10);
    }

    function test_RAM3_explicitInitialZeroThenEnablePreservesFirstWindow() public {
        rate(0);
        (PoolKey memory k, uint256 id) = seed();
        swap(k, true, -int256(1e14), "");
        rate(1000);
        swap(k, true, -int256(1e14), "");
        assertEq(ramp.effectiveClaimFee(id), 0);
        sync(id);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), 0);
        assertEq(ramp.effectiveClaimFee(id), 1000);
        uint256 beforeGross = manager.balanceOf(address(ramp), k.currency0.toId());
        swap(k, true, -int256(1e14), "");
        sync(id);
        uint256 gross = manager.balanceOf(address(ramp), k.currency0.toId()) - beforeGross;
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), gross / 10);
    }
}
