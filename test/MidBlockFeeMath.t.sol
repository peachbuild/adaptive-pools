// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MidBlockFeeMath} from "../src/hooks/MidBlockFeeMath.sol";

contract MidBlockFeeMathTest is Test {
    MidBlockFeeMath internal math = new MidBlockFeeMath();

    struct Vector {
        uint160 open;
        uint160 current;
        bool direction;
        uint24 threshold;
        uint24 fraction;
        uint24 cap;
        uint24 expected;
    }

    function test_referenceVectorsFullUint160Domain() public view {
        bytes memory data = vm.parseJsonBytes(vm.readFile("test/fixtures/mid_block_math.json"), ".encoded");
        Vector[] memory cases = abi.decode(data, (Vector[]));
        for (uint256 i; i < cases.length; ++i) {
            Vector memory v = cases[i];
            assertEq(math.surcharge(v.open, v.current, v.direction, v.threshold, v.fraction, v.cap), v.expected);
        }
    }

    function testFuzz_exactRationalReference(uint120 a, uint120 b, uint24 t, uint24 f, uint24 c, bool direction)
        public
        view
    {
        // Keep this independent 256-bit oracle representable. The generated
        // Python vectors separately cover the full uint160 domain, including 1.
        uint160 open = uint160(bound(a, 65536, type(uint120).max));
        uint160 current = uint160(bound(b, 65536, type(uint120).max));
        uint24 threshold = uint24(bound(t, 1, 1_000_000));
        uint24 fraction = uint24(bound(f, 0, 1_000_000));
        uint24 cap = uint24(bound(c, 0, 1_000_000));
        uint256 os = uint256(open) * open;
        uint256 cs = uint256(current) * current;
        uint256 d = FullMath.mulDiv(os > cs ? os - cs : cs - os, 1_000_000, os);
        uint256 expected;
        if (d >= threshold && current != open && (current > open) == direction) {
            expected = FullMath.mulDiv(d, fraction, 1_000_000);
            if (expected > cap) expected = cap;
        }
        assertEq(math.surcharge(open, current, direction, threshold, fraction, cap), expected);
    }

    function test_thresholdAndFloorArePriceBased() public view {
        assertEq(math.surcharge(10000, 10010, true, 2001, 500000, 1000000), 1000);
        assertEq(math.surcharge(10000, 10010, true, 2002, 500000, 1000000), 0);
        assertEq(math.surcharge(10000, 9990, false, 1999, 500000, 1000000), 999);
        assertEq(math.surcharge(10000, 10010, false, 1, 1000000, 1000000), 0);
    }

    function test_worstSearchFitsCallBudget() public view {
        uint256 gasBefore = gasleft();
        assertEq(math.surcharge(1, type(uint160).max, true, 1000000, 1, 1000000), 1000000);
        assertLt(gasBefore - gasleft(), 200000);
    }
}
