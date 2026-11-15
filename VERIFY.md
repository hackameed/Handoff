# Verify Handoff yourself

Everything below takes about two minutes and needs no trust in us.

## 1. The contract exists

```bash
cast code 0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762 --rpc-url https://rpc.test.mezo.org | wc -c
# → 12341   (6169 bytes of runtime, hex-encoded, plus "0x")
```

Or open it: https://explorer.test.mezo.org/address/0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762

## 2. The deployed bytecode is the tested build

```bash
cast keccak $(cast code 0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762 --rpc-url https://rpc.test.mezo.org)
# → 0xbaec09e54ddfd78eee5a79e41558d731b12a9ae54717b1627bd07c792624b546
```

Then compile this repository and compare:

```bash
git clone <repo> && cd handoff
forge build
forge test --match-test test_Hash -vv   # or read it from out/
```

The hash must match exactly. It also runs in-browser at `web/verify.html`.

> This is stronger than a "verified source" checkmark: it proves the deployed
> code is byte-for-byte the code that was tested, with no room for a different
> build to have been deployed.

## 3. It is bound to the real Mezo protocol

```bash
R=0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762
RPC=https://rpc.test.mezo.org
for f in EXPECTED_CHAIN_ID MUSD BORROWER_OPERATIONS_SIGNATURES TROVE_MANAGER ACTIVE_POOL POOL POOL_FACTORY; do
  printf "%-32s " "$f"; cast call $R "$f()(address)" --rpc-url $RPC 2>/dev/null || cast call $R "$f()(uint256)" --rpc-url $RPC
done
```

Expected:

| Field | Value |
|---|---|
| `EXPECTED_CHAIN_ID` | `31611` |
| `MUSD` | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |
| `BORROWER_OPERATIONS_SIGNATURES` | `0xD757e3646AF370b15f32EB557F0F8380Df7D639e` |
| `TROVE_MANAGER` | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` |
| `ACTIVE_POOL` | `0x143A063F62340DA3A8bEA1C5642d18C6D0F7FF51` |
| `POOL` | `0x525F049A4494dA0a6c87E3C4df55f9929765Dc3e` |
| `POOL_FACTORY` | `0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A` |

## 4. It reads live protocol state, not constants

```bash
cast call $R "poolFeeBps()(uint256)" --rpc-url $RPC
# → 1

cast call $R "flashFeeFor(uint256)(uint256)" 2500000000000000000000 --rpc-url $RPC
# → 250025002500250026   (0.250025 MUSD)
```

If the Tigris fee changes, these change. Nothing is hardcoded.

## 5. Run the tests yourself

```bash
forge test --match-path test/Handoff.t.sol -vv --fork-url https://rpc.test.mezo.org
```

Nine tests pass, including a full migration and seven failure paths.

**These are simulations.** They execute the deployed router against a fork of
live Mezo Testnet state pinned at a block. Real troves, real Tigris pool, real
balances — but no transaction was mined.

To be exact about what each level proves:

| Level | What it establishes |
|---|---|
| Mock unit test | logic is self-consistent |
| **Fork simulation (what we have)** | **deployed bytecode executes correctly against live protocol state** |
| Mined transaction | a real migration happened at a real block, forever checkable |

We are one level short of the third, and we say so in the README, the pitch,
and the submission.

## 6. Read the corrections we made to the build spec

Four things in the original brief were wrong, all found by executing code rather
than reading it. They're in the README under "Corrections". If you want to know
how carefully this was checked, that section is the honest signal — we were
wrong four times, logged each one, and fixed it.

---

## What we would want checked if we were judging

1. Does the close→open sequence respect Mezo's own accounting? *(Yes — the router holds no value between transactions and the tests assert zero residual BTC and MUSD.)*
2. Can a third party redirect the collateral? *(No — the destination signs the exact asset amount.)*
3. Is the fee math sound? *(`ceil(p·r/(10000−r))`, matching Tigris rounding, verified by `test_FlashFeeRounding`.)*
4. Is it actually deployed and live? *(Yes, with a public bytecode hash match.)*
5. Has it moved a real loan? *(Not yet. Funded-wallet step outstanding.)*
