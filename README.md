# Adaptive Pools — Uniswap v4 Hooks

Adaptive Pools implements Uniswap v4 Hooks for ERC20, native-asset and
calendar-driven RWA pools. This repository provides the Hook source, pinned
dependencies and offline regression tests for Uniswap Labs routing-compatibility
review and independent reproduction. Source review and local tests do not
establish that a particular deployment matches this repository.

## Review scope

| Component | Responsibility |
| --- | --- |
| `Ramp`, `RampETH`, `RwaRamp` | Concrete Hooks, liquidity settlement, ERC6909 shares, fee accounting and native/RWA extensions |
| `BaseHook`, `FeePolicyMath`, `MidBlockFeeMath` | Hook permissions, dynamic fees, bounded keeper overrides and optional Mid-block fees |
| `ClaimFeePolicy`, `LedgerTypes` | Historical claim-fee policy and shared accounting types |
| `MarketCalendar`, `CalendarLib`, `SessionLib` | Controller-only RWA settings, trading sessions and calendar fee curves |

These 11 Solidity files under `src/` form the production review scope. Ramp's
liquidity and share-accounting functions are part of the concrete Hook contracts
and remain in scope alongside the swap callbacks. `BaseHook` is abstract.

Application Routers, aggregator integration, readers, pool discovery registries,
standalone test tokens, deployment scripts and deployment records are excluded.
Uniswap's own test routers and local mock tokens are used only to exercise the
Hooks against a local PoolManager. Tests make no RPC requests and submit no
chain transactions.

## Routing behavior

All three concrete Hooks use the same callback permissions:

| Property | Behavior |
| --- | --- |
| Enabled callbacks | `beforeInitialize` and `beforeSwap` only; all other callback and return-delta flags are disabled |
| Pool fee mode | Uniswap v4 dynamic LP fees; `beforeSwap` supplies the applicable LP fee using `OVERRIDE_FEE_FLAG` |
| Custom swap accounting | `beforeSwap` returns zero `BeforeSwapDelta`; no custom input/output delta is charged by the callback |
| Hook data | Swap callbacks accept empty `hookData`; no custom payload or signature is required |
| Swap caller | Callbacks authenticate PoolManager; they do not require a particular transaction router or inspect the original swap sender |
| Pool availability | A pool must be configured on its Hook before initialization; swaps revert while the Hook or pool is paused |
| Upgradeability | Hook contracts are non-upgradeable; submitted deployments must not use an upgradeable proxy |

PoolManager retains AMM settlement and protocol-fee processing. Ramp's claim-fee
accounting concerns the distribution of collected position fees and is separate
from Uniswap's AMM protocol fee. Dynamic fees, including enabled Mid-block fees,
are state-dependent; a quote can change before execution. Governance controls
and pause behavior are described below.

## Accounting and permissions

PoolManager owns AMM state and settles currencies. Ramp aggregates liquidity by
pool and tick range, issues ERC6909 shares in liquidity units, and retains earned
fees as PoolManager currency claims until payout. ClaimFeePolicy records
per-pool historical revenue rates; configured recipients receive the protocol
portion, while LP balances follow the Hook's growth accounting.

Administrative calls use OpenZeppelin AccessManager. The configured authority
controls pool settings, fee recipients, pause policy and role assignments.
Keepers can only call selectors assigned to their roles; fee overrides remain
bounded by the pool floor, cap, discount limit and TTL. Mid-block configuration
requires its own authorized selector and does not automatically grant keepers
additional permission. Actual authority roles and delays must be checked against
the deployment under review; this source does not attest a live multisig setup.

Pausing a Hook pauses deposits, withdrawals, swaps, claims and share transfers
together. There is no independent principal-withdrawal exemption. Calendar and
claim-fee components accept writes only from their controlling Hook. The Hooks
are non-upgradeable. Standard non-rebasing, non-taxed ERC20 assets are assumed.

## Swap fees

Fees use Uniswap v4 pips: 100 pips = 1 basis point. Ordinary fees combine the
configured flat or RWA calendar policy, directional premiums and live keeper
overrides, subject to the Hook's bounds.

Mid-block Fee is configured per pool and disabled by default. The first
successful swap in each block records its pre-swap sqrtPriceX96 and pays no
Mid-block surcharge. Later swaps pay a surcharge only when their direction moves
back toward that opening price and the configured displacement threshold is met:

```text
displacementPips = floor(abs(Pcurrent / Popen - 1) * 1_000_000)
midBlockFee = min(floor(displacementPips * captureFractionE6 / 1_000_000), midCap)
finalFee = min(currentFee + midBlockFee, poolCap, absoluteCap)
```

`P` is the raw currency1/currency0 price (the square of sqrtPriceX96 divided by
Q192). Outward swaps and swaps below the threshold have zero surcharge. The
pre-swap fee applies to the whole swap, including exact-output swaps and swaps
that cross the opening price. Liquidity changes do not reset the observation;
a failed transaction rolls it back. Every successful Mid-block configuration
update clears that pool's observation, including disable or unchanged settings.

`currentFee` reports the ordinary policy; `executionFee` includes the live
Mid-block surcharge. These are current-state queries, not historical or
next-block guarantees. The immutable MidBlockFeeMath component uses full-width
integer arithmetic. Its surcharge calculation has a 200,000-gas static-call
budget; a revert, malformed result or result above midCap falls back to the
ordinary fee without erasing the observation. Other Hook errors still revert.

## Assets and networks

`Ramp` and `RwaRamp` settle ERC20 currencies. `RampETH` also handles native assets,
including BNB on BSC. On Arc, business settlement uses the ERC20 USDC interface
at `0x3600000000000000000000000000000000000000` (6 decimals); do not use RampETH
or native USDC as a pool currency there. Native USDC is required for gas and
shares its underlying balance with the ERC20 interface. Local standard-EVM tests
do not establish Arc-specific native balance or transfer behavior.

## Reproduce the review

Validated with Foundry 1.7.1 and Python 3. The committed compiler settings are
Solidity 0.8.26, Cancun, the optimizer with one run, and `via_ir = true`.
Clone this repository with recursive submodules, then run from its root:

```sh
git submodule update --init --recursive --depth 1
python3 script/check_dependencies.py
python3 script/generate_mid_block_vectors.py --check
forge build --sizes
forge test --summary --threads 1
forge fmt --check src test
```

The three top-level dependency gitlinks and `dependencies.lock.json` pin
forge-std, v4-core and v4-periphery; each upstream parent pins its nested
submodules. Do not use `git submodule update --remote`. Initial dependency setup
requires GitHub access; verification and tests run locally once dependencies
and the pinned compiler are installed. The dependency checker validates Git
index entries, upstream URLs, exact revisions, clean dependency source and
recursive pins.

Dependency source is taken from the fixed upstream revisions recorded in the
lock file. Upstream licenses remain in the submodules, and production and test
source retain their SPDX notices.

## Tests

Local verification on 22 October 2026: **360 tests passed across 27 suites, with
zero failures or skips**. A clean build, dependency validation, formatting check
and reproduction of all 384 mathematical oracle vectors also passed. These
results apply to the retained Hook source and tests; compiler and linter warnings
remain. They do not establish live-network behavior or deployment verification.

Regression tests cover ERC20/native settlement, shares, LP/protocol fee
accounting, claim operators, permissions, pauses, reentrancy and recipient
failures, RWA calendars, dynamic fee bounds and Mid-block behavior. The
Mid-block tests exercise all three concrete Hooks directly with PoolManager,
including both directions, block transitions, exact-output swaps, fee caps,
configuration permissions, module failures, transaction rollback and pool
isolation. Mathematical coverage includes 384 reproducible arbitrary-precision
Python oracle vectors over the uint160 price domain.

Dedicated batch-claim tests are not included.
