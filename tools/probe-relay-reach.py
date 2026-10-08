#!/usr/bin/env python3
"""Which chains can Relay actually route INTO Monad (143)?

Corrected after a first version returned a false 28/28. Two bugs, both mine:
  1. Relay answers 429 with {"message": ...} and NO "errors" key, so a verdict
     based on "no errors" counted rate-limit rejections as successes.
  2. The amount was 10 * 10**18 regardless of the origin currency's decimals,
     which is 10 ETH on an 18-decimal chain, not "$10".

Fixes: require HTTP 200 AND a populated details.currencyOut.amount; treat 429
as a retryable condition with backoff; use per-chain native decimals; pace the
requests. A corridor only counts as reachable if it returns a real quote.

Run: python3 tools/probe-relay-reach.py
"""
import json
import time
import urllib.request
import urllib.error

RELAY = "https://api.relay.link/quote/v2"
USER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
MONAD = 143
NATIVE = "0x0000000000000000000000000000000000000000"
MONAD_USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
MONAD_AUSD = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a"

# (chain id, name, native decimals, USD value to send)
CHAINS = [
    (1, "Ethereum", 18, 50), (10, "Optimism", 18, 50), (56, "BNB", 18, 50),
    (100, "Gnosis", 18, 50), (130, "Unichain", 18, 50), (137, "Polygon", 18, 50),
    (146, "Sonic", 18, 50), (252, "Fraxtal", 18, 50), (324, "zkSync", 18, 50),
    (480, "World Chain", 18, 50), (8453, "Base", 18, 50), (5000, "Mantle", 18, 50),
    (80094, "Berachain", 18, 50), (42161, "Arbitrum", 18, 50),
    (42220, "Celo", 18, 50), (43114, "Avalanche", 18, 50),
    (59144, "Linea", 18, 50), (534352, "Scroll", 18, 50), (57073, "Ink", 18, 50),
    (81457, "Blast", 18, 50), (999, "HyperEVM", 18, 50), (1329, "Sei EVM", 18, 50),
    (33139, "ApeChain", 18, 50), (1868, "Soneium", 18, 50), (34443, "Mode", 18, 50),
    (101, "Solana", 9, 50), (4217, "Tempo", 18, 50),
]

# rough native prices so 50 USD is expressible in each chain's own decimals
PRICE_USD = {"ETH": 3000.0, "BNB": 600.0, "SOL": 150.0, "XDAI": 1.0,
             "POL": 0.25, "S": 0.5, "FRAX": 1.5, "MNT": 0.8, "BERA": 2.0,
             "CELO": 0.5, "AVAX": 25.0, "T": 1.0, "HYPE": 25.0, "SEI": 0.3,
             "APE": 0.6, "ZK": 0.05, "OP": 1.5, "ARBITRUM": 1.5, "BLAST": 0.003}
NATIVE_SYM = {1: "ETH", 10: "OP", 56: "BNB", 100: "XDAI", 130: "ETH", 137: "POL",
              146: "S", 252: "FRAX", 324: "ETH", 480: "ETH", 8453: "ETH",
              5000: "MNT", 80094: "BERA", 42161: "ARBITRUM", 42220: "CELO",
              43114: "AVAX", 59144: "ETH", 534352: "ETH", 57073: "ETH",
              81457: "BLAST", 999: "HYPE", 1329: "SEI", 33139: "APE",
              1868: "ETH", 34443: "ETH", 101: "SOL", 4217: "T"}


def amount_for(cid, dec, usd):
    sym = NATIVE_SYM.get(cid, "ETH")
    native = usd / PRICE_USD.get(sym, 3000.0)
    return int(native * 10**dec)


def quote(cid, dest, amount, tries=4):
    body = json.dumps({
        "user": USER, "originChainId": cid, "destinationChainId": MONAD,
        "originCurrency": NATIVE, "destinationCurrency": dest,
        "amount": str(amount), "tradeType": "EXACT_INPUT",
    }).encode()
    for t in range(tries):
        req = urllib.request.Request(RELAY, data=body, headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.loads(r.read().decode()), 200
        except urllib.error.HTTPError as e:
            if e.code == 429 and t < tries - 1:
                time.sleep(2.5 * (t + 1))   # back off; 429 is our fault, not theirs
                continue
            try:
                return json.loads(e.read().decode()), e.code
            except Exception:
                return {}, e.code
        except Exception as e:
            return {"errors": [{"message": str(e)[:50]}]}, 0
    return {}, 429


def verdict(d, status):
    """A corridor counts ONLY on a real quote: HTTP 200 plus a populated output."""
    if status != 200:
        return "no", f"HTTP {status}"
    if d.get("errors"):
        return "no", str(d["errors"][0].get("message"))[:44]
    det = d.get("details") or {}
    out = (det.get("currencyOut") or {}).get("amount")
    if not out:
        return "no", "200 but no currencyOut (not a real route)"
    imp = (det.get("totalImpact") or {}).get("percent")
    return "YES", f"out={int(out)/1e6:.4f} USD impact={imp}%"


print(f"{'chain':<13}{'id':>7}  {'->USDC':<6}{'->AUSD':<6}  detail")
print("-" * 84)
reaches = []
for cid, name, dec, usd in CHAINS:
    amt = amount_for(cid, dec, usd)
    ok_u, du = verdict(*quote(cid, MONAD_USDC, amt))
    time.sleep(1.2)
    ok_a, da = verdict(*quote(cid, MONAD_AUSD, amt))
    time.sleep(1.2)
    if ok_u == "YES" or ok_a == "YES":
        reaches.append(name)
    print(f"{name:<13}{cid:>7}  {ok_u:<6}{ok_a:<6}  {da if ok_a=='YES' else du}")

print("-" * 84)
print(f"verified reachable into Monad: {len(reaches)}/{len(CHAINS)}")
print(", ".join(reaches) if reaches else "none")
