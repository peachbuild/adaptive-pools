// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Session categories and fee-curve primitives for US-equity RWA pools.
library SessionLib {
    enum Session {
        OPEN,
        OVERNIGHT,
        CLOSED
    }

    enum DstMode {
        AUTO,
        FIXED_EST,
        FIXED_EDT
    }

    /// @dev Fee values are Uniswap v4 pips (1e-6).
    struct FloorConfig {
        uint24 openFloor;
        uint24 overnightFloor;
        uint24 closedFloor;
        uint8 spikeMult;
        uint24 closedSpike;
        uint32 descentWindow;
        uint24 closeFloor;
        uint32 closeBefore;
        uint32 closeAfter;
    }

    function descending(uint256 peak, uint256 floor, uint256 elapsed, uint256 window) internal pure returns (uint256) {
        if (window == 0 || elapsed >= window || peak <= floor) {
            return floor;
        }

        return floor + (peak - floor) * (window - elapsed) / window;
    }

    function ascending(uint256 floor, uint256 peak, uint256 elapsed, uint256 window) internal pure returns (uint256) {
        if (window == 0 || elapsed >= window || peak <= floor) {
            return peak;
        }

        return floor + (peak - floor) * elapsed / window;
    }
}
