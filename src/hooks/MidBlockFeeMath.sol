// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Stateless, immutable companion for the Ramp fee policy.
/// @dev No assets, permissions, callbacks or price observations.
contract MidBlockFeeMath {
    uint256 private constant E6 = 1_000_000;

    /// @dev Exactly floors the price displacement before converting it to a fee.
    /// Squared uint160 prices are up to 320 bits. Compare full 512-bit products
    /// rather than truncating sqrt prices, ticks or an intermediate price ratio.
    function surcharge(uint160 open, uint160 current, bool zeroForOne, uint24 threshold, uint24 fraction, uint24 cap)
        external
        pure
        returns (uint24)
    {
        if (open == 0 || current == open || fraction == 0 || cap == 0) return 0;
        bool up = current > open;
        if (up != zeroForOne) return 0;
        // Above this displacement the fee is already saturated; keep the search
        // bounded (at most 40 iterations for valid policy parameters).
        uint256 high = (uint256(cap) * E6 + fraction - 1) / fraction;
        if (high < threshold) high = threshold;
        if (!up && high > E6) high = E6;
        uint256 low;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (_atLeast(open, current, up, mid)) low = mid;
            else high = mid - 1;
        }
        if (low < threshold) return 0;
        uint256 fee = low * fraction / E6;
        return uint24(fee > cap ? cap : fee);
    }

    function _atLeast(uint256 open, uint256 current, bool up, uint256 displacement) private pure returns (bool) {
        (uint256 ah, uint256 al) = _squareScaled(current, E6);
        (uint256 bh, uint256 bl) = _squareScaled(open, up ? E6 + displacement : E6 - displacement);
        return up ? (ah > bh || (ah == bh && al >= bl)) : (ah < bh || (ah == bh && al <= bl));
    }

    function _squareScaled(uint256 price, uint256 scale) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let squareLow := mul(price, price)
            let mm := mulmod(price, price, not(0))
            let squareHigh := sub(sub(mm, squareLow), lt(mm, squareLow))
            lo := mul(squareLow, scale)
            mm := mulmod(squareLow, scale, not(0))
            hi := add(mul(squareHigh, scale), sub(sub(mm, lo), lt(mm, lo)))
        }
    }
}
