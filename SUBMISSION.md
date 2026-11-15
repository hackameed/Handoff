# SUBMISSION — Handoff

Copy-paste ready for the AKINDO submission form. Fill the four `<<>>` fields.

---

## Project name

```
Handoff
```

## One-line description (short field, ~150 chars)

```
Move a Mezo MUSD loan to a new wallet in one transaction. Flash liquidity closes the old loan and opens the replacement — the borrower never needs to hold a stablecoin.
```

## Track

```
DeFi — borrowing infrastructure
```

## Links

| Field | Value |
|---|---|
| Live app | `<<LIVE_DEMO_URL>>` |
| Repository | `<<GITHUB_URL>>` |
| Demo video | `<<VIDEO_URL>>` |
| Contract (Mezo Testnet) | `https://explorer.test.mezo.org/address/0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762` |
| Deploy transaction | `https://explorer.test.mezo.org/tx/0xd745ce35e5baa0abace396a377eddfd3ca0c83b43de13c45e38d0d8fc7c400bd` |
| Verification page | `<<LIVE_DEMO_URL>>/verify.html` |

---

## Full description

### The problem

A Bitcoin holder on Mezo borrows 2,500 MUSD against their BTC, then spends it. Later they want the loan on a different wallet — rotating to hardware, handing off an ops wallet, consolidating.

**They can't.** Mezo's `CLOSE_TROVE_TYPEHASH` covers `(borrower, recipient, nonce, deadline)`. There is no destination-wallet field anywhere in the protocol. So the only path is: find 2,500 MUSD, close the loan, reopen on the second wallet, and pay a second borrowing fee.

Step one is where it dies. The MUSD was spent. Most borrowers cannot close their own loan.

This is not a UX complaint — it's a structural gap. Every MUSD borrower is locked to the wallet they borrowed from, permanently, unless they happen to be holding the stablecoin.

### What Handoff does

Handoff flash-borrows the MUSD, moves the loan, and repays the flash — atomically, in one transaction.

1. Flash-borrow MUSD from the Tigris MUSD/mUSDC pool.
2. `closeTroveWithSignature` on the current wallet. Mezo debits the MUSD from the Handoff router and releases the BTC collateral to it.
3. `openTroveWithSignature` on the new wallet, forwarding the exact released BTC.
4. Repay the pool with fee; send surplus MUSD back to the original wallet.

The collateral never leaves the protocol. The borrower signs twice and never needs to hold a stablecoin.

### Why the signatures are the security model

Mezo's `OPEN_TROVE_TYPEHASH` includes `assetAmount`, which is `msg.value`. So the receiving wallet signs the **exact collateral amount**.

That means:
- the router is trusted only to *sequence* calls, never to set amounts
- a relayer cannot redirect the Bitcoin
- a frontend bug cannot silently change the collateral

Submission must come from the original wallet, because the close signature names the router and the protocol offers no destination field. That is why the flow requires two signatures rather than one.

### Integration depth

This is protocol plumbing, not a wrapper:
- uses Mezo's native EIP-712 signature path (`BorrowerOperationsSignatures`)
- reads live trove state and current debt via `updateSystemAndTroveInterest` rather than trusting a quote
- depends on Tigris as a liquidity source, with the pool fee read at call time (`poolFeeBps()` → 1 bps), never hardcoded
- respects Mezo's own collateral, Recovery Mode and liquidity rules; the router adds no parallel accounting

### Deployment and verification

Deployed on Mezo Testnet (chain 31611): `0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762`

The runtime bytecode hash read from chain is **identical** to the hash produced by compiling the published source:

```
0xbaec09e54ddfd78eee5a79e41558d731b12a9ae54717b1627bd07c792624b546
```

`/verify.html` recomputes this in the browser from public RPC and checks all seven immutables against the real Mezo protocol addresses. No trust in the authors required.

### Evidence level — stated precisely

| Level | Status |
|---|---|
| Unit tests with mocks | not relied on |
| **Fork simulation against the deployed contract** | **9/9 passing** |
| Mined public transaction | **not yet** |

The nine tests in `test/Handoff.t.sol` are **simulations**. They execute the deployed router against a fork of live Mezo Testnet state, pinned at a block — real troves, real Tigris pool, real balances. That is materially stronger than mocks and materially weaker than a confirmed transaction.

**We have not mined a migration yet.** It needs Wallet A to hold a real loan, which requires ≥0.06 test BTC of collateral at current prices and `minNetDebt` is 1,800 MUSD. We measured the floor: at 0.035 BTC a borrower can open a loan but cannot complete a migration, because the replacement trove cannot redraw enough to repay the flash without breaching MCR. `script/MineMigration.s.sol` runs the full flow the moment a funded wallet exists.

We are labelling this clearly rather than implying the simulations are on-chain proof.

### Built from a spec, and we corrected it

The four corrections below each came from running code, not reading it. They're documented in the README because they indicate how much of the protocol we actually verified:

1. **Tigris is Uniswap-V2 shaped, not Basin.** The spec described a tuple-based `swap`; the real pool is `swap(uint256,uint256,address,bytes)` with a `hook` callback.
2. **The MUSD must sit in the router, not be transferred to the signatures contract.** `restrictedCloseTrove(borrower, msg.sender, recipient)` passes the Signatures contract as `_caller`, but the balance check resolves against the router.
3. **Off-chain quotes are stale by construction.** Mezo settles the close against interest-accrued debt, so the router measures debt on-chain via `updateSystemAndTroveInterest`.
4. **A closed trove has status 2, not 0.** Only status `1` blocks opening a destination.

### Market hypothesis

Stated as a hypothesis, not a claim: wallet migration is a recurring need for anyone holding a leveraged position long-term — hardware rotation, key hygiene, operational separation, inheritance planning. No independent borrower has used Handoff yet. Validation from a real borrower or a wallet team is the next step and the reason this continues past the buildathon.

### What's next

1. First mined migration once funded
2. A wallet team integrates Handoff as a "move loan" action — the natural distribution path, since they already own the user relationship
3. Batch and delegated variants once the single-move path is proven

---

## Short blurb (if the form caps characters)

```
Handoff moves a Mezo MUSD loan between wallets in one transaction. A Tigris flash loan pays off the old trove, and the released BTC opens the replacement — so a borrower who has already spent their MUSD can still change wallets. Two EIP-712 signatures bind the exact collateral; the protocol has no destination-wallet field, which is why this had to be built. Deployed and bytecode-verified on Mezo Testnet; nine fork tests pass against the live deployment. The first mined migration is pending testnet funding, and we say so.
```

---

## Pre-submit checklist

- [ ] `<<LIVE_DEMO_URL>>` resolves and Demo mode walks to the receipt
- [ ] `<<GITHUB_URL>>` is public and the repo has no `.deploy/` directory
- [ ] `<<VIDEO_URL>>` plays without login
- [ ] Explorer link opens the contract
- [ ] Read the description once more and confirm **every** claim is one you'd defend to a Mezo core dev
- [ ] Do not describe the fork tests as on-chain proof anywhere
