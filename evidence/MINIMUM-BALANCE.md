# Minimum balance required for a mined migration

Measured against live Mezo Testnet, BTC at $64,550, `minNetDebt` 1,800 MUSD,
borrowing fee 5%.

## What 0.035 BTC can do

| Step | Result |
|---|---|
| Open a trove at 0.035 BTC / 1,800 MUSD draw | ✅ works (0.0345 is the floor) |
| Max draw at 0.035 BTC | ~1,850 MUSD — anything higher reverts on ICR < MCR |
| **Complete a migration at 0.035 BTC** | ❌ **fails: "ICR < MCR not permitted"** |

## Why the migration needs more

The destination trove must redraw enough to repay the flash:

```
payoff      = 1,801.80 MUSD   (debt 2,001.80 − 200 gas reserve)
flash fee   =     0.181 MUSD
must redraw ≥ 1,801.98 MUSD
```

But 0.0345 BTC caps the destination draw at roughly 1,730–1,850 MUSD depending
on the interest accrued at execution time. The two constraints overlap in a
window only a few MUSD wide — and the observed failure is that they don't
overlap in practice.

## Minimum realistic balance

| Amount | Outcome |
|---|---|
| 0.035 BTC | opens a loan, **cannot migrate** |
| 0.05 BTC | marginal — draw ceiling ~1,850 MUSD, still tight |
| **0.06 BTC** | **works:** verified in `test_Fork_RealMigration` |
| 0.10 BTC | comfortable, wide margin |

## Why not just try it

A revert costs gas and leaves nothing. At 0.035 BTC every attempt spends a
meaningful fraction of the only testnet BTC available, and the outcome is
already known from simulation: it reverts on the destination open.

The mechanism is proven against live state at 0.1 BTC. What's missing is testnet
BTC, not correctness.
