// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {Ramp} from "../src/core/Ramp.sol";
import {BaseHook} from "../src/hooks/BaseHook.sol";

contract RampTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint64 internal constant KEEPER_ROLE = 1;
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    AccessManager internal access;
    Ramp internal ramp;
    MockERC20 internal wbnb;
    MockERC20 internal stable;

    function setUp() public {
        deployFreshManagerAndRouters();
        wbnb = new MockERC20("Wrapped BNB", "WBNB", 18);
        stable = new MockERC20("USD Stable", "USDX", 18);
        wbnb.mint(address(this), 1e30);
        stable.mint(address(this), 1e30);

        access = new AccessManager(address(this));
        bytes memory args = abi.encode(manager, address(access), uint24(20_000));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG), type(Ramp).creationCode, args
        );
        ramp = new Ramp{salt: salt}(manager, address(access), 20_000);
        assertEq(address(ramp), predicted, "mined hook address");
        ramp.setPoolConfig(_key(), 100, 700, 6_000);
        wbnb.approve(address(ramp), type(uint256).max);
        stable.approve(address(ramp), type(uint256).max);
    }

    function test_hookAddressAndDynamicFeeTTL() public {
        PoolId id = _key().toId();
        assertEq(
            uint160(address(ramp)) & Hooks.ALL_HOOK_MASK, uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        );
        assertEq(ramp.currentFee(id, true), 700);

        _assignKeeper();
        vm.prank(keeper);
        ramp.pokeFee(id, 350, 350, 1 hours);
        assertEq(ramp.currentFee(id, true), 350);
        vm.warp(block.timestamp + 1 hours);
        assertEq(ramp.currentFee(id, true), 700, "expired poke restores the base fee");
    }

    function test_keeperCannotEscapeFeeBoundsOrRole() public {
        PoolId id = _key().toId();
        _assignKeeper();
        vm.prank(stranger);
        vm.expectRevert();
        ramp.pokeFee(id, 700, 700, 1 hours);

        vm.startPrank(keeper);
        vm.expectRevert(BaseHook.FeeBelowFloor.selector);
        ramp.pokeFee(id, 99, 99, 1 hours);
        vm.expectRevert(BaseHook.FeeAboveCap.selector);
        ramp.pokeFee(id, 6_001, 6_001, 1 hours);
        vm.expectRevert(BaseHook.InvalidTtl.selector);
        ramp.pokeFee(id, 700, 700, 73 hours);
        vm.stopPrank();
    }

    function test_depositTransferAndWithdrawSharedRange() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        uint128 shares = 1e18;
        ramp.deposit(key, -120, 120, shares, type(uint128).max, type(uint128).max, block.timestamp + 1);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        assertEq(ramp.balanceOf(address(this), id), shares);
        assertEq(ramp.rangeState(id).totalShares, shares);

        address receiver = makeAddr("share receiver");
        ramp.transfer(receiver, id, shares / 4);
        assertEq(ramp.balanceOf(receiver, id), shares / 4);
        ramp.withdraw(key, -120, 120, shares * 3 / 4, address(this), 0, 0, block.timestamp + 1);
        assertEq(ramp.balanceOf(address(this), id), 0);
        assertEq(ramp.rangeState(id).totalShares, shares / 4);
    }

    function test_initialProtocolRevenueConfigIsDisabled() public {
        assertEq(ramp.claimFeeBps(_key().toId()), 0);
    }

    function test_tokenomicsAndPublicSyncSelectorsAreAbsent() public {
        uint256[] memory ids = new uint256[](0);
        (bool syncOk,) = address(ramp).call(abi.encodeWithSignature("syncRanges(uint256,uint256[])", 0, ids));
        assertFalse(syncOk, "syncRanges removed from ABI");
        PoolKey memory key = _key();
        (bool stakeOk,) = address(ramp)
            .call(
                abi.encodeWithSignature(
                    "stake((address,address,uint24,int24,address),int24,int24,uint128)", key, -120, 120, uint128(1)
                )
            );
        assertFalse(stakeOk, "stake removed from ABI");
    }

    function test_pauseBlocksMutationsAndPrincipalExit() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        uint128 shares = 1e18;
        ramp.deposit(key, -120, 120, shares, type(uint128).max, type(uint128).max, block.timestamp + 1);
        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        ramp.pause(1 hours);

        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.deposit(key, -120, 120, 1, type(uint128).max, type(uint128).max, block.timestamp + 1);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.claimFees(key, -120, 120, address(this), 0);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.withdrawAndClaim(key, -120, 120, 1, address(this), 0, 0, block.timestamp + 1, 0);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.transfer(stranger, id, 1);
        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.sweepClaimFee(key.currency0);

        vm.expectRevert(Ramp.LedgerPaused.selector);
        ramp.withdraw(key, -120, 120, shares, address(this), 0, 0, block.timestamp + 1);
        assertEq(ramp.balanceOf(address(this), id), shares);
        ramp.setPaused(0);
        ramp.withdraw(key, -120, 120, shares, address(this), 0, 0, block.timestamp + 1);
        assertEq(ramp.balanceOf(address(this), id), 0);
    }

    function test_withdrawAndClaimPaysFeesAndHonorsMaximumFee() public {
        PoolKey memory key = _key();
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        ramp.setClaimFee(key, new Currency[](0), 1_000, makeAddr("treasury"));
        uint128 shares = 1e18;
        ramp.deposit(key, -120, 120, shares, type(uint128).max, type(uint128).max, block.timestamp + 1);
        wbnb.approve(address(swapRouter), type(uint256).max);
        stable.approve(address(swapRouter), type(uint256).max);
        swap(key, true, -int256(1e14), "");

        vm.expectRevert(Ramp.ClaimFeeAboveMax.selector);
        ramp.withdrawAndClaim(key, -120, 120, shares, address(this), 0, 0, block.timestamp + 1, 999);

        uint256 id = ramp.rangeId(key.toId(), -120, 120);
        uint256 before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        ramp.withdrawAndClaim(key, -120, 120, shares, address(this), 0, 0, block.timestamp + 1, 1_000);
        assertEq(ramp.balanceOf(address(this), id), 0);
        assertGt(MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)), before);
        assertGt(ramp.claimFeeOwed(Currency.unwrap(key.currency0)), 0);
        assertEq(ramp.userPosition(id, address(this)).owed0, 0);
    }

    function _assignKeeper() private {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BaseHook.pokeFee.selector;
        selectors[1] = BaseHook.clearPoke.selector;
        access.grantRole(KEEPER_ROLE, keeper, 0);
        access.setTargetFunctionRole(address(ramp), selectors, KEEPER_ROLE);
    }

    function _key() internal view returns (PoolKey memory key) {
        Currency a = Currency.wrap(address(wbnb));
        Currency b = Currency.wrap(address(stable));
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 10, hooks: ramp});
    }
}
