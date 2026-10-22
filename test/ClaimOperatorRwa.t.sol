// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RwaRampTest} from "./RwaRamp.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract ClaimOperatorRwaTest is RwaRampTest {
    using PoolIdLibrary for PoolKey;

    function test_rwaInheritedDelegationPaysOwnerFees() public {
        PoolKey memory key = _key();
        vm.warp(TUESDAY_OPEN + 1 hours);
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        stock.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        swap(key, true, -int256(1e14), "");
        ramp.setClaimOperator(id, keeper, true);
        vm.prank(keeper);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(keeper), 0);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
        ramp.setClaimOperator(id, keeper, false);
        vm.prank(keeper);
        vm.expectRevert(Ramp.UnauthorizedClaimOperator.selector);
        ramp.claimFeesFor(key, -120, 120, address(this), keeper, 0);
    }
}
