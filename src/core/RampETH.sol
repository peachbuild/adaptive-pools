// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ramp} from "./Ramp.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @notice Native-asset Crypto Ramp with both the legacy Fables single-fee API
/// and the directional fee API used by the current Crypto strategy.
/// @dev Native principal is prepaid by the depositor and settled only inside the
/// PoolManager unlock callback. LP/protocol fees remain as PoolManager claims
/// and are redeemed directly to recipients in their original currency.
contract RampETH is Ramp {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using Address for address payable;

    uint256 private nativePrepaid;

    error InvalidMsgValue();
    error UnauthorizedNativeSender();

    constructor(IPoolManager manager_, address authority_, uint24 absoluteMaxFee_)
        Ramp(manager_, authority_, absoluteMaxFee_)
    {}

    /// @notice FablesRampETH-compatible symmetric keeper update.
    /// @dev Both directional slots are set to the same value. The four-argument
    /// inherited overload remains available for directional Crypto strategies.
    function pokeFee(PoolId id, uint24 fee, uint40 ttl) external restricted {
        _pokeFee(id, fee, fee, ttl);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnauthorizedNativeSender();
    }

    function deposit(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable override nonReentrant live {
        bool nativePool = Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0);
        if (!nativePool) {
            if (msg.value != 0) revert InvalidMsgValue();
        } else {
            // v4's canonical ordering places native currency in currency0. Requiring
            // the caller to prepay the declared maximum keeps settlement atomic.
            if (Currency.unwrap(key.currency0) != address(0) || msg.value < amount0Max) revert InvalidMsgValue();
            nativePrepaid = msg.value;
        }

        _deposit(key, lower, upper, liquidity, amount0Max, amount1Max, deadline);

        uint256 refund = nativePrepaid;
        nativePrepaid = 0;
        if (refund != 0) {
            payable(msg.sender).sendValue(refund);
        }
    }

    function _checkKey(PoolKey memory key) internal view override {
        _checkOwnPool(key);
        _config(key.toId());
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
    }

    function _payIfNegative(Currency c, int128 a, address from, uint128 maximum) internal override {
        if (Currency.unwrap(c) != address(0)) {
            super._payIfNegative(c, a, from, maximum);
            return;
        }
        if (a >= 0) return;
        uint256 amount = uint256(uint128(-a));
        if (amount > maximum) revert PrincipalAboveMax(amount, maximum);
        if (amount > nativePrepaid) revert InvalidMsgValue();
        nativePrepaid -= amount;
        poolManager.sync(c);
        poolManager.settle{value: amount}();
    }
}
