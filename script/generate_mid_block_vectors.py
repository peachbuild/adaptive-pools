#!/usr/bin/env python3
"""Reproduce the Mid-block math oracle with Python arbitrary-precision integers."""
import argparse
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "test/fixtures/mid_block_math.json"


def render():
    rng = random.Random(20261019)
    cases = []
    for _ in range(192):
        opening = rng.randrange(1, 2 ** rng.randrange(1, 161))
        current = rng.randrange(1, 2 ** rng.randrange(1, 161))
        for direction in (False, True):
            threshold = rng.choice([1, 1000, 1000000, rng.randrange(1, 1000001)])
            fraction = rng.choice([0, 1, 500000, 1000000, rng.randrange(1000001)])
            cap = rng.choice([0, 20000, 1000000, rng.randrange(1000001)])
            displacement = abs(current * current - opening * opening) * 1000000 // (opening * opening)
            fee = (min(displacement * fraction // 1000000, cap)
                   if displacement >= threshold and opening != current and (current > opening) == direction else 0)
            cases.append((opening, current, int(direction), threshold, fraction, cap, fee))

    def word(value):
        return value.to_bytes(32, "big").hex()

    encoded = "0x" + word(32) + word(len(cases)) + "".join(word(x) for case in cases for x in case)
    return json.dumps({
        "reference": "Python arbitrary-precision integer arithmetic; seed 20261019; full uint160 domain",
        "encoded": encoded,
    }, indent=2) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    data = render()
    if args.check:
        if PATH.read_text() != data:
            raise SystemExit("Mid-block oracle fixture differs from the independently generated reference")
        print("384 Mid-block reference vectors verified.")
    else:
        PATH.write_text(data)
