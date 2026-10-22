// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Per-pool fee history. Only its immutable ledger may append policy changes.
/// @dev Isolated storage keeps both ERC-20 and RWA hook runtime below EIP-170.
contract ClaimFeePolicy {
    struct Change {
        uint64 fromTs;
        uint16 bps;
    }

    struct Policy {
        uint16 bps;
        uint16 minimum;
        Change[] history;
    }
    mapping(PoolId => Policy) private policies;
    address public immutable ledger;
    error Unauthorized();
    error InvalidRate();

    constructor() {
        ledger = msg.sender;
    }

    function record(PoolId id, uint16 bps) external {
        if (msg.sender != ledger) revert Unauthorized();
        if (bps > 2000) revert InvalidRate();
        Policy storage p = policies[id];
        if (p.history.length == 0 || bps < p.minimum) p.minimum = bps;
        p.bps = bps;
        p.history.push(Change(uint64(block.timestamp), bps));
    }

    function current(PoolId id) external view returns (uint16) {
        return policies[id].bps;
    }

    function length(PoolId id) external view returns (uint256) {
        return policies[id].history.length;
    }

    function minimum(PoolId id) external view returns (uint16) {
        return policies[id].minimum;
    }

    function changeAt(PoolId id, uint256 i) external view returns (Change memory) {
        return policies[id].history[i];
    }

    /// @notice Minimum rate from the entry in force at the range's sync cursor onward.
    /// @dev A zero cursor preserves the pre-configuration zero-rate window. The walk
    ///      includes the starting entry and reads at most 32 records; truncation can
    ///      use an earlier all-time minimum, intentionally favouring LPs.
    function effective(PoolId id, uint64 since) external view returns (uint16 rate) {
        if (since == 0) return 0;
        Policy storage p = policies[id];
        rate = p.bps;
        uint256 stop = since - 1;
        uint256 i = p.history.length;
        uint256 count;
        while (i > stop && count < 32) {
            uint16 past = p.history[--i].bps;
            if (past < rate) rate = past;
            count++;
        }
        if (i > stop && p.minimum < rate) rate = p.minimum;
    }
}
