# Live migration on Mezo Testnet

**Result: a real MUSD loan moved from one wallet to another, in one transaction,
keeping the same Bitcoin collateral.**

This is not a fork test and not a simulation. The transaction is on Mezo Testnet
and can be checked by anyone.

## The transaction

```
0x70048e7c663d833fb55e6917a918c26406769b97ce7328b7b43075c77c76fd37
```

https://explorer.test.mezo.org/tx/0x70048e7c663d833fb55e6917a918c26406769b97ce7328b7b43075c77c76fd37

| field | value |
|---|---|
| block | 16797058 |
| gas used | 2,533,448 |
| status | success |
| router | `0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762` |
| source wallet | `0xFE8FE674173C579b4900D38a4c8c6c5B99B1992B` |
| destination wallet | `0xea1968d50a9002B40f7bFA114E3C04Ea4BB2d114` |

## Before and after

| | source | destination |
|---|---|---|
| trove status before | 1 (active) | 0 (none) |
| trove status after | **2 (closed)** | **1 (active)** |
| collateral before | 0.060000 BTC | — |
| collateral after | — | **0.060000 BTC** |
| debt after | — | 2214.21 MUSD |

The router ends holding **0 BTC and 0 MUSD**, which is asserted on-chain by the
contract itself (`ResidualValue` / `PrincipalNotReturned` revert otherwise).

## What the transaction did

1. Borrowed 2013.01 MUSD from the Tigris pool against the source loan.
2. Closed the source trove, releasing 0.060 BTC to the router.
3. Opened a replacement trove for the destination wallet with that same 0.060 BTC.
4. Repaid the pool out of the new loan's proceeds and returned the surplus.

All four steps are one atomic transaction. The two EIP-712 signatures authorise
the close and the open; neither wallet had to send a transaction of its own.

## Reproducing it

`script/live_migrate.py` performs the whole sequence against the live chain:

```
python3 script/live_migrate.py open     # open the source trove
python3 script/live_migrate.py resume   # sign and execute the migration
```

It reads a disposable testnet key from `.deploy/DEPLOYER.env`, which is
gitignored and has never been committed.

## Notes on the testnet conditions

Mezo Testnet is currently in **recovery mode** with **TCR = 0** — the protocol
holds essentially no debt of its own. Two consequences shaped the run:

- A trove with ICR below the 150% collateral ratio is immediately redeemable, so
  an early attempt at 0.04 BTC was closed by redemption within about two minutes.
- Mezo's `MIN_NET_DEBT` of 2000 MUSD plus 200 MUSD gas compensation means a trove
  needs roughly 0.031 BTC of collateral at current prices just to open.

The successful run used 0.060 BTC, giving an ICR of about 178% at open — safely
above the redemption threshold.
