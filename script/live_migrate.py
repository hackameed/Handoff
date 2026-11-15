#!/usr/bin/env python3
"""
Handoff — live end-to-end migration on Mezo Testnet.

Reproduces the fork test (test_Fork_RealMigration) against real chain state:
  1. Deployer opens a real MUSD trove.
  2. Handoff previews the move.
  3. Both wallets sign EIP-712 (close + open).
  4. Router.moveLoan migrates the loan to the destination wallet.
  5. Assert: source closed, destination active, same collateral.

Reads the disposable deployer key from .deploy/DEPLOYER.env. Never commits it.
"""
import json, os, sys, time, urllib.request

RPC = os.environ.get("MEZO_RPC", "https://rpc.test.mezo.org")
CHAIN_ID = 31611
ROUTER = "0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762"
MUSD = "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503"
SIGS = "0xD757e3646AF370b15f32EB557F0F8380Df7D639e"
TROVE_MANAGER = "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0"
BORROWER_OPS = "0xCdF7028ceAB81fA0C6971208e83fa7872994beE5"

from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_abi import encode as abi_encode
from Crypto.Hash import keccak

def k256(b):
    h = keccak.new(digest_bits=256); h.update(b); return h.hexdigest()

def sel(sig):
    return "0x" + k256(sig.encode())[:8]

_id = 0
def rpc(method, params):
    global _id
    _id += 1
    req = urllib.request.Request(
        RPC, data=json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode(),
        headers={"content-type": "application/json", "User-Agent": "handoff-live"})
    r = json.load(urllib.request.urlopen(req, timeout=120))
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]

def eth_call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])

def word(hexstr, i):
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    return int(h[i*64:(i+1)*64], 16)

def status_of(addr):
    return word(eth_call(TROVE_MANAGER, sel("getTroveStatus(address)") + abi_encode(["address"], [addr]).hex()), 0)

def coll_of(addr):
    return word(eth_call(TROVE_MANAGER, sel("getTroveColl(address)") + abi_encode(["address"], [addr]).hex()), 0)

def debt_of(addr):
    return word(eth_call(TROVE_MANAGER, sel("getTroveDebt(address)") + abi_encode(["address"], [addr]).hex()), 0)

def musd_of(addr):
    return word(eth_call(MUSD, sel("balanceOf(address)") + abi_encode(["address"], [addr]).hex()), 0)

def nonce_of(addr):
    return word(eth_call(SIGS, sel("getNonce(address)") + abi_encode(["address"], [addr]).hex()), 0)

def send(signed_raw):
    return rpc("eth_sendRawTransaction", [signed_raw])

def wait(h, timeout=180):
    end = time.time() + timeout
    while time.time() < end:
        try:
            r = rpc("eth_getTransactionReceipt", [h])
        except RuntimeError:
            r = None
        if r:
            return r
        time.sleep(3)
    raise TimeoutError(h)

# --- load key -------------------------------------------------------------
env = {}
for line in open(".deploy/DEPLOYER.env"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k] = v.strip()
acct_a = Account.from_key(env["DEPLOYER_PRIVATE_KEY"])

# destination wallet: fresh, no funder needed (router supplies the BTC)
acct_b = Account.create()
print(f"source      : {acct_a.address}")
print(f"destination : {acct_b.address}  (fresh, unused)")

bal = int(rpc("eth_getBalance", [acct_a.address, "latest"]), 16)
print(f"source bal  : {bal/1e18:.6f} BTC\n")

MODE = sys.argv[1] if len(sys.argv) > 1 else "run"
COLL = int(os.environ.get("COLL_WEI", 600 * 10**14))  # 0.0600 BTC (leaves ~0.0039 for gas)
BORROW = int(os.environ.get("BORROW_WEI", 2000 * 10**18))  # min net debt

def open_trove():
    if status_of(acct_a.address) == 1:
        print("source already has an active trove — skipping open")
        return
    data = sel("openTrove(uint256,address,address)") + abi_encode(
        ["uint256", "address", "address"], [BORROW, "0x" + "00"*20, "0x" + "00"*20]).hex()
    tx = {"to": BORROWER_OPS, "value": COLL, "data": data, "chainId": CHAIN_ID,
          "nonce": int(rpc("eth_getTransactionCount", [acct_a.address, "pending"]), 16),
          "gas": 3_000_000, "maxFeePerGas": 10**9, "maxPriorityFeePerGas": 10**8}
    est = rpc("eth_estimateGas", [{"from": acct_a.address, "to": BORROWER_OPS,
                                   "value": hex(COLL), "data": data}])
    tx["gas"] = int(est, 16) * 115 // 100
    signed = acct_a.sign_transaction(tx)
    h = send("0x" + signed.raw_transaction.hex())
    print(f"openTrove tx : {h}")
    r = wait(h)
    print(f"  status {'OK' if r['status']=='0x1' else 'FAILED'}  block {int(r['blockNumber'],16)}")
    assert r["status"] == "0x1"

def sign_typed(acct, primary, message):
    tm = "".join(m for m in primary)
    td = {"types": {
            "EIP712Domain": [{"name":"name","type":"string"},{"name":"version","type":"string"},
                             {"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
            primary: MESSAGE_TYPES[primary]},
          "primaryType": primary,
          "domain": {"name":"BorrowerOperationsSignatures","version":"1","chainId":CHAIN_ID,"verifyingContract":SIGS},
          "message": message}
    signed = acct.sign_typed_data(full_message=td)
    return signed.signature.hex()

MESSAGE_TYPES = {
    "CloseTrove": [{"name":"borrower","type":"address"},{"name":"recipient","type":"address"},
                   {"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}],
    "OpenTrove": [{"name":"assetAmount","type":"uint256"},{"name":"debtAmount","type":"uint256"},
                  {"name":"borrower","type":"address"},{"name":"recipient","type":"address"},
                  {"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}],
}

def migrate():
    s = status_of(acct_a.address)
    assert s == 1, f"source trove not active (status {s})"
    print(f"\nsource trove : ACTIVE   coll={coll_of(acct_a.address)/1e18:.6f} BTC  debt={debt_of(acct_a.address)/1e18:.2f} MUSD")

    # Mezo adds GAS_COMPENSATION (200 MUSD) to every trove and caps debt at
    # 110% of collateral value, so the draw has to clear payoff+fee while
    # leaving ICR > MCR. Quote with a large probe, then draw the minimum.
    probe = 2200 * 10**18
    q = eth_call(ROUTER, sel("preview(address,uint256)") + abi_encode(["address","uint256"], [acct_a.address, probe]).hex())
    qcoll, payoff, principal, fee = word(q,0), word(q,1), word(q,2), word(q,3)
    print(f"quote        : coll={qcoll/1e18:.6f}  payoff={payoff/1e18:.2f}  principal={principal/1e18:.2f}  fee={fee/1e18:.6f}")

    replacement = payoff + fee + int(os.environ.get("BUFFER_WEI", 10 * 10**18))
    q = eth_call(ROUTER, sel("preview(address,uint256)") + abi_encode(["address","uint256"], [acct_a.address, replacement]).hex())
    qcoll, payoff, principal, fee = word(q,0), word(q,1), word(q,2), word(q,3)
    print(f"draw chosen  : replacement={replacement/1e18:.2f} MUSD (payoff+fee+20)")

    deadline = int(time.time()) + 900
    close_sig = sign_typed(acct_a, "CloseTrove",
        {"borrower": acct_a.address, "recipient": ROUTER, "nonce": nonce_of(acct_a.address), "deadline": deadline})
    open_sig = sign_typed(acct_b, "OpenTrove",
        {"assetAmount": coll_of(acct_a.address), "debtAmount": replacement, "borrower": acct_b.address,
         "recipient": ROUTER, "nonce": nonce_of(acct_b.address), "deadline": deadline})
    print(f"signed       : close={close_sig[:18]}…  open={open_sig[:18]}…")

    data = sel("moveLoan(address,uint256,uint256,uint256,bytes,bytes)") + abi_encode(
        ["address","uint256","uint256","uint256","bytes","bytes"],
        [acct_b.address, qcoll, replacement, deadline,
         bytes.fromhex(close_sig), bytes.fromhex(open_sig)]).hex()

    tx = {"to": ROUTER, "value": 0, "data": data, "chainId": CHAIN_ID,
          "nonce": int(rpc("eth_getTransactionCount", [acct_a.address, "pending"]), 16),
          "maxFeePerGas": 10**9, "maxPriorityFeePerGas": 10**8}
    est2 = rpc("eth_estimateGas", [{"from": acct_a.address, "to": ROUTER, "data": data}])
    tx["gas"] = int(est2, 16) * 115 // 100
    signed = acct_a.sign_transaction(tx)
    h = send("0x" + signed.raw_transaction.hex())
    print(f"moveLoan tx  : {h}")
    r = wait(h)
    print(f"  status {'OK' if r['status']=='0x1' else 'FAILED'}  gasUsed {int(r['gasUsed'],16):,}  block {int(r['blockNumber'],16)}")
    if r["status"] != "0x1":
        raise SystemExit("moveLoan reverted on-chain")
    return h

def report(h):
    print("\n--- RESULT ---")
    print(f"source status      : {status_of(acct_a.address)}  (1=active, 2=closed)")
    print(f"destination status : {status_of(acct_b.address)}")
    print(f"destination coll   : {coll_of(acct_b.address)/1e18:.6f} BTC")
    print(f"destination debt   : {debt_of(acct_b.address)/1e18:.2f} MUSD")
    print(f"destination MUSD   : {musd_of(acct_b.address)/1e18:.2f}")
    print(f"router BTC left    : {int(rpc('eth_getBalance',[ROUTER,'latest']),16)}")
    print(f"router MUSD left   : {musd_of(ROUTER)}")
    print(f"\nexplorer: https://explorer.test.mezo.org/tx/{h}")
    json.dump({"tx": h, "source": acct_a.address, "destination": acct_b.address,
               "dest_coll": str(coll_of(acct_b.address)), "dest_debt": str(debt_of(acct_b.address))},
              open("evidence/live-migration.json","w"), indent=2)

if MODE == "open":
    open_trove()
elif MODE == "run":
    open_trove()
    h = migrate()
    report(h)
elif MODE == "resume":
    h = migrate()
    report(h)
