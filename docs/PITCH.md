# Handoff — 2-minute pitch

**Format:** screen recording, 1920×1080, no face cam. Voiceover + screen only.
**Runtime:** 1:58. Read at ~150 wpm. Do not rush the first 15 seconds — that's where the judge decides.

---

## 0:00 – 0:15 · The problem

> **[SCREEN: Mezo borrow UI, a loan sitting there. Or a simple title card.]**

"Here's a Bitcoin holder on Mezo. They borrowed 2,500 MUSD against their BTC, and they've spent it.

Now they want this loan on a different wallet — a hardware wallet, a fresh one. And they can't move it.

Mezo has no way to express that. The close signature only names the router — there's no destination wallet in the protocol. So their only option is to find 2,500 MUSD, close the loan, and open a new one.

**They don't have 2,500 MUSD. That's the whole problem.**"

---

## 0:15 – 0:40 · What Handoff does

> **[SCREEN: web/index.html, Demo mode. Scroll the hero, then the three steps.]**

"Handoff moves the loan in one transaction.

It flash-borrows the MUSD from Tigris, closes your current loan, opens the replacement on the new wallet with the exact same Bitcoin, and repays the flash.

The collateral never leaves the protocol. You sign twice. You never need to hold a stablecoin."

> **[SCREEN: click 'Find loan and review']**

"Two wallets, side by side. Current loan on the left, destination on the right."

---

## 0:40 – 1:05 · The security model

> **[SCREEN: Review screen, then scroll down to the mechanics accordion and open it.]**

"The new wallet signs the exact collateral amount. That's not cosmetic —

Mezo's open signature includes the asset amount. So the router decides the *order* of calls, but it cannot change *how much Bitcoin* moves. And a relayer can't redirect it either.

Submission has to come from the current wallet, because the close signature names the router and the protocol gives us no destination field. That's why it's two signatures, not one."

---

## 1:05 – 1:30 · The proof

> **[SCREEN: terminal. Run the fork test live.]**

```bash
HANDOFF_ROUTER=0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762 \
forge test --match-path test/Handoff.t.sol -vv --fork-url https://rpc.test.mezo.org
```

"Nine tests, all passing — against the deployed contract, not a local copy.

The main one opens a real Mezo loan, migrates it, and checks the new wallet holds the same 0.1 Bitcoin. The rest prove the failure paths: you can't open over a live loan, you can't under-fund the flash, you can't send BTC from anywhere but Mezo's Active Pool."

> **[SCREEN: the PASS lines, let them sit for 3 seconds]**

"These are **simulations** — they run against a fork of live Mezo state, not a mined transaction. I want to be precise about that. Real troves, real pool, real balances. But simulated."

---

## 1:30 – 1:50 · Why it's verifiable

> **[SCREEN: web/verify.html, let it load and go green]**

"The contract is deployed on Mezo Testnet. This page recomputes its bytecode hash from public RPC, in your browser, and compares it to this build.

`0xbaec09e5…24b546` — identical. Byte for byte. That's stronger than a verified-source badge.

Every immutable is checked against the real Mezo protocol addresses, and it reads the live Tigris fee — one basis point, right now."

---

## 1:50 – 1:58 · Close

> **[SCREEN: back to the demo, Receipt screen.]**

"Handoff fixes a structural gap in MUSD, rather than building beside it. One transaction, no stablecoin required, collateral never moves.

The contract works. What's missing is testnet Bitcoin to mine the first real migration — the script is written and runs the moment there's funding.

Repo, demo, and the verifier are in the submission."

---

## Shot list

| # | Time | Shot | Prep |
|---|---|---|---|
| 1 | 0:00 | Mezo borrow UI / title card | Screenshot beforehand |
| 2 | 0:15 | index.html demo, hero + steps | Open fresh tab |
| 3 | 0:30 | Click *Find loan and review* | Pre-loaded, demo mode |
| 4 | 0:40 | Review screen, upload arrow tiles | — |
| 5 | 0:50 | Mechanic accordion opened | — |
| 6 | 1:05 | Terminal, run fork test | Pre-run once so compile is warm |
| 7 | 1:20 | PASS output held | Let it breathe |
| 8 | 1:30 | verify.html, green badge | Pre-loaded |
| 9 | 1:50 | Demo receipt screen | Back button |

## Delivery notes

- **Do not open with "Hi, I'm…"**. Judges watch dozens. Start on the problem.
- **Say "simulation" out loud.** If a judge discovers the tests aren't mined transactions after you implied otherwise, you lose the credibility on everything else. Naming it builds trust.
- **Don't apologise for the missing mined tx.** State it as a funding constraint, once, and move on.
- **Record at 1080p**, cursor visible, and cut every pause. Two minutes means two minutes.
- If you overrun, cut shot 4 (the tiles) — the security section is worth more.

## One-line version (for the submission blurb)

> Handoff lets a Mezo borrower move an MUSD loan to a new wallet in one transaction — flash-borrowing the liquidity so they never need to hold a stablecoin, and keeping the Bitcoin collateral inside the protocol the whole time.
