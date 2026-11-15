# Handoff — Deployed Router Evidence

## Deployment

| | |
|---|---|
| Network | Mezo Testnet |
| Chain ID | `31611` |
| Contract | `HandoffRouter` |
| Address | `0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762` |
| Transaction | `0xd745ce35e5baa0abace396a377eddfd3ca0c83b43de13c45e38d0d8fc7c400bd` |
| Deployer | `0xFE8FE674173C579b4900D38a4c8c6c5B99B1992B` (disposable testnet key) |
| Cost | 0.0000000005 test BTC |
| Runtime code | 12,341 bytes |

Explorer: https://explorer.test.mezo.org/address/0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762

## Immutable verification (read from the live contract)

| Field | Value | Matches build |
|---|---|---|
| `EXPECTED_CHAIN_ID` | `31611` | ✓ |
| `MUSD` | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | ✓ |
| `BORROWER_OPERATIONS_SIGNATURES` | `0xD757e3646AF370b15f32EB557F0F8380Df7D639e` | ✓ |
| `TROVE_MANAGER` | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` | ✓ |
| `ACTIVE_POOL` | `0x143A063F62340DA3A8bEA1C5642d18C6D0F7FF51` | ✓ |
| `POOL` | `0x525F049A4494dA0a6c87E3C4df55f9929765Dc3e` | ✓ |
| `POOL_FACTORY` | `0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A` | ✓ |

## Live protocol reads

```
poolFeeBps()          → 1
flashFeeFor(2500e18)  → 250025002500250026   (0.250025 MUSD)
```

Reads the real Tigris factory fee at call time. If the pool fee changes, the
router's fee math changes with it — nothing is hardcoded.

## Test suite executed against the DEPLOYED instance

Run with `HANDOFF_ROUTER=0x2d2c…9762`, so every test drives the public
contract rather than a fresh local copy.

```
9 passed; 0 failed; 0 skipped
```

The full migration inside the deployed router:

```
A collateral:  0.1000 BTC
A debt:        2,202.00 MUSD
payoff:        2,002.00 MUSD
principal:     2,013.01 MUSD
flash fee:     0.201321 MUSD
B debt:        2,402.20 MUSD
```

## Evidence levels — stated precisely

| Level | What it proves | Status |
|---|---|---|
| Local unit tests | Logic is correct in isolation | Not used |
| **Fork tests vs. deployed contract** | **The deployed bytecode executes a real migration against live Mezo state** | **Yes — 9/9** |
| Mined public transaction | A migration happened in a confirmed block, verifiable by anyone | **No — not yet** |

The fork test simulates execution against real chain state pinned at a block.
It is materially stronger than a mock, and materially weaker than a confirmed
transaction. A submission should not conflate the two.
