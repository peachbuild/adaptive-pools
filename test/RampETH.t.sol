// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UserPosition, RangeState} from "../src/ledger/LedgerTypes.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {RampETH} from "../src/core/RampETH.sol";
import {Ramp} from "../src/core/Ramp.sol";

contract RejectRefund {
    receive() external payable {
        revert("reject native refund");
    }
}

contract NativePayoutReceiver {
    bool public reject;
    address public target;
    bytes public callback;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function configure(bool reject_, address target_, bytes calldata callback_) external {
        reject = reject_;
        target = target_;
        callback = callback_;
    }

    receive() external payable {
        require(!reject, "reject native payout");
        if (target != address(0)) (callbackSucceeded, callbackResult) = target.call(callback);
    }
}

contract RampETHTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AccessManager internal access;
    RampETH internal ramp;
    MockERC20 internal stable;

    function setUp() public {
        deployFreshManagerAndRouters();
        vm.deal(address(this), 100 ether);
        stable = new MockERC20("USD Stable", "USDX", 18);
        stable.mint(address(this), 1e30);
        access = new AccessManager(address(this));
        bytes memory args = abi.encode(IPoolManager(manager), address(access), uint24(6_000));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
            type(RampETH).creationCode,
            args
        );
        ramp = new RampETH{salt: salt}(manager, address(access), 6_000);
        assertEq(address(ramp), predicted);
        ramp.setPoolConfig(_key(), 100, 700, 6_000);
        stable.approve(address(ramp), type(uint256).max);
    }

    function test_legacySingleFeeUpdatesBothDirections() public {
        PoolId id = _key().toId();
        ramp.pokeFee(id, 350, 1 hours);
        (uint24 zeroForOne, uint24 oneForZero,) = ramp.pokeOf(id);
        assertEq(zeroForOne, 350);
        assertEq(oneForZero, 350);
    }

    function test_nativeDepositPrepayAndRefund() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        uint256 balanceBefore = address(this).balance;
        ramp.deposit{value: 1 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        assertEq(ramp.balanceOf(address(this), id), 1e18);
        assertGt(address(this).balance, balanceBefore - 1 ether);
        assertEq(address(ramp).balance, 0);

        uint256 beforeWithdraw = address(this).balance;
        ramp.withdraw(key, -120, 120, 1e18, address(this), 0, 0, block.timestamp);
        assertGt(address(this).balance, beforeWithdraw, "principal is paid in native currency");
    }

    function test_nativeProtocolFeeSweepPaysNative() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        address treasury = makeAddr("treasury");
        ramp.setClaimFee(key, new Currency[](0), 1_000, treasury);
        ramp.deposit{value: 1 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);

        swapNativeInput(key, true, -int256(1e14), "", 1e14);
        ramp.claimFees(key, -120, 120, address(this), 1_000);
        uint256 owed = ramp.claimFeeOwed(address(0));
        assertGt(owed, 0);

        ramp.sweepClaimFee(Currency.wrap(address(0)));
        assertEq(treasury.balance, owed, "protocol revenue is paid natively");
        assertEq(ramp.claimFeeOwed(address(0)), 0);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
    }

    function test_nativeNamedDebtPaidBeforeRecipientRotation() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        address old = makeAddr("treasury");
        address next = makeAddr("next treasury");
        ramp.setClaimFee(key, new Currency[](0), 1_000, old);
        ramp.deposit{value: 1 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        swapNativeInput(key, true, -int256(1e14), "", 1e14);
        ramp.claimFees(key, -120, 120, address(this), 1_000);
        uint256 owed = ramp.claimFeeOwed(address(0));
        assertGt(owed, 0);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
        Currency[] memory nativeCurrency = new Currency[](1);
        nativeCurrency[0] = Currency.wrap(address(0));
        ramp.setClaimFee(key, nativeCurrency, 1_000, next);
        assertEq(old.balance, owed);
        assertEq(ramp.claimFeeRecipient(), next);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 0);
    }

    function test_nativeDepositRejectsInsufficientPrepayment() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        vm.expectRevert(RampETH.InvalidMsgValue.selector);
        ramp.deposit{value: 0.99 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
    }

    function test_nativeRefundFailureRevertsEntireDeposit() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        RejectRefund rejector = new RejectRefund();
        stable.mint(address(rejector), 1e30);
        vm.prank(address(rejector));
        stable.approve(address(ramp), type(uint256).max);
        vm.deal(address(rejector), 2 ether);
        uint256 tokenBefore = stable.balanceOf(address(rejector));
        uint256 managerNativeBefore = address(manager).balance;
        uint256 managerTokenBefore = stable.balanceOf(address(manager));
        vm.prank(address(rejector));
        vm.expectRevert();
        ramp.deposit{value: 2 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        assertEq(ramp.balanceOf(address(rejector), id), 0);
        assertEq(ramp.rangeState(id).totalShares, 0);
        assertEq(ramp.rangeState(id).resetSeq, 0);
        assertEq(ramp.userPosition(id, address(rejector)).owed0, 0);
        assertEq(ramp.userPosition(id, address(rejector)).owed1, 0);
        (uint128 liquidity,,) = StateLibrary.getPositionInfo(manager, key.toId(), address(ramp), -120, 120, bytes32(id));
        assertEq(liquidity, 0);
        assertEq(address(rejector).balance, 2 ether);
        assertEq(stable.balanceOf(address(rejector)), tokenBefore);
        assertEq(address(manager).balance, managerNativeBefore);
        assertEq(stable.balanceOf(address(manager)), managerTokenBefore);
        assertEq(address(ramp).balance, 0);
        assertFalse(ramp.isSettling());
    }

    function seedNative(address treasury) private returns (PoolKey memory key, uint256 id) {
        key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.setClaimFee(key, new Currency[](0), 1000, treasury);
        ramp.deposit{value: 1 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        swapNativeInput(key, true, -int256(1e14), "", 1e14);
        id = ramp.rangeId(key.toId(), -120, 120);
        ramp.transfer(address(this), id, 1); // Materialize claims and user debt without a payout.
    }

    function test_rejectedNativeProtocolPayoutPreservesClaimsAndAllowsRotation() public {
        NativePayoutReceiver old = new NativePayoutReceiver();
        old.configure(true, address(0), "");
        (PoolKey memory key, uint256 id) = seedNative(address(old));
        uint256 lpOwed = ramp.userPosition(id, address(this)).owed0;
        uint256 before = address(this).balance;
        ramp.claimFees(key, -120, 120, address(this), 1000);
        assertEq(address(this).balance - before, lpOwed, "rejecting treasury cannot block LP claims");
        uint256 debt = ramp.claimFeeOwed(address(0));
        uint256 held = manager.balanceOf(address(ramp), 0);
        vm.expectRevert();
        ramp.sweepClaimFee(key.currency0);
        assertEq(ramp.claimFeeOwed(address(0)), debt);
        assertEq(manager.balanceOf(address(ramp), 0), held);
        assertEq(ramp.pendingClaimFeeCurrencyCount(), 1);
        address next = makeAddr("accepting native treasury");
        ramp.setClaimFee(key, new Currency[](0), 1000, next);
        ramp.sweepClaimFee(key.currency0);
        assertEq(next.balance, debt);
        assertEq(address(old).balance, 0);
        assertEq(manager.balanceOf(address(ramp), 0), held - debt);
    }

    function test_nativeLpPayoutRollsBackOnRejectAndBlocksReentry() public {
        (PoolKey memory key, uint256 id) = seedNative(makeAddr("treasury"));
        NativePayoutReceiver receiver = new NativePayoutReceiver();
        receiver.configure(true, address(0), "");
        uint256 owed = ramp.userPosition(id, address(this)).owed0;
        uint256 held = manager.balanceOf(address(ramp), 0);
        vm.expectRevert();
        ramp.claimFees(key, -120, 120, address(receiver), 1000);
        assertEq(ramp.userPosition(id, address(this)).owed0, owed);
        assertEq(manager.balanceOf(address(ramp), 0), held);
        receiver.configure(
            false, address(ramp), abi.encodeCall(Ramp.claimFees, (key, -120, 120, address(receiver), 1000))
        );
        ramp.claimFees(key, -120, 120, address(receiver), 1000);
        assertEq(address(receiver).balance, owed);
        assertFalse(receiver.callbackSucceeded());
        assertEq(
            receiver.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(manager.balanceOf(address(ramp), 0), held - owed);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
    }

    function test_nativeProtocolPayoutBlocksReentry() public {
        NativePayoutReceiver receiver = new NativePayoutReceiver();
        (PoolKey memory key,) = seedNative(address(receiver));
        uint256 debt = ramp.claimFeeOwed(address(0));
        receiver.configure(false, address(ramp), abi.encodeCall(Ramp.sweepClaimFee, (key.currency0)));
        ramp.sweepClaimFee(key.currency0);
        assertEq(address(receiver).balance, debt);
        assertFalse(receiver.callbackSucceeded());
        assertEq(
            receiver.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(ramp.claimFeeOwed(address(0)), 0);
    }

    function test_nativeRefundCannotConsumeClaimsOrForeignBalance() public {
        (PoolKey memory key,) = seedNative(makeAddr("treasury"));
        uint256 held = manager.balanceOf(address(ramp), 0);
        assertGt(held, 0);
        vm.deal(address(ramp), 1234); // Forced, unattributed native balance is never a deposit refund.
        ramp.deposit{value: 2 ether}(key, -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
        assertEq(address(ramp).balance, 1234);
        assertEq(manager.balanceOf(address(ramp), 0), held);
    }

    function testFuzz_multiPoolNativeAndTokenClaimsStaySolvent(uint256 random) public {
        PoolKey[2] memory keys;
        keys[0] = _key();
        keys[1] = _key();
        keys[1].tickSpacing = 20;
        address treasury = makeAddr("fuzz treasury");
        address payout = makeAddr("fuzz fee payout");
        address[2] memory owners = [address(this), makeAddr("fuzz LP")];
        uint256[2] memory ids;
        stable.approve(address(swapRouter), type(uint256).max);
        stable.mint(owners[1], 1e24);
        vm.deal(owners[1], 10 ether);
        vm.prank(owners[1]);
        stable.approve(address(ramp), type(uint256).max);
        for (uint256 i; i < 2; i++) {
            ramp.setPoolConfig(keys[i], 100, 700, 6000);
            ramp.setClaimFee(keys[i], new Currency[](0), uint16(1000 + i * 500), treasury);
            manager.initialize(keys[i], Constants.SQRT_PRICE_1_1);
            ramp.deposit{value: 1 ether}(keys[i], -120, 120, 1e18, 1 ether, type(uint128).max, block.timestamp);
            ids[i] = ramp.rangeId(keys[i].toId(), -120, 120);
            ramp.transfer(owners[1], ids[i], 4e17);
        }
        uint256[2] memory gross;
        for (uint256 i; i < 16; i++) {
            random = uint256(keccak256(abi.encode(random, i)));
            uint256 index = random % 2;
            PoolKey memory key = keys[index];
            uint256 ownerIndex = (random >> 8) % 2;
            address owner = owners[ownerIndex];
            vm.recordLogs();
            swap(key, (random >> 16) % 2 == 0, -int256(1e8 + (random >> 32) % 1e12), "");
            uint256 action = (random >> 24) % 5;
            vm.startPrank(owner);
            if (action == 0) {
                ramp.claimFees(key, -120, 120, payout, 2000);
            } else if (action == 1) {
                ramp.transfer(owners[1 - ownerIndex], ids[index], 1e10);
            } else if (action == 2) {
                ramp.deposit{value: 1 ether}(key, -120, 120, 1e10, 1 ether, type(uint128).max, block.timestamp);
            } else if (action == 3) {
                ramp.withdraw(key, -120, 120, 1e10, owner, 0, 0, block.timestamp);
            } else {
                ramp.claimFees(key, -120, 120, payout, 2000);
                ramp.sweepClaimFee(key.currency0);
                ramp.sweepClaimFee(key.currency1);
            }
            vm.stopPrank();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; j++) {
                if (
                    logs[j].emitter == address(ramp)
                        && logs[j].topics[0] == keccak256("FeesCollected(uint256,uint256,uint256,uint128)")
                ) {
                    (uint256 a0, uint256 a1,) = abi.decode(logs[j].data, (uint256, uint256, uint128));
                    gross[0] += a0;
                    gross[1] += a1;
                }
            }
            assertNativeSolvency(ids, owners, payout, treasury, gross);
        }
    }

    function assertNativeSolvency(
        uint256[2] memory ids,
        address[2] memory owners,
        address payout,
        address treasury,
        uint256[2] memory gross
    ) private view {
        uint256 liability0 = ramp.claimFeeOwed(address(0));
        uint256 liability1 = ramp.claimFeeOwed(address(stable));
        for (uint256 i; i < 2; i++) {
            RangeState memory state = ramp.rangeState(ids[i]);
            uint256 shares;
            for (uint256 j; j < 2; j++) {
                UserPosition memory p = ramp.userPosition(ids[i], owners[j]);
                (uint128 r0, uint128 r1) = ramp.userFeeRemainder(ids[i], owners[j]);
                uint256 units = ramp.balanceOf(owners[j], ids[i]);
                shares += units;
                liability0 += p.owed0 + (units * (state.accFee0X128 - p.checkpoint0X128) + r0) / (1 << 128);
                liability1 += p.owed1 + (units * (state.accFee1X128 - p.checkpoint1X128) + r1) / (1 << 128);
            }
            assertEq(shares, state.totalShares);
        }
        uint256 held0 = manager.balanceOf(address(ramp), 0);
        uint256 held1 = manager.balanceOf(address(ramp), uint256(uint160(address(stable))));
        assertLe(liability0, held0);
        assertLe(liability1, held1);
        assertEq(payout.balance + treasury.balance + held0, gross[0]);
        assertEq(stable.balanceOf(payout) + stable.balanceOf(treasury) + held1, gross[1]);
        assertEq(address(ramp).balance, 0);
        assertEq(stable.balanceOf(address(ramp)), 0);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(stable)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: ramp
        });
    }
}
