// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampETHTest, NativePayoutReceiver} from "./RampETH.t.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract ClaimOperatorNativeTest is RampETHTest {
    using PoolIdLibrary for PoolKey;

    function test_delegatedNativePayoutRejectsReentryAndPreservesFailedPayout() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.deposit{value: 1 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        swapNativeInput(key, true, -int256(1e14), "", 1e14);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        // Checkpoint earnings while leaving the owner with no shares.
        ramp.transfer(makeAddr("holder"), id, 1e18);
        uint256 owed = ramp.userPosition(id, address(this)).owed0;
        assertGt(owed, 0);
        NativePayoutReceiver receiver = new NativePayoutReceiver();
        ramp.setClaimOperator(id, address(receiver), true);
        bytes memory callback = abi.encodeCall(
            Ramp.claimFeesFor, (key, int24(-120), int24(120), address(this), address(receiver), uint16(0))
        );
        receiver.configure(true, address(ramp), callback);
        vm.prank(address(receiver));
        vm.expectRevert();
        ramp.claimFeesFor(key, -120, 120, address(this), address(receiver), 0);
        assertEq(ramp.userPosition(id, address(this)).owed0, owed);
        assertEq(address(receiver).balance, 0);
        receiver.configure(false, address(ramp), callback);
        vm.prank(address(receiver));
        ramp.claimFeesFor(key, -120, 120, address(this), address(receiver), 0);
        assertEq(address(receiver).balance, owed);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
        assertFalse(receiver.callbackSucceeded());
        assertEq(
            receiver.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }
}
