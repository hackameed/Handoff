# Handoff

**Move a Mezo MUSD loan between wallets — one transaction, collateral never leaves the protocol.**

Built for the [Mezo Buildathon](https://app.akindo.io/wave-hacks/OVOO0gdrVU8379D10) · DeFi track · Mezo Testnet

---

## The problem

A Bitcoin holder borrows 2,500 MUSD against their BTC to buy equipment. They spend it. Later they want the loan on a different wallet — rotating to a hardware wallet, handing off an ops wallet, consolidating.

Today there is no way to do this. Mezo's `CLOSE_TROVE_TYPEHASH` covers `(borrower, recipient, nonce, deadline)` — it has **no destination-wallet field**. The protocol cannot express "move my loan to wallet B". So the borrower has to:

1. Find 2,500 MUSD from somewhere
2. Close the loan manually
3. Hope the BTC price hasn't moved
4. Open a new loan on the second wallet
5. Pay a second borrowing fee

**Step 1 is where it dies.** The MUSD was spent. Most borrowers cannot close their own loan.

## The fix

Handoff flash-borrows the MUSD, moves the loan, and repays the flash — atomically. The borrower signs twice and never needs to hold a stablecoin.

```
                    ┌─────────────────────────────┐
                    │   Tigris MUSD/mUSDC pool    │
                    └──────┬───────────────▲──────┘
                 flash MUSD│               │ principal + fee
                    ┌──────▼───────────────┴──────┐
                    │      HandoffRouter          │
                    └──┬───────────────────────▲──┘
      closeTroveWithSignature                openTroveWithSignature
          (borrower = A)                        (borrower = B)
                    │                        │
       ┌────────────▼──────────┐   ┌─────────┴─────────────┐
       │  Wallet A's trove     │   │  Wallet B's trove     │
       │  closes → BTC to router│──▶│ opens with same BTC   │
       └───────────────────────┘   └───────────────────────┘
```

1. **Flash-borrow MUSD** from the Tigris MUSD/mUSDC pool.
2. **`closeTroveWithSignature`** on Wallet A. Mezo debits the MUSD from the router and releases the collateral to it.
3. **`openTroveWithSignature`** on Wallet B, forwarding the exact released BTC.
4. **Repay the pool**, return surplus MUSD to Wallet A.

If any step fails, the whole thing reverts. The loan never moves twice.

### Why the signatures are the security model

Mezo's `OPEN_TROVE_TYPEHASH` includes `assetAmount`, which is `msg.value`. Wallet B signs the **exact collateral amount**, so:

- the router is trusted only to *sequence* calls, not to set amounts
- a relayer cannot redirect the BTC
- a bug in the frontend cannot silently change the collateral

Submission must come from Wallet A, because the close signature names the router and the protocol provides no destination field. That's the reason the flow needs two signatures from one browser rather than one.

---

## Deployed contract

| | |
|---|---|
| Network | Mezo Testnet · chain `31611` |
| Address | [`0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762`](https://explorer.test.mezo.org/address/0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762) |
| Deploy tx | [`0xd745ce35e5baa0abace396a377eddfd3ca0c83b43de13c45e38d0d8fc7c400bd`](https://explorer.test.mezo.org/tx/0xd745ce35e5baa0abace396a377eddfd3ca0c83b43de13c45e38d0d8fc7c400bd) |
| Runtime size | 6,169 bytes (well under the 24,576 limit) |
| Runtime hash | `0xbaec09e54ddfd78eee5a79e41558d731b12a9ae54717b1627bd07c792624b546` |

### Bytecode integrity

The runtime bytecode hash read from the live contract is **identical** to the hash produced by compiling this repository:

```
live chain : 0xbaec09e54ddfd78eee5a79e41558d731b12a9ae54717b1627bd07c792624b546
this build : 0xbaec09e54ddfd78eee5a79e41558d731b12a9ae54717b1627bd07c792624b546
```

This is deliberately stronger than a "verified source" badge: it proves the deployed code is byte-for-byte the code that was tested. You don't have to trust a checkbox — see [`web/verify.html`](web/verify.html), which recomputes it in your browser from public RPC.

### Immutables, read from the live contract

| Field | Live value |
|---|---|
| `EXPECTED_CHAIN_ID` | `31611` |
| `MUSD` | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |
| `BORROWER_OPERATIONS_SIGNATURES` | `0xD757e3646AF370b15f32EB557F0F8380Df7D639e` |
| `TROVE_MANAGER` | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` |
| `ACTIVE_POOL` | `0x143A063F62340DA3A8bEA1C5642d18C6D0F7FF51` |
| `POOL` | `0x525F049A4494dA0a6c87E3C4df55f9929765Dc3e` |
| `POOL_FACTORY` | `0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A` |

It reads the live Tigris fee at call time — `poolFeeBps()` returns `1`, and `flashFeeFor(2500e18)` returns `0.250025 MUSD`. Nothing about the fee is hardcoded.

---

## Evidence: what is proven, and how

| Claim | How it was established |
|---|---|
| Contract deployed and reading real Mezo state | Live calls to public RPC, above |
| Deployed bytecode == tested build | Runtime hash equality |
| Full migration executes correctly | **Simulation** on a fork of live Mezo state |
| A migration has been mined publicly | **No — not yet** |

### The nine tests are simulations

This matters, so it's stated plainly rather than buried:

> The nine tests in `test/Handoff.t.sol` are **fork simulations**. They execute the
> deployed router against a fork of live Mezo Testnet state pinned at a block.
> They are materially stronger than mocks — real troves, real Tigris pool, real
> ERC-20 balances — and materially weaker than a confirmed transaction. No
> migration has yet been mined on public Mezo Testnet.

Evidence levels, honestly labelled:

| Level | Status |
|---|---|
| Unit tests with mocks | ✗ not relied on |
| **Fork simulation vs. deployed contract** | **✓ 9/9 passing** |
| Mined public transaction | ✗ pending testnet funding |

Run them yourself:

```bash
forge test --match-path test/Handoff.t.sol -vv --fork-url https://rpc.test.mezo.org
# or against the deployed instance:
HANDOFF_ROUTER=0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762 \
  forge test --match-path test/Handoff.t.sol -vv --fork-url https://rpc.test.mezo.org
```

Result from the deployed instance:

```
[PASS] test_Fork_RealMigration() (gas: 2463967)
  A collateral:  0.1000 BTC
  A debt:        2,202.00 MUSD
  payoff:        2,002.00 MUSD
  principal:     2,013.01 MUSD
  flash fee:     0.201321 MUSD
  B debt:        2,402.20 MUSD
[PASS] test_Revert_DestinationOccupied      # can't open over a live loan
[PASS] test_Revert_DrawTooSmall             # draw can't service the debt
[PASS] test_Revert_SourceNotActive          # trove doesn't exist
[PASS] test_Revert_DuplicateWallets         # A → A
[PASS] test_Revert_QuoteExpired             # stale signature
[PASS] test_Revert_DeadlineTooFar           # unbounded signature
[PASS] test_Revert_NativeFromUnexpectedSource  # BTC from anyone but ActivePool
[PASS] test_FlashFeeRounding                # fee maths matches Tigris
```

### Why no mined transaction yet

A migration needs Wallet A to hold a real loan, which needs **≥ 0.06 test BTC** of collateral at current prices. Mezo's `minNetDebt` is 1,800 MUSD and the minimum collateral ratio is 110%.

We measured the floor precisely: at 0.035 BTC a borrower can open a loan but **cannot** complete a migration — the destination trove cannot redraw enough to repay the flash without breaching MCR. See [`evidence/MINIMUM-BALANCE.md`](evidence/MINIMUM-BALANCE.md).

The mechanism is not in doubt; the testnet BTC is. `script/MineMigration.s.sol` is written, compiles, and runs the full flow end-to-end the moment a funded wallet exists.

---

## The live demo

**[`web/index.html`](web/index.html)** — open it directly, no build step, no wallet required.

- **Demo mode** walks all three screens with sample data. Nothing touches the chain. This is what a judge should click first.
- **Testnet mode** reads real Mezo troves over public RPC: validates addresses, rejects duplicate wallets, detects an occupied destination, flags the wrong network, and pulls live quotes from the deployed router.

**[`web/verify.html`](web/verify.html)** — recomputes the bytecode hash and reads every immutable from your browser. Confirms the deployment without trusting this README.

**[`web/deploy.html`](web/deploy.html)** — deploys the router from your own wallet, signing locally. Included so the deployment is reproducible rather than a one-off.

---

## Corrections made to the original build brief

Four errors in the spec would each have cost hours. All found by running code, not reading it:

| Brief said | Reality |
|---|---|
| Tigris `swap(address,(address,address,address,uint256,uint256),bytes,address,uint256)` | Uniswap-V2 shaped: `swap(uint256,uint256,address,bytes)`, callback `hook(...)`. Not Basin. |
| Caller supplies `payoff` / `principal` / `fee` | Router measures debt itself via `updateSystemAndTroveInterest`. Off-chain quotes are stale by execution time — interest accrues between quote and close. |
| MUSD is "used to pay off the old loan" (implying transfer to the signatures contract) | MUSD must sit **in the router**. `restrictedCloseTrove(borrower, msg.sender, recipient)` passes the Signatures contract as `_caller`, and `_requireSufficientMUSDBalance` resolves against the router's balance. |
| "Verify the target has no active loan" | A previously-closed trove (status 2/3/4) is fine. Only status `1` blocks opening. |

---

## Repository

```
src/HandoffRouter.sol        the router
test/Handoff.t.sol           9 fork tests
script/Deploy.s.sol          deployment
script/MineMigration.s.sol   end-to-end mined migration (needs funded wallet)
web/index.html               3-screen app, demo + testnet modes
web/verify.html              independent bytecode/config verification
web/deploy.html              in-browser deployer
evidence/                    deployment record, balance analysis, test output
```

### Build and test

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # if needed
make install        # forge install foundry-rs/forge-std
make test           # 9 fork tests against live Mezo Testnet
make test-deployed  # same suite, driven at the live router
make demo           # http://localhost:8080
make verify         # asserts the deployed bytecode hash
```

Verified from a clean clone: `make install && make test` → **9 passed, 0 failed**.

Requires [Foundry](https://getfoundry.sh). Solidity 0.8.28, optimiser on, `via_ir` enabled.
CI runs the same suite on every push (`.github/workflows/test.yml`) and fails if the
deployed bytecode hash drifts from the build.

---

## Limits — read these

- **Not audited.** Testnet software built for a buildathon.
- **No mined migration yet.** See above. The nine tests are simulations.
- **One loan per wallet.** If the destination already holds an active trove the move is rejected by design.
- **Recovery Mode risk.** If Mezo enters Recovery Mode, the open path tightens to CCR (150%) and a migration can fail for an otherwise healthy position during a crash.
- **Pool dependency.** A migration needs the Tigris MUSD/mUSDC pool liquid and unpaused. At time of writing: 201,350 MUSD, 1 bps fee, not paused.
- **Mainnet demand is a hypothesis.** This solves a real structural gap, but no independent borrower has used it yet. Validation from a real borrower or wallet team is the next step, not a claim made here.

## License

MIT
