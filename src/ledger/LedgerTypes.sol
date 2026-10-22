// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Immutable Uniswap v4 coordinates of one shared LP range.
struct RangeKey {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    bool set;
}

struct RangeState {
    uint128 totalShares;
    uint256 accFee0X128;
    uint256 accFee1X128;
    uint64 collectionSeq;
    uint64 resetSeq;
}

struct UserPosition {
    uint128 owed0;
    uint128 owed1;
    uint256 checkpoint0X128;
    uint256 checkpoint1X128;
}
