"""Drive the Handoff screen against a simulated wallet and RPC."""

import argparse
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

APP = "https://handoff.test"
WEB = Path(__file__).resolve().parents[1] / "web"
SOURCE = "0x" + "1" * 40
DESTINATION = "0x" + "2" * 40
ROUTER = "0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762"
SIGNATURE_CONTRACT = "0xd757e3646af370b15f32eb557f0f8380df7d639e"
CLOSE_SIGNATURE = "0x" + "11" * 64 + "1b"
OPEN_SIGNATURE = "0x" + "22" * 64 + "1c"
TX_HASH = "0x" + "af" * 32
ONE = 10**18
COLLATERAL = ONE // 10
DRAW = 2012 * ONE + ONE // 5


def abi_words(*values):
    return "0x" + "".join(format(value, "064x") for value in values)


def serve_rpc(route):
    headers = {"access-control-allow-origin": APP}
    if route.request.method == "OPTIONS":
        route.fulfill(
            status=204,
            headers={**headers, "access-control-allow-headers": "content-type"},
        )
        return

    request = route.request.post_data_json
    method = request["method"]
    if method == "eth_blockNumber":
        result = "0x1004c3a"
    elif method == "eth_getTransactionReceipt":
        assert request["params"] == [TX_HASH]
        result = {"status": "0x1", "blockNumber": "0x1004c3b"}
    else:
        assert method == "eth_call"
        data = request["params"][0]["data"].lower()
        selector = data[:10]
        source = data[10:].endswith(SOURCE[2:])
        calls = {
            "0x21e37801": abi_words(1 if source else 0),
            "0x480cd578": abi_words(COLLATERAL if source else 0),
            "0xd66a2553": abi_words(2202 * ONE if source else 0),
            "0x92b7659b": abi_words(100),
            "0x7c3a00fd": abi_words(100),
            "0x2d0335ab": abi_words(7 if source else 11),
            "0x13ce19e3": abi_words(COLLATERAL, 2002 * ONE, 2013 * ONE, ONE // 5, 10 * ONE),
        }
        assert selector in calls, f"Unexpected call {selector}"
        result = calls[selector]

    route.fulfill(
        json={"jsonrpc": "2.0", "id": request["id"], "result": result},
        headers=headers,
    )


def verify_calldata(tx, typed_messages):
    assert tx["from"].lower() == SOURCE
    assert tx["to"].lower() == ROUTER.lower()

    data = bytes.fromhex(tx["data"][2:])
    assert data[:4].hex() == "ed74fbba"
    assert len(data) == 452
    payload = data[4:]

    def number(offset):
        return int.from_bytes(payload[offset : offset + 32], "big")

    def dynamic_bytes(offset):
        start = offset + 32
        end = start + number(offset)
        padded_end = start + ((end - start + 31) // 32) * 32
        assert payload[end:padded_end] == bytes(padded_end - end)
        return "0x" + payload[start:end].hex()

    assert "0x" + payload[12:32].hex() == DESTINATION
    assert number(32) == COLLATERAL
    assert number(64) == DRAW
    assert number(128) == 192
    assert number(160) == 320
    assert dynamic_bytes(number(128)) == CLOSE_SIGNATURE
    assert dynamic_bytes(number(160)) == OPEN_SIGNATURE

    close, open_ = typed_messages
    assert close["primaryType"] == "CloseTrove"
    assert open_["primaryType"] == "OpenTrove"
    for message, borrower, nonce in ((close, SOURCE, 7), (open_, DESTINATION, 11)):
        assert int(message["domain"]["chainId"]) == 31611
        assert message["domain"]["verifyingContract"].lower() == SIGNATURE_CONTRACT
        assert message["message"]["borrower"].lower() == borrower
        assert message["message"]["recipient"].lower() == ROUTER.lower()
        assert int(message["message"]["deadline"], 16) == number(96)
        assert int(message["message"]["nonce"], 16) == nonce

    assert int(open_["message"]["assetAmount"], 16) == COLLATERAL
    assert int(open_["message"]["debtAmount"], 16) == DRAW


def test_wallet_submits_two_signatures(chromium=None):
    with sync_playwright() as playwright:
        launcher = {"executable_path": chromium} if chromium else {}
        with playwright.chromium.launch(**launcher) as browser:
            context = browser.new_context()
            context.route("**/*", lambda route: route.abort())
            context.route(APP + "/", lambda route: route.fulfill(path=str(WEB / "index.html"), content_type="text/html"))
            context.route("https://rpc.test.mezo.org/", serve_rpc)
            page = context.new_page()
            page.add_init_script(
                f"""
                const harness = window.handoffTest = {{
                  active: "{SOURCE}",
                  signatures: [],
                  submissions: [],
                  listeners: {{}},
                  changeAccount(address) {{
                    this.active = address;
                    this.listeners.accountsChanged([address]);
                  }},
                }};
                window.ethereum = {{
                  on(event, callback) {{ harness.listeners[event] = callback; }},
                  async request({{method, params}}) {{
                    if (method === "eth_requestAccounts") return [harness.active];
                    if (method === "eth_chainId") return "0x7b7b";
                    if (method === "eth_signTypedData_v4") {{
                      if (params[0] !== harness.active) throw new Error("Wrong signer");
                      harness.signatures.push(JSON.parse(params[1]));
                      return harness.active === "{SOURCE}" ? "{CLOSE_SIGNATURE}" : "{OPEN_SIGNATURE}";
                    }}
                    if (method === "eth_sendTransaction") {{
                      harness.submissions.push(params[0]);
                      return "{TX_HASH}";
                    }}
                    throw new Error("Unexpected request " + method);
                  }},
                }};
                """
            )

            page.goto(APP + "/")
            page.locator('[data-action="testnet"]').click()
            page.locator('[data-action="connect"]').click()
            expect(page.locator("#source")).to_have_value(SOURCE)
            page.locator("#destination").fill(DESTINATION)
            page.locator('#wallet-form button[type="submit"]').click()

            submit = page.locator('[data-action="submit"]')
            expect(submit).to_be_disabled()
            page.locator('[data-action="sign-source"]').click()
            notice = page.locator("p.notice")
            expect(notice.filter(has_text="Signature recorded.")).to_be_visible()
            expect(submit).to_be_disabled()

            page.evaluate("address => window.handoffTest.changeAccount(address)", DESTINATION)
            page.locator('[data-action="sign-destination"]').click()
            expect(submit).to_be_enabled()
            submit.click()
            expect(notice.filter(has_text="the current wallet submits")).to_be_visible()
            assert page.evaluate("window.handoffTest.submissions") == []

            page.evaluate("address => window.handoffTest.changeAccount(address)", SOURCE)
            submit.click()
            expect(notice.filter(has_text="Confirmed by Mezo.")).to_be_visible()
            transactions = page.evaluate("window.handoffTest.submissions")
            messages = page.evaluate("window.handoffTest.signatures")
            assert len(transactions) == 1
            assert len(messages) == 2
            verify_calldata(transactions[0], messages)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium", help="Optional Chromium executable")
    test_wallet_submits_two_signatures(parser.parse_args().chromium)
    print("PASS: both signature payloads, source-only submission, and confirmed receipt UI")
