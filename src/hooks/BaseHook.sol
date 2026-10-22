// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MidBlockFeeMath} from "./MidBlockFeeMath.sol";
import {FeePolicyMath} from "./FeePolicyMath.sol";

/// @notice Shared Uniswap v4 permission and dynamic-fee policy for Ramp hooks.
abstract contract BaseHook is IHooks, AccessManaged, ImmutableState {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    uint24 public constant MIN_POOL_FEE = 100;
    uint16 public constant MAX_POKE_DISCOUNT_BPS = 5000;
    uint40 public constant MAX_POKE_TTL = 72 hours;

    struct Config {
        uint24 floorPips;
        uint24 flatPips;
        uint24 maxFee;
        bool set;
    }

    struct Poke {
        uint24 fee0For1;
        uint24 fee1For0;
        uint40 expiry;
    }
    uint24 public immutable ABSOLUTE_MAX_FEE;

    struct Asymmetry {
        uint24 premiumPips;
        bool premiumZeroForOne;
    }
    mapping(PoolId => Asymmetry) internal asymmetries;
    mapping(PoolId => Config) internal configs;
    mapping(PoolId => Poke) internal pokes;

    struct MidBlockConfig {
        bool enabled;
        uint24 midThresholdPips;
        uint24 captureFractionE6;
        uint24 midCap;
    }

    struct MidBlockState {
        uint160 sqrtPriceX96;
        uint96 blockNumber;
    }

    MidBlockFeeMath public immutable midBlockFeeMath;
    FeePolicyMath private immutable feePolicyMath;
    mapping(PoolId => MidBlockConfig) public midBlockConfig;
    mapping(PoolId => MidBlockState) public midBlockState;
    uint256 private constant MID_BLOCK_MATH_GAS = 200_000;
    error NotDynamicFeePool();
    error PoolNotConfigured();
    error InvalidConfig();
    error InvalidTtl();
    error FeeBelowFloor();
    error FeeAboveCap();
    error InvalidMaxFee();
    error EmptyPoke();
    error PremiumExceedsFeeBand();
    error NativeNotSupported();
    event PoolAsymmetrySet(PoolId indexed poolId, uint24 premiumPips, bool premiumZeroForOne);
    event PoolConfigured(PoolId indexed poolId, uint24 floorPips, uint24 flatPips, uint24 maxFee);
    event FeePoked(PoolId indexed poolId, uint24 fee0For1, uint24 fee1For0, uint40 expiry);
    event PokeCleared(PoolId indexed poolId);

    constructor(IPoolManager manager_, address authority_, uint24 absoluteMaxFee_)
        AccessManaged(authority_)
        ImmutableState(manager_)
    {
        if (absoluteMaxFee_ == 0 || absoluteMaxFee_ > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidMaxFee();
        }
        ABSOLUTE_MAX_FEE = absoluteMaxFee_;
        midBlockFeeMath = new MidBlockFeeMath();
        feePolicyMath = new FeePolicyMath();
        Hooks.validateHookPermissions(IHooks(address(this)), _permissions());
    }

    /// @notice Configures the autonomous fee and hard boundaries for one dynamic-fee pool.
    function setPoolConfig(PoolKey calldata key, uint24 floorPips, uint24 flatPips, uint24 cap)
        external
        virtual
        restricted
    {
        _checkOwnPool(key);
        if (
            !key.fee.isDynamicFee() || floorPips < MIN_POOL_FEE || floorPips > flatPips || flatPips > cap
                || cap > ABSOLUTE_MAX_FEE
        ) {
            revert InvalidConfig();
        }
        PoolId id = key.toId();
        _setConfig(id, floorPips, flatPips, cap);
        emit PoolConfigured(id, floorPips, flatPips, cap);
    }

    function pokeFee(PoolId id, uint24 fee0For1, uint24 fee1For0, uint40 ttl) external restricted {
        _pokeFee(id, fee0For1, fee1For0, ttl);
    }

    /// @dev Shared by product-specific compatibility entry points. In particular, the
    /// native-asset Crypto ramp exposes Fables' legacy single-fee selector and maps it
    /// to the two directional slots.
    function _pokeFee(PoolId id, uint24 fee0For1, uint24 fee1For0, uint40 ttl) internal {
        Config memory c = _config(id);
        if (ttl == 0 || ttl > MAX_POKE_TTL) revert InvalidTtl();
        if (fee0For1 == 0 && fee1For0 == 0) revert EmptyPoke();
        if ((fee0For1 != 0 && fee0For1 < c.floorPips) || (fee1For0 != 0 && fee1For0 < c.floorPips)) {
            revert FeeBelowFloor();
        }
        if (fee0For1 > c.maxFee || fee1For0 > c.maxFee) revert FeeAboveCap();
        uint40 expiry = uint40(block.timestamp) + ttl;
        pokes[id] = Poke(fee0For1, fee1For0, expiry);
        emit FeePoked(id, fee0For1, fee1For0, expiry);
    }

    function setPoolAsymmetry(PoolKey calldata key, uint24 premiumPips, bool premiumZeroForOne) external restricted {
        _checkOwnPool(key);
        PoolId id = key.toId();
        Config memory c = _config(id);
        if (premiumPips > c.maxFee - c.floorPips) revert PremiumExceedsFeeBand();
        asymmetries[id] = Asymmetry(premiumPips, premiumZeroForOne);
        emit PoolAsymmetrySet(id, premiumPips, premiumZeroForOne);
    }

    function poolAsymmetry(PoolId id) external view returns (uint24 premiumPips, bool premiumZeroForOne) {
        Asymmetry memory a = asymmetries[id];
        return (a.premiumPips, a.premiumZeroForOne);
    }

    function clearPoke(PoolId id) external restricted {
        _config(id);
        delete pokes[id];
        emit PokeCleared(id);
    }

    function flatFee(PoolId id) external view returns (uint24) {
        return _config(id).flatPips;
    }

    function maxFee(PoolId id) external view returns (uint24) {
        return _config(id).maxFee;
    }

    /// @notice Configured floor, distinct from the live 50% execution-time guard.
    function pokeFloor(PoolId id) public view returns (uint24) {
        return _config(id).floorPips;
    }

    function pokeOf(PoolId id) external view returns (uint24 fee0For1, uint24 fee1For0, uint40 expiry) {
        Poke memory p = pokes[id];
        return (p.fee0For1, p.fee1For0, p.expiry);
    }

    function _baseFee(PoolId id) internal view virtual returns (uint256) {
        return _config(id).flatPips;
    }

    function autonomousFee(PoolId id, bool zeroForOne) public view returns (uint256 fee) {
        fee = _baseFee(id);
        Asymmetry memory a = asymmetries[id];
        if (zeroForOne == a.premiumZeroForOne) fee += a.premiumPips;
    }

    function currentFee(PoolId id, bool zeroForOne) public view returns (uint24) {
        Config memory c = _config(id);
        Poke memory p = pokes[id];
        return feePolicyMath.resolve(
            autonomousFee(id, zeroForOne),
            c.maxFee,
            c.floorPips,
            zeroForOne ? p.fee0For1 : p.fee1For0,
            p.expiry > block.timestamp
        );
    }

    event MidBlockConfigSet(PoolId indexed poolId, MidBlockConfig config);

    /// @notice Changing configuration invalidates the observation; the next swap seeds it.
    function setMidBlockConfig(PoolKey calldata key, MidBlockConfig calldata config) external restricted {
        _checkKey(key);
        if (
            config.midThresholdPips == 0 || config.midThresholdPips > 1_000_000 || config.captureFractionE6 > 1_000_000
                || config.midCap > ABSOLUTE_MAX_FEE
        ) revert InvalidConfig();
        PoolId id = key.toId();
        midBlockConfig[id] = config;
        delete midBlockState[id];
        // The static tuple was validated above and while storing it. Preserve
        // its event encoding without generating another struct encoder.
        bytes32 topic = keccak256("MidBlockConfigSet(bytes32,(bool,uint24,uint24,uint24))");
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, config, 128)
            log2(ptr, 128, topic, id)
            mstore(0x40, add(ptr, 128))
        }
    }

    /// @notice Current-state LP execution fee; does not write a block observation.
    function executionFee(PoolId id, bool zeroForOne) public view returns (uint24) {
        uint24 base = currentFee(id, zeroForOne);
        MidBlockConfig memory c = midBlockConfig[id];
        MidBlockState memory s = midBlockState[id];
        if (!c.enabled || s.blockNumber != block.number || s.sqrtPriceX96 == 0) return base;
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, id);
        bytes memory input = abi.encodeCall(
            MidBlockFeeMath.surcharge,
            (s.sqrtPriceX96, price, zeroForOne, c.midThresholdPips, c.captureFractionE6, c.midCap)
        );
        // Fixed output buffer: malformed/oversized returndata cannot cause a copy bomb.
        address target = address(midBlockFeeMath);
        uint256 extra;
        bool ok;
        assembly ("memory-safe") {
            let output := mload(0x40)
            ok := staticcall(MID_BLOCK_MATH_GAS, target, add(input, 32), mload(input), output, 32)
            ok := and(ok, eq(returndatasize(), 32))
            extra := mload(output)
        }
        if (!ok || extra > c.midCap) return base;
        uint256 fee;
        unchecked {
            fee = uint256(base) + extra; // Both inputs are bounded by uint24.
        }
        uint24 cap = configs[id].maxFee; // currentFee already validated this pool.
        return fee > cap ? cap : uint24(fee);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) {
            revert NotDynamicFeePool();
        }
        _checkKey(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        _requireLive(id);
        if (
            midBlockConfig[id].enabled
                && (midBlockState[id].blockNumber != block.number || midBlockState[id].sqrtPriceX96 == 0)
        ) {
            (uint160 price,,,) = StateLibrary.getSlot0(poolManager, id);
            midBlockState[id] = MidBlockState(price, uint96(block.number));
        }
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            executionFee(id, params.zeroForOne) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert NotPoolManager();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotPoolManager();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotPoolManager();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotPoolManager();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotPoolManager();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert NotPoolManager();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotPoolManager();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotPoolManager();
    }

    function _config(PoolId id) internal view returns (Config memory c) {
        c = configs[id];
        if (!c.set) {
            revert PoolNotConfigured();
        }
    }

    /// @dev The ledger's global/per-pool pause also gates PoolManager swaps.
    function _requireLive(PoolId id) internal view virtual;

    function _setConfig(PoolId id, uint24 floorPips, uint24 flatPips, uint24 cap) internal {
        if (cap == 0 || cap > ABSOLUTE_MAX_FEE) revert InvalidMaxFee();
        if (floorPips < MIN_POOL_FEE || floorPips > cap) revert InvalidConfig();
        if (asymmetries[id].premiumPips > cap - floorPips) revert PremiumExceedsFeeBand();
        configs[id] = Config(floorPips, flatPips, cap, true);
    }

    function _checkOwnPool(PoolKey memory key) internal view {
        if (address(key.hooks) != address(this)) revert PoolNotConfigured();
    }

    function _checkKey(PoolKey memory key) internal view virtual {
        _checkOwnPool(key);
        _config(key.toId());
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        if (Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0)) {
            revert NativeNotSupported();
        }
    }

    function _permissions() private pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions(
            true, false, false, false, false, false, true, false, false, false, false, false, false, false
        );
    }
}
