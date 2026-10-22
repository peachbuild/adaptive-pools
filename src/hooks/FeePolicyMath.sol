// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Pure resolution of the existing autonomous/poke fee, independent of
/// the optional surcharge component and its failure handling.
contract FeePolicyMath {
    function resolve(uint256 autonomous, uint24 cap, uint24 floor, uint24 side, bool active)
        external
        pure
        returns (uint24)
    {
        uint256 fee = autonomous > cap ? cap : autonomous;
        if (active && side != 0) {
            uint256 lower = fee / 2;
            if (lower < floor) lower = floor;
            fee = side < lower ? lower : side;
            if (fee > cap) fee = cap;
        }
        return uint24(fee);
    }
}
