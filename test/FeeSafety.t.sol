// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RampTest} from "./Ramp.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {UserPosition} from "../src/ledger/LedgerTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract FeeSafetyTest is RampTest {
    using PoolIdLibrary for PoolKey;

    uint256 private constant Q128 = 1 << 128;

    function seed(uint16 bps) private returns (PoolKey memory k, uint256 id) {
        k = _key();
        if (bps != 0) ramp.setClaimFee(k, new Currency[](0), bps, makeAddr("treasury"));
        manager.initialize(k, Constants.SQRT_PRICE_1_1);
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        id = ramp.rangeId(k.toId(), -120, 120);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
    }

    function collect(PoolKey memory k) private {
        ramp.claimFees(k, -120, 120, address(this), 2000);
    }

    function smallSwaps(PoolKey memory k, uint256 id, address bob, uint8 mode) private returns (uint256) {
        for (uint256 i; i < 50; ++i) {
            swap(k, true, -int256(1e8), "");
            collect(k);
            if (mode == 1) ramp.transfer(bob, id, 1);
            if (mode == 2) {
                vm.prank(bob);
                ramp.claimFees(k, -120, 120, bob, 0);
            }
        }
        vm.prank(bob);
        ramp.claimFees(k, -120, 120, bob, 0);
        return MockERC20(Currency.unwrap(k.currency0)).balanceOf(bob);
    }

    function test_dustTransfersAndFrequentClaimsPreserveSmallEarnings() public {
        (PoolKey memory k, uint256 id) = seed(0);
        address bob = makeAddr("small holder");
        ramp.transfer(bob, id, 1e12);
        uint256 snap = vm.snapshotState();
        uint256 normal = smallSwaps(k, id, bob, 0);
        assertEq(normal, 3, "original 50-swap reproduction");
        assertTrue(vm.revertToState(snap));
        assertEq(smallSwaps(k, id, bob, 1), normal, "unsolicited shares cannot erase fractions");
        assertTrue(vm.revertToState(snap));
        assertEq(smallSwaps(k, id, bob, 2), normal, "claim frequency cannot erase fractions");
    }

    function test_bothTokenFractionsCarryAcrossSelfTransfers() public {
        (PoolKey memory k, uint256 id) = seed(0);
        address bob = makeAddr("small holder");
        ramp.transfer(bob, id, 1e12);
        for (uint256 i; i < 30; ++i) {
            swap(k, true, -int256(1e8), "");
            swap(k, false, -int256(1e8), "");
            collect(k);
            vm.startPrank(bob);
            ramp.transfer(bob, id, 1);
            (uint128 loopR0, uint128 loopR1) = ramp.userFeeRemainder(id, bob);
            UserPosition memory before = ramp.userPosition(id, bob);
            ramp.transferFrom(bob, bob, id, 1);
            (uint128 after0, uint128 after1) = ramp.userFeeRemainder(id, bob);
            assertEq(after0, loopR0);
            assertEq(after1, loopR1);
            assertEq(ramp.userPosition(id, bob).owed0, before.owed0);
            assertEq(ramp.userPosition(id, bob).owed1, before.owed1);
            vm.stopPrank();
        }
        (uint256 g0, uint256 g1) = netGrowth(id);
        vm.prank(bob);
        ramp.claimFees(k, -120, 120, bob, 0);
        assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(bob), 1e12 * g0 / Q128);
        assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(bob), 1e12 * g1 / Q128);
        assertGt(1e12 * g0 / Q128, 0);
        assertGt(1e12 * g1 / Q128, 0);
        (uint128 r0, uint128 r1) = ramp.userFeeRemainder(id, bob);
        assertEq(r0, 1e12 * g0 % Q128);
        assertEq(r1, 1e12 * g1 % Q128);
    }

    function test_remaindersStayWithSenderThroughTransferFromAndFullExit() public {
        (PoolKey memory k, uint256 id) = seed(0);
        address bob = makeAddr("small holder");
        address receiver = makeAddr("share receiver");
        ramp.transfer(bob, id, 1e12);
        swap(k, true, -int256(1e8), "");
        swap(k, false, -int256(1e8), "");
        vm.startPrank(bob);
        ramp.claimFees(k, -120, 120, bob, 0);
        (uint128 r0, uint128 r1) = ramp.userFeeRemainder(id, bob);
        assertGt(r0, 0);
        assertGt(r1, 0);
        ramp.approve(stranger, id, 5e11);
        vm.stopPrank();
        vm.prank(stranger);
        ramp.transferFrom(bob, receiver, id, 5e11);
        assertRemainder(id, bob, r0, r1);
        assertRemainder(id, receiver, 0, 0);

        vm.prank(bob);
        ramp.withdraw(k, -120, 120, 2e11, bob, 0, 0, block.timestamp);
        assertRemainder(id, bob, r0, r1);
        vm.prank(bob);
        ramp.withdraw(k, -120, 120, 3e11, bob, 0, 0, block.timestamp);
        assertRemainder(id, bob, r0, r1);
        vm.prank(bob);
        vm.expectRevert(Ramp.NothingToClaim.selector);
        ramp.claimFees(k, -120, 120, bob, 0);

        // Empty the entire range; fractions must survive even its next initialization of shares.
        vm.prank(receiver);
        ramp.withdraw(k, -120, 120, 5e11, receiver, 0, 0, block.timestamp);
        ramp.withdraw(k, -120, 120, uint128(ramp.balanceOf(address(this), id)), address(this), 0, 0, block.timestamp);
        wbnb.mint(bob, 1e24);
        stable.mint(bob, 1e24);
        vm.startPrank(bob);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
        ramp.deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        vm.stopPrank();
        assertRemainder(id, bob, r0, r1);
        (uint256 old0, uint256 old1) = netGrowth(id);
        swap(k, true, -int256(1e8), "");
        swap(k, false, -int256(1e8), "");
        address payout = makeAddr("reentry earnings");
        vm.prank(bob);
        ramp.claimFees(k, -120, 120, payout, 0);
        (uint256 new0, uint256 new1) = netGrowth(id);
        uint256 scaled0 = 1e18 * (new0 - old0) + r0;
        uint256 scaled1 = 1e18 * (new1 - old1) + r1;
        assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(payout), scaled0 / Q128);
        assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(payout), scaled1 / Q128);
        assertRemainder(id, bob, uint128(scaled0 % Q128), uint128(scaled1 % Q128));
    }

    function netGrowth(uint256 id) private view returns (uint256, uint256) {
        return (ramp.rangeState(id).accFee0X128, ramp.rangeState(id).accFee1X128);
    }

    function assertRemainder(uint256 id, address who, uint128 expected0, uint128 expected1) private view {
        (uint128 r0, uint128 r1) = ramp.userFeeRemainder(id, who);
        assertEq(r0, expected0);
        assertEq(r1, expected1);
    }

    function test_rotationPaysNamedCurrencyToOldAndOmittedCurrencyToNew() public {
        (PoolKey memory k,) = seed(1000);
        swap(k, true, -int256(1e14), "");
        swap(k, false, -int256(1e14), "");
        collect(k);
        address old = ramp.claimFeeRecipient();
        address next = makeAddr("next treasury");
        uint256 debt0 = ramp.claimFeeOwed(Currency.unwrap(k.currency0));
        uint256 debt1 = ramp.claimFeeOwed(Currency.unwrap(k.currency1));
        assertGt(debt0, 0);
        assertGt(debt1, 0);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 2);
        Currency[] memory partialSettle = new Currency[](3);
        partialSettle[0] = k.currency0;
        partialSettle[1] = k.currency0; // Duplicate and zero-debt currencies are harmless.
        partialSettle[2] = Currency.wrap(address(0));
        ramp.setClaimFee(k, partialSettle, 1500, next);
        assertEq(ramp.claimFeeRecipient(), next);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), 0);
        assertEq(ramp.claimFeeOwed(Currency.unwrap(k.currency1)), debt1);
        assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(old), debt0);
        assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(old), 0);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
        ramp.sweepClaimFee(k.currency1);
        assertEq(MockERC20(Currency.unwrap(k.currency1)).balanceOf(next), debt1);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
        ramp.sweepClaimFee(k.currency0);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
        swap(k, true, -int256(1e14), "");
        collect(k);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
    }

    function test_currencyCountAggregatesSharedTokensAcrossPools() public {
        (PoolKey memory k,) = seed(1000);
        swap(k, true, -int256(1e14), "");
        collect(k);
        uint256 firstDebt = ramp.claimFeeOwed(Currency.unwrap(k.currency0));
        PoolKey memory second = k;
        second.tickSpacing = 20;
        ramp.setPoolConfig(second, 100, 700, 6000);
        ramp.setClaimFee(second, new Currency[](0), 1000, ramp.claimFeeRecipient());
        manager.initialize(second, Constants.SQRT_PRICE_1_1);
        ramp.deposit(second, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        swap(second, true, -int256(1e14), "");
        collect(second);
        assertGt(ramp.claimFeeOwed(Currency.unwrap(k.currency0)), firstDebt);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
        swap(second, false, -int256(1e14), "");
        collect(second);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 2);
        Currency[] memory all = new Currency[](2);
        all[0] = k.currency0;
        all[1] = k.currency1;
        ramp.setClaimFee(k, all, 1000, makeAddr("next treasury"));
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
    }

    function test_unsynchronizedFeesBelongToRecipientAtCollection() public {
        (PoolKey memory k,) = seed(1000);
        swap(k, true, -int256(1e14), "");
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
        address next = makeAddr("next treasury");
        ramp.setClaimFee(k, new Currency[](0), 1000, next);
        collect(k);
        uint256 debt = ramp.claimFeeOwed(Currency.unwrap(k.currency0));
        ramp.sweepClaimFee(k.currency0);
        assertGt(debt, 0);
        assertEq(MockERC20(Currency.unwrap(k.currency0)).balanceOf(next), debt);
    }

    function test_failedTokenPaymentRollsBackDebtCountAndRecipient() public {
        (PoolKey memory k,) = seed(1000);
        swap(k, true, -int256(1e14), "");
        collect(k);
        address token = Currency.unwrap(k.currency0);
        address old = ramp.claimFeeRecipient();
        uint256 debt = ramp.claimFeeOwed(token);
        bytes memory payment = abi.encodeWithSignature("transfer(address,uint256)", old, debt);
        vm.mockCall(token, payment, abi.encode(false));
        Currency[] memory all = new Currency[](1);
        all[0] = k.currency0;
        vm.expectRevert(); // PoolManager wraps the failed ERC-20 payment.
        ramp.setClaimFee(k, all, 1500, makeAddr("next treasury"));
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
        assertEq(ramp.claimFeeOwed(token), debt);
        assertEq(ramp.claimFeeRecipient(), old);
        assertEq(ramp.claimFeeBps(k.toId()), 1000, "failed rotation preserves rate");
        assertEq(ramp.claimFeeHistoryLength(k.toId()), 1, "failed rotation preserves history");
        vm.clearMockedCalls();
        ramp.setClaimFee(k, all, 1000, makeAddr("next treasury"));
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
    }

    function testFuzz_multiUserOperationsPreserveSolvency(uint256 random) public {
        (PoolKey memory k, uint256 id) = seed(1000);
        address[3] memory owners = [address(this), makeAddr("bob"), makeAddr("carol")];
        address payout = makeAddr("all LP fee payments");
        ramp.transfer(owners[1], id, 3e17);
        ramp.transfer(owners[2], id, 3e17);
        for (uint256 i = 1; i < 3; ++i) {
            wbnb.mint(owners[i], 1e24);
            stable.mint(owners[i], 1e24);
            vm.startPrank(owners[i]);
            wbnb.approve(address(ramp), type(uint256).max);
            stable.approve(address(ramp), type(uint256).max);
            vm.stopPrank();
        }
        uint256 gross0;
        uint256 gross1;
        bytes32 collected = keccak256("FeesCollected(uint256,uint256,uint256,uint128)");
        for (uint256 i; i < 24; ++i) {
            random = uint256(keccak256(abi.encode(random, i)));
            vm.recordLogs();
            swap(k, random & 1 == 0, -int256(1e8 + random % 1e12), "");
            address owner = owners[(random >> 8) % 3];
            uint256 action = (random >> 16) % 5;
            uint128 units = uint128(1 + (random >> 32) % 1e12);
            vm.startPrank(owner);
            if (action == 0) {
                ramp.transfer(owners[(random >> 24) % 3], id, units);
            } else if (action == 1) {
                ramp.claimFees(k, -120, 120, payout, 2000);
            } else if (action == 2) {
                ramp.deposit(k, -120, 120, units, type(uint128).max, type(uint128).max, block.timestamp);
            } else if (action == 3) {
                ramp.withdraw(k, -120, 120, units, owner, 0, 0, block.timestamp);
            } else {
                ramp.approve(stranger, id, units);
            }
            vm.stopPrank();
            if (action == 4) {
                vm.prank(stranger);
                ramp.transferFrom(owner, owners[(random >> 24) % 3], id, units);
            }
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].emitter == address(ramp) && logs[j].topics[0] == collected) {
                    (uint256 a0, uint256 a1,) = abi.decode(logs[j].data, (uint256, uint256, uint128));
                    gross0 += a0;
                    gross1 += a1;
                }
            }
            (uint256 growth0, uint256 growth1) = netGrowth(id);
            uint256 liability0 = ramp.claimFeeOwed(Currency.unwrap(k.currency0));
            uint256 liability1 = ramp.claimFeeOwed(Currency.unwrap(k.currency1));
            uint256 shares;
            for (uint256 j; j < owners.length; ++j) {
                address who = owners[j];
                UserPosition memory position = ramp.userPosition(id, who);
                (uint128 r0, uint128 r1) = ramp.userFeeRemainder(id, who);
                uint256 balance = ramp.balanceOf(who, id);
                shares += balance;
                assertLt(uint256(r0), Q128);
                assertLt(uint256(r1), Q128);
                liability0 += position.owed0 + (balance * (growth0 - position.checkpoint0X128) + r0) / Q128;
                liability1 += position.owed1 + (balance * (growth1 - position.checkpoint1X128) + r1) / Q128;
            }
            assertEq(shares, ramp.rangeState(id).totalShares);
            MockERC20 token0 = MockERC20(Currency.unwrap(k.currency0));
            MockERC20 token1 = MockERC20(Currency.unwrap(k.currency1));
            assertLe(token0.balanceOf(payout) + liability0, gross0);
            assertLe(token1.balanceOf(payout) + liability1, gross1);
            assertEq(token0.balanceOf(payout) + manager.balanceOf(address(ramp), k.currency0.toId()), gross0);
            assertEq(token1.balanceOf(payout) + manager.balanceOf(address(ramp), k.currency1.toId()), gross1);
        }
    }
}
