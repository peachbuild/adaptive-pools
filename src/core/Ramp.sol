// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ClaimFeePolicy} from "../ledger/ClaimFeePolicy.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "../hooks/BaseHook.sol";
import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RangeKey, RangeState, UserPosition} from "../ledger/LedgerTypes.sol";

/// @notice ERC-20-only implementation of a Fables-style v4 liquidity desk.
contract Ramp is BaseHook, IUnlockCallback, ERC6909, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;
    uint256 private constant Q128 = 1 << 128;
    uint16 public constant MAX_CLAIM_FEE_BPS = 2_000;
    uint256 public constant MAX_CLAIM_BATCH = 100;
    uint256 public constant MAX_PAUSE = 7 days;
    enum Action {
        Deposit,
        Withdraw,
        Collect,
        Payout
    }

    struct UnlockData {
        Action action;
        address account;
        PoolKey key;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint128 limit0;
        uint128 limit1;
        address recipient;
    }

    struct FeeRemainder {
        uint128 amount0X128;
        uint128 amount1X128;
    }

    struct ClaimParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint16 maxFeeBps;
    }

    struct PayoutData {
        Currency currency0;
        Currency currency1;
        address recipient;
        uint256 amount0;
        uint256 amount1;
    }

    mapping(uint256 => RangeKey) private keys;
    mapping(uint256 => RangeState) private states;
    mapping(uint256 => mapping(address => UserPosition)) private positions;
    mapping(uint256 => mapping(address => FeeRemainder)) private feeRemainders;
    mapping(uint256 => uint64) public claimFeeSyncIndex;
    ClaimFeePolicy public immutable claimFeePolicy;
    mapping(PoolId => uint256) public pausedUntilOf;
    uint256 public constant MAX_CLAIM_FEE_WALK = 32;
    uint256 public pausedUntil;
    address public claimFeeRecipient;
    mapping(address => uint256) public claimFeeOwed;
    uint256 public pendingClaimFeeCurrencyCount;
    mapping(address owner => mapping(uint256 id => mapping(address operator => bool approved))) public isClaimOperator;
    error UnauthorizedClaimOperator();
    event ClaimOperatorSet(address indexed owner, uint256 indexed rangeId, address indexed operator, bool approved);

    error DeadlineExpired();
    error LedgerPaused();
    error PauseTooLong();
    error ZeroLiquidity();
    error ZeroShares();
    error RangeUnset();
    error PrincipalAboveMax(uint256, uint256);
    error PrincipalBelowMin(uint256, uint256);
    error InsufficientBalance();
    error NothingToClaim();
    error InvalidBatchSize();
    error ClaimFeeAboveMax();
    error NotPoolManagerCallback();
    error InvalidRecipient();
    error InvalidClaimFee();
    event Deposited(
        address indexed owner,
        uint256 indexed rangeId,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event Withdrawn(
        address indexed owner,
        uint256 indexed rangeId,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        address to
    );
    event FeesClaimed(address indexed owner, uint256 indexed rangeId, uint256 amount0, uint256 amount1, address to);
    event FeesCollected(uint256 indexed rangeId, uint256 fee0, uint256 fee1, uint128 totalShares);
    event RangeLifecycleChanged(
        uint256 indexed rangeId,
        uint64 resetSeq,
        uint128 totalShares,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    );
    event PausedSet(uint256 pausedUntil);
    event ClaimFeeSet(PoolId indexed poolId, uint16 bps, address recipient);
    event ClaimFeeAccrued(uint256 indexed rangeId, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint16 bps);
    event PoolPausedSet(PoolId indexed poolId, uint256 pausedUntil);
    event ClaimFeeSwept(address indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager manager_, address authority_, uint24 absoluteMaxFee_)
        BaseHook(manager_, authority_, absoluteMaxFee_)
    {
        claimFeePolicy = new ClaimFeePolicy();
    }

    modifier live() {
        if (block.timestamp < pausedUntil) {
            revert LedgerPaused();
        }
        _;
    }

    function rangeId(PoolId poolId, int24 lower, int24 upper) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, lower, upper)));
    }

    function rangeKey(uint256 id) external view returns (PoolKey memory key, int24 lower, int24 upper, bool set) {
        RangeKey storage r = keys[id];
        return (r.key, r.tickLower, r.tickUpper, r.set);
    }

    function rangeState(uint256 id) external view returns (RangeState memory) {
        return states[id];
    }

    function userPosition(uint256 id, address owner) external view returns (UserPosition memory) {
        return positions[id][owner];
    }

    /// @notice Fractional token base units retained for this owner, denominated in Q128.
    /// @dev Fractions stay with the owner after claims, share transfers and full exits.
    function userFeeRemainder(uint256 id, address owner)
        external
        view
        returns (uint128 amount0X128, uint128 amount1X128)
    {
        FeeRemainder storage r = feeRemainders[id][owner];
        return (r.amount0X128, r.amount1X128);
    }

    /// @notice Live PoolManager growth before this ledger's protocol skim, matching Fables.
    /// @dev Not a claimable balance. Use rangeState for synchronized net accumulators;
    /// establish a new live-growth baseline whenever resetSeq changes.
    function rangeGrowth(uint256 id) public view returns (uint256, uint256) {
        RangeKey storage r = keys[id];
        if (!r.set) return (0, 0);
        return StateLibrary.getFeeGrowthInside(poolManager, r.key.toId(), r.tickLower, r.tickUpper);
    }

    /// @notice Whether a guarded ledger operation is in progress.
    /// @dev External valuation adapters should refuse in-flight settlement reads.
    function isSettling() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    function paused() external view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    function setPaused(uint256 duration) external restricted {
        if (duration > MAX_PAUSE) {
            revert PauseTooLong();
        }
        pausedUntil = block.timestamp + duration;
        emit PausedSet(pausedUntil);
    }

    /// @notice Sets this pool's revenue rate and the Hook-wide protocol treasury.
    /// @dev Does not synchronize ranges. Backlogs use their minimum historical rate.
    ///      Named currencies' recorded protocol debt is paid to the old treasury;
    ///      unlisted debt and future collections follow the new treasury.
    function setClaimFee(PoolKey calldata key, Currency[] calldata settleFirst, uint16 bps, address recipient)
        external
        restricted
        nonReentrant
    {
        _checkKey(key);
        if ((bps != 0 && recipient == address(0)) || (claimFeeRecipient != address(0) && recipient == address(0))) {
            revert InvalidClaimFee();
        }
        if (recipient != address(0)) _validRecipient(recipient);
        for (uint256 i; i < settleFirst.length; i++) {
            _sweepClaimFee(settleFirst[i]);
        }
        // Fables semantics: only named currencies are paid to the outgoing recipient.
        // Unlisted debt follows the new recipient; the currency count is informational.
        claimFeeRecipient = recipient;
        _recordClaimFee(key.toId(), bps);
    }

    /// @dev Rate-only change; preserves the treasury and does not synchronize ranges.
    function setClaimFeeBps(PoolKey calldata key, uint16 bps) external restricted nonReentrant {
        _checkKey(key);
        if (claimFeeRecipient == address(0)) revert InvalidClaimFee();
        _recordClaimFee(key.toId(), bps);
    }

    function _recordClaimFee(PoolId id, uint16 bps) private {
        if (bps > MAX_CLAIM_FEE_BPS) revert ClaimFeeAboveMax();
        claimFeePolicy.record(id, bps);
        emit ClaimFeeSet(id, bps, claimFeeRecipient);
    }

    function claimFeeBps(PoolId id) external view returns (uint16) {
        _readClaimFeePolicy(ClaimFeePolicy.current.selector);
    }

    function claimFeeHistoryLength(PoolId id) external view returns (uint256) {
        _readClaimFeePolicy(ClaimFeePolicy.length.selector);
    }

    function claimFeeChangeAt(PoolId id, uint256 i) external view returns (ClaimFeePolicy.Change memory) {
        _readClaimFeePolicy(ClaimFeePolicy.changeAt.selector);
    }

    function claimFeeAllTimeMin(PoolId id) external view returns (uint16) {
        _readClaimFeePolicy(ClaimFeePolicy.minimum.selector);
    }

    /// @dev Forward read-only ABI-compatible results from the immutable policy component.
    /// Sharing this forwarding path avoids four separate call/return encoders in RWA runtime.
    function _readClaimFeePolicy(bytes4 selector) private view {
        address target = address(claimFeePolicy);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            calldatacopy(add(ptr, 4), 4, sub(calldatasize(), 4))
            let ok := staticcall(gas(), target, ptr, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)
            if ok { return(ptr, size) }
            revert(ptr, size)
        }
    }

    function claimFeeFor(PoolId id, uint64 sinceIndex) public view returns (uint16) {
        return claimFeeRecipient == address(0) ? 0 : claimFeePolicy.effective(id, sinceIndex);
    }

    function effectiveClaimFee(uint256 id) public view returns (uint16) {
        if (states[id].totalShares == 0) return 0;
        return claimFeeFor(keys[id].key.toId(), claimFeeSyncIndex[id]);
    }

    function pausedFor(PoolId id) public view returns (bool) {
        return block.timestamp < pausedUntil || block.timestamp < pausedUntilOf[id];
    }

    function _requireLive(PoolId id) internal view override {
        if (pausedFor(id)) revert LedgerPaused();
    }

    function setPoolPaused(PoolKey calldata key, uint256 duration) external restricted {
        _checkKey(key);
        if (duration > MAX_PAUSE) revert PauseTooLong();
        uint256 until = duration == 0 ? 0 : block.timestamp + duration;
        pausedUntilOf[key.toId()] = until;
        emit PoolPausedSet(key.toId(), until);
    }

    function pause(uint256 duration) external restricted {
        uint256 until = block.timestamp + duration;
        if (duration == 0 || duration > MAX_PAUSE || until <= pausedUntil) revert PauseTooLong();
        pausedUntil = until;
        emit PausedSet(until);
    }

    function pausePool(PoolKey calldata key, uint256 duration) external restricted {
        _checkKey(key);
        PoolId id = key.toId();
        uint256 until = block.timestamp + duration;
        if (duration == 0 || duration > MAX_PAUSE || until <= pausedUntilOf[id]) revert PauseTooLong();
        pausedUntilOf[id] = until;
        emit PoolPausedSet(id, until);
    }

    function transfer(address receiver, uint256 id, uint256 amount) public override nonReentrant returns (bool) {
        _beforeShareTransfer(msg.sender, receiver, id, amount);
        bool success = super.transfer(receiver, id, amount);
        return success;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override
        nonReentrant
        returns (bool)
    {
        _beforeShareTransfer(sender, receiver, id, amount);
        bool success = super.transferFrom(sender, receiver, id, amount);
        return success;
    }

    /// @dev Payable permits RampETH to override this entry point for native deposits.
    ///      This ERC-20 implementation rejects nonzero msg.value atomically.
    function deposit(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable virtual nonReentrant live {
        if (msg.value != 0) revert NativeNotSupported();
        _deposit(key, lower, upper, liquidity, amount0Max, amount1Max, deadline);
    }

    function _deposit(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) internal {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (liquidity == 0) {
            revert ZeroLiquidity();
        }
        _checkKey(key);
        _requireLive(key.toId());
        uint256 id = _ensureRange(key, lower, upper);
        _syncRange(id);
        _checkpoint(id, msg.sender);
        bool recreated = states[id].totalShares == 0;
        if (recreated) states[id].resetSeq++;
        // Settle old fees before minting, then finish ownership accounting before
        // the principal token can call out. This hook has no add-liquidity callbacks.
        states[id].totalShares += liquidity;
        _mint(msg.sender, id, liquidity);
        _unlock(
            UnlockData(Action.Deposit, msg.sender, key, lower, upper, liquidity, amount0Max, amount1Max, msg.sender)
        );
        if (recreated) _emitLifecycle(id);
    }

    function withdraw(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external nonReentrant {
        _withdraw(key, lower, upper, liquidity, to, amount0Min, amount1Min, deadline);
    }

    function withdrawAndClaim(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline,
        uint16 maxFeeBps
    ) external nonReentrant live {
        _checkKey(key);
        _requireLive(key.toId());
        uint256 id = rangeId(key.toId(), lower, upper);
        if (maxFeeBps < effectiveClaimFee(id)) revert ClaimFeeAboveMax();
        _withdraw(key, lower, upper, liquidity, to, amount0Min, amount1Min, deadline);
        _claimFees(id, msg.sender, to);
    }

    function _withdraw(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) private returns (uint256 id) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (liquidity == 0) {
            revert ZeroLiquidity();
        }
        _checkKey(key);
        _requireLive(key.toId());
        id = rangeId(key.toId(), lower, upper);
        if (!keys[id].set) {
            revert RangeUnset();
        }
        if (balanceOf[msg.sender][id] < liquidity) revert InsufficientBalance();
        _validRecipient(to);
        _syncRange(id);
        _checkpoint(id, msg.sender);
        _burn(msg.sender, id, liquidity);
        states[id].totalShares -= liquidity;
        bool emptied = states[id].totalShares == 0;
        if (emptied) states[id].resetSeq++;
        _syncDebt(id, msg.sender);
        _unlock(UnlockData(Action.Withdraw, msg.sender, key, lower, upper, liquidity, amount0Min, amount1Min, to));
        if (emptied) _emitLifecycle(id);
    }

    function _emitLifecycle(uint256 id) private {
        (uint256 g0, uint256 g1) = rangeGrowth(id);
        RangeState storage s = states[id];
        emit RangeLifecycleChanged(id, s.resetSeq, s.totalShares, g0, g1);
    }

    function _syncRange(uint256 id) private {
        RangeKey storage r = keys[id];
        if (states[id].totalShares == 0) {
            claimFeeSyncIndex[id] = uint64(claimFeePolicy.length(r.key.toId()));
            return;
        }
        _unlock(UnlockData(Action.Collect, msg.sender, r.key, r.tickLower, r.tickUpper, 0, 0, 0, address(this)));
    }

    /// @notice Authorize fee payouts for a range, independently of ERC-6909 share approvals.
    /// @dev Persists across exits/redeposits. Operators may choose the recipient and fee cap.
    function setClaimOperator(uint256 id, address operator, bool approved) external {
        isClaimOperator[msg.sender][id][operator] = approved;
        emit ClaimOperatorSet(msg.sender, id, operator, approved);
    }

    function claimFees(PoolKey calldata key, int24 lower, int24 upper, address to, uint16 maxFeeBps) external {
        claimFeesFor(key, lower, upper, msg.sender, to, maxFeeBps);
    }

    /// @notice Claim an owner's fees as the owner or their explicitly authorized range operator.
    function claimFeesFor(PoolKey calldata key, int24 lower, int24 upper, address owner, address to, uint16 maxFeeBps)
        public
        nonReentrant
        live
    {
        uint256 id = _claimRange(key, lower, upper, owner);
        _validRecipient(to);
        if (!_claimWithLimit(id, owner, to, maxFeeBps)) revert NothingToClaim();
    }

    /// @notice Atomically claim the caller's fees across up to 100 ranges of this hook.
    /// @dev Empty earnings are skipped only after all claim validations pass. Never withdraws principal.
    function claimFeesBatch(ClaimParams[] calldata items, address to) external nonReentrant live {
        if (items.length == 0 || items.length > MAX_CLAIM_BATCH) revert InvalidBatchSize();
        _validRecipient(to);
        for (uint256 i; i < items.length; ++i) {
            ClaimParams calldata item = items[i];
            uint256 id = _claimRange(item.key, item.tickLower, item.tickUpper, msg.sender);
            _claimWithLimit(id, msg.sender, to, item.maxFeeBps);
        }
    }

    function _claimRange(PoolKey calldata key, int24 lower, int24 upper, address owner)
        private
        view
        returns (uint256 id)
    {
        _checkKey(key);
        id = rangeId(key.toId(), lower, upper);
        if (msg.sender != owner && !isClaimOperator[owner][id][msg.sender]) revert UnauthorizedClaimOperator();
        if (!keys[id].set) revert RangeUnset();
        _requireLive(key.toId());
    }

    function _claimWithLimit(uint256 id, address owner, address to, uint16 maxFeeBps) private returns (bool) {
        if (maxFeeBps < effectiveClaimFee(id)) revert ClaimFeeAboveMax();
        if (balanceOf[owner][id] == 0 && positions[id][owner].owed0 == 0 && positions[id][owner].owed1 == 0) {
            return false;
        }
        _claimFees(id, owner, to);
        return true;
    }

    function _claimFees(uint256 id, address owner, address to) private {
        _syncRange(id);
        _checkpoint(id, owner);
        UserPosition storage p = positions[id][owner];
        uint256 a0 = p.owed0;
        uint256 a1 = p.owed1;
        if (a0 == 0 && a1 == 0) return;
        p.owed0 = 0;
        p.owed1 = 0;
        PoolKey storage key = keys[id].key;
        _payout(key.currency0, key.currency1, to, a0, a1);
        emit FeesClaimed(owner, id, a0, a1, to);
    }

    function sweepClaimFee(Currency currency) external nonReentrant live {
        _sweepClaimFee(currency);
    }

    function _sweepClaimFee(Currency currency) internal virtual {
        uint256 amount = _consumeClaimFee(currency);
        if (amount == 0) return;
        _payout(currency, currency, claimFeeRecipient, amount, 0);
        emit ClaimFeeSwept(Currency.unwrap(currency), claimFeeRecipient, amount);
    }

    function _accrueClaimFee(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        if (claimFeeOwed[token] == 0) pendingClaimFeeCurrencyCount++;
        claimFeeOwed[token] += amount;
    }

    /// @dev Clear debt before external payment; a failed payout reverts both updates.
    /// Native and ERC-20 debts follow the same counting rules.
    function _consumeClaimFee(Currency currency) internal returns (uint256 amount) {
        address token = Currency.unwrap(currency);
        amount = claimFeeOwed[token];
        if (amount == 0) return 0;
        claimFeeOwed[token] = 0;
        pendingClaimFeeCurrencyCount--;
    }

    function _validRecipient(address to) private view {
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert InvalidRecipient();
    }

    function _payout(Currency currency0, Currency currency1, address to, uint256 amount0, uint256 amount1) private {
        if (amount0 == 0 && amount1 == 0) return;
        poolManager.unlock(
            abi.encode(Action.Payout, abi.encode(PayoutData(currency0, currency1, to, amount0, amount1)))
        );
    }

    function _redeem(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) {
            revert NotPoolManagerCallback();
        }
        (Action action, bytes memory payload) = abi.decode(raw, (Action, bytes));
        if (action == Action.Payout) {
            PayoutData memory payment = abi.decode(payload, (PayoutData));
            _redeem(payment.currency0, payment.recipient, payment.amount0);
            _redeem(payment.currency1, payment.recipient, payment.amount1);
            return "";
        }
        UnlockData memory d = abi.decode(payload, (UnlockData));
        uint256 id = rangeId(d.key.toId(), d.lower, d.upper);
        ModifyLiquidityParams memory p = ModifyLiquidityParams(
            d.lower,
            d.upper,
            d.action == Action.Withdraw
                ? -int256(uint256(d.liquidity))
                : d.action == Action.Deposit ? int256(uint256(d.liquidity)) : int256(0),
            bytes32(id)
        );
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(d.key, p, "");
        // Fees belong to the pre-mutation owners, never to the principal recipient.
        uint256 f0 = _mintFees(d.key.currency0, fees.amount0());
        uint256 f1 = _mintFees(d.key.currency1, fees.amount1());
        _accrue(id, f0, f1);
        if (d.action == Action.Collect) return "";
        BalanceDelta principal = delta - fees;
        int128 x = principal.amount0();
        int128 y = principal.amount1();
        if (d.action == Action.Deposit) {
            _payIfNegative(d.key.currency0, x, d.account, d.limit0);
            _payIfNegative(d.key.currency1, y, d.account, d.limit1);
            emit Deposited(
                d.account,
                id,
                d.key.toId(),
                d.lower,
                d.upper,
                d.liquidity,
                x < 0 ? uint256(-int256(x)) : 0,
                y < 0 ? uint256(-int256(y)) : 0
            );
        } else {
            uint256 a0 = _takeIfPositive(d.key.currency0, x, d.recipient);
            uint256 a1 = _takeIfPositive(d.key.currency1, y, d.recipient);
            if (a0 < d.limit0) revert PrincipalBelowMin(a0, d.limit0);
            if (a1 < d.limit1) revert PrincipalBelowMin(a1, d.limit1);
            emit Withdrawn(d.account, id, d.key.toId(), d.lower, d.upper, d.liquidity, a0, a1, d.recipient);
        }
        return "";
    }

    function _ensureRange(PoolKey calldata key, int24 lower, int24 upper) private returns (uint256 id) {
        if (lower >= upper || lower % key.tickSpacing != 0 || upper % key.tickSpacing != 0) {
            revert InvalidConfig();
        }
        id = rangeId(key.toId(), lower, upper);
        if (!keys[id].set) {
            keys[id] = RangeKey(key, lower, upper, true);
        }
    }

    function _unlock(UnlockData memory d) private {
        poolManager.unlock(abi.encode(d.action, abi.encode(d)));
    }

    /// @dev Retain real tokens in PoolManager; only payout redeems these claims.
    function _mintFees(Currency currency, int128 amount) private returns (uint256 fee) {
        if (amount <= 0) return 0;
        fee = uint256(uint128(amount));
        poolManager.mint(address(this), currency.toId(), fee);
    }

    function _payIfNegative(Currency c, int128 a, address from, uint128 maximum) internal virtual {
        if (a >= 0) {
            return;
        }
        uint256 v = uint256(uint128(-a));
        if (v > maximum) {
            revert PrincipalAboveMax(v, maximum);
        }
        address token = Currency.unwrap(c);
        poolManager.sync(c);
        IERC20(token).safeTransferFrom(from, address(poolManager), v);
        poolManager.settle();
    }

    function _takeIfPositive(Currency c, int128 a, address to) private returns (uint256 v) {
        if (a <= 0) {
            return 0;
        }
        v = uint256(uint128(a));
        poolManager.take(c, to, v);
    }

    function _accrue(uint256 id, uint256 a0, uint256 a1) private {
        RangeState storage s = states[id];
        PoolId pool = keys[id].key.toId();
        uint16 rate = effectiveClaimFee(id);
        claimFeeSyncIndex[id] = uint64(claimFeePolicy.length(pool));
        if (s.totalShares == 0 || (a0 == 0 && a1 == 0)) return;
        uint256 cut0 = a0 * rate / 10000;
        uint256 cut1 = a1 * rate / 10000;
        _accrueClaimFee(keys[id].key.currency0, cut0);
        _accrueClaimFee(keys[id].key.currency1, cut1);
        if (cut0 != 0 || cut1 != 0) emit ClaimFeeAccrued(id, pool, cut0, cut1, rate);
        s.accFee0X128 += FullMath.mulDiv(a0 - cut0, Q128, s.totalShares);
        s.accFee1X128 += FullMath.mulDiv(a1 - cut1, Q128, s.totalShares);
        s.collectionSeq++;
        emit FeesCollected(id, a0, a1, s.totalShares);
    }

    function _checkpoint(uint256 id, address account) private {
        RangeState storage s = states[id];
        UserPosition storage p = positions[id][account];
        FeeRemainder storage r = feeRemainders[id][account];
        uint256 units = balanceOf[account][id];
        uint256 a0;
        uint256 a1;
        (a0, r.amount0X128) = _earnedWithRemainder(units, s.accFee0X128 - p.checkpoint0X128, r.amount0X128);
        (a1, r.amount1X128) = _earnedWithRemainder(units, s.accFee1X128 - p.checkpoint1X128, r.amount1X128);
        if (a0 > type(uint128).max || a1 > type(uint128).max) revert InvalidConfig();
        p.owed0 += uint128(a0);
        p.owed1 += uint128(a1);
        _syncDebt(id, account);
    }

    function _earnedWithRemainder(uint256 units, uint256 growth, uint128 previous)
        private
        pure
        returns (uint256 earned, uint128 remainder)
    {
        // Compute the quotient and remainder separately: units * growth may exceed 256 bits.
        uint256 fraction = mulmod(units, growth, Q128) + uint256(previous);
        earned = FullMath.mulDiv(units, growth, Q128) + fraction / Q128;
        // Modulo Q128 guarantees the remaining fraction fits in uint128.
        remainder = uint128(fraction % Q128);
    }

    function _syncDebt(uint256 id, address account) private {
        RangeState storage s = states[id];
        UserPosition storage p = positions[id][account];
        p.checkpoint0X128 = s.accFee0X128;
        p.checkpoint1X128 = s.accFee1X128;
    }

    /// @dev Settle past fees before inherited ERC-6909 mutates ownership. Failed
    /// authorization in the parent reverts the entire synchronization as well.
    /// The parent makes no external calls or growth changes, so these checkpoints
    /// also remain current after the transfer; no second debt snapshot is needed.
    function _beforeShareTransfer(address from, address to, uint256 id, uint256 a) private {
        _validRecipient(to);
        if (a == 0) revert ZeroShares();
        _requireLive(keys[id].key.toId());
        if (balanceOf[from][id] < a) revert InsufficientBalance();
        _syncRange(id);
        _checkpoint(id, from);
        _checkpoint(id, to);
    }
}
