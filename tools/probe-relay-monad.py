#!/usr/bin/env python3
"""Probe Relay's live quote API for X -> Monad (143) corridors.

Primary-source check: does the aggregator WinkPay already integrates actually
route to Monad, and for which destination token? Printed as a table so the
answer is auditable rather than asserted.
"""
import json
import urllib.request

RELAY = "https://api.relay.link/quote/v2"
USER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
MONAD = 143
MONAD_USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
MONAD_AUSD = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a"
AMOUNT = "1000000"  # 1.00 at 6 decimals

SOURCES = [
    (8453, "Base", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
    (1, "Ethereum", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
    (42161, "Arbitrum", "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"),
    (10, "Optimism", "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"),
    (137, "Polygon", "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"),
]


def quote(origin_id, origin_token, dest_token):
    body = json.dumps({
        "user": USER,
        "originChainId": origin_id,
        "destinationChainId": MONAD,
        "originCurrency": origin_token,
        "destinationCurrency": dest_token,
        "amount": AMOUNT,
        "tradeType": "EXACT_INPUT",
    }).encode()
    req = urllib.request.Request(RELAY, data=body, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.loads(r.read().decode()), r.status
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode()), e.code
        except Exception:
            return {"errors": [{"message": f"HTTP {e.code}"}]}, e.code
    except Exception as e:
        return {"errors": [{"message": str(e)}]}, 0


def describe(d):
    if d.get("errors"):
        msgs = [str(e.get("message"))[:70] for e in d["errors"]]
        return "REFUSED  " + " | ".join(msgs)
    det = d.get("details") or {}
    cin = (det.get("currencyIn") or {}).get("symbol")
    cout = (det.get("currencyOut") or {}).get("symbol")
    fees = ((d.get("fees") or {}).get("total") or {}).get("amount")
    steps = d.get("steps") or []
    kinds = ",".join(str(s.get("kind")) for s in steps)
    return (f"OK  {cin}->{cout}  est={det.get('estimatedTime')}s  "
            f"impact={det.get('totalImpact')}  fee={fees}  steps=[{kinds}]")


print(f"{'corridor':<28} {'dest token':<6} result")
print("-" * 108)
for cid, name, tok in SOURCES:
    for dest_label, dest in (("USDC", MONAD_USDC), ("AUSD", MONAD_AUSD)):
        d, status = quote(cid, tok, dest)
        print(f"{name + ' -> Monad':<28} {dest_label:<6} {describe(d)}")
