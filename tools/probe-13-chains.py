#!/usr/bin/env python3
"""Do WinkPay's 13 source chains route into Monad (143)?

Uses the chain IDs and source tokens from the product's actual supported list,
not guessed IDs. An earlier probe tested Solana as 101; Relay's Solana ID is
792703809, so that result was invalid.

Method note: quotes use tradeType EXACT_OUTPUT with amount = the DESTINATION
amount. That was confirmed empirically -- a quote for 100000000 returned
currencyIn.amount = 100073320 (what the sender pays on Base) and
currencyOut.amount = 100000000 (what lands on Monad). It removes any need to
know the origin currency's decimals or price, which is what made the previous
sweep's dollar figures meaningless.

Origin currency is native (0x0) so the probe tests route reachability rather
than a specific stablecoin leg.

Run: python3 tools/probe-13-chains.py
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
OUT_AMOUNT = "100000000"  # exactly 100.000000 delivered on Monad

# The 13 source chains, with the IDs and tokens WinkPay actually uses.
SOURCES = [
    (8453, "Base", "USDC"),
    (1, "Ethereum", "USDC"),
    (42161, "Arbitrum", "USDC"),
    (10, "Optimism", "USDC"),
    (137, "Polygon", "USDC"),
    (56, "BSC", "USDC"),
    (792703809, "Solana", "USDC"),
    (43114, "Avalanche", "USDC"),
    (42220, "Celo", "USDC"),
    (224235520, "TON", "GRAM"),
    (4663, "Robinhood Chain", "USDG"),
    (9745, "Plasma", "USDT0"),
    (196, "X Layer", "USDC"),
    # Not one of the 13 sources -- WinkPay's DESTINATION. Included because if
    # Tempo can source into Monad, WinkPay's existing book can migrate.
    (4217, "Tempo (dest)", "pathUSD"),
]


def quote(cid, dest, tries=4):
    body = json.dumps({
        "user": USER, "originChainId": cid, "destinationChainId": MONAD,
        "originCurrency": NATIVE, "destinationCurrency": dest,
        "amount": OUT_AMOUNT, "tradeType": "EXACT_OUTPUT",
    }).encode()
    for t in range(tries):
        req = urllib.request.Request(RELAY, data=body, headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.loads(r.read().decode()), 200
        except urllib.error.HTTPError as e:
            if e.code == 429 and t < tries - 1:
                time.sleep(3 * (t + 1))
                continue
            try:
                return json.loads(e.read().decode()), e.code
            except Exception:
                return {}, e.code
        except Exception as e:
            return {"errors": [{"message": str(e)[:60]}]}, 0
    return {}, 429


def verdict(d, status):
    """Reachable ONLY on HTTP 200 with a real populated output amount."""
    if status != 200:
        return None, f"HTTP {status}"
    if d.get("errors"):
        return None, str(d["errors"][0].get("message"))[:46]
    det = d.get("details") or {}
    cin = (det.get("currencyIn") or {})
    cout = (det.get("currencyOut") or {})
    if not cout.get("amount"):
        return None, "200 but no currencyOut"
    cur = ((cin.get("currency") or {}).get("symbol")) or "?"
    dec = ((cin.get("currency") or {}).get("decimals")) or 18
    paid = int(cin.get("amount") or 0) / 10**dec
    return (paid, cur), f"pay {paid:.6f} {cur}"


print("WinkPay's 13 source chains -> Monad 143, exactly 100 USDC/AUSD out")
print("=" * 78)
print(f"{'chain':<18}{'relay id':>12}  {'token':<6} {'->USDC':<24}{'->AUSD':<24}")
print("-" * 78)
reach, partial, none = [], [], []
for cid, name, tok in SOURCES:
    cells = []
    got = []
    for dest in (MONAD_USDC, MONAD_AUSD):
        res, msg = verdict(*quote(cid, dest))
        time.sleep(1.6)
        if res:
            cells.append(f"{msg:<24}")
            got.append(dest is MONAD_AUSD)
        else:
            cells.append(f"{msg:<24}")
    if len(got) == 2:
        reach.append(name)
    elif got:
        partial.append(name)
    else:
        none.append(name)
    print(f"{name:<18}{cid:>12}  {tok:<6} {cells[0]}{cells[1]}")

print("-" * 78)
total = len(SOURCES)
print(f"both tokens : {len(reach)}/{total}  {', '.join(reach) or '-'}")
print(f"one token   : {len(partial)}/{total}  {', '.join(partial) or '-'}")
print(f"neither     : {len(none)}/{total}  {', '.join(none) or '-'}")
print()
print("NOTE: Solana and TON need a native-format sender address, not an EVM 0x")
print("address. Relay rejects the EVM address with 'Invalid address ... for chain'")
print("which means the CHAIN ID is accepted -- so those two are inconclusive here,")
print("not proven unsupported. Every other refusal carries a real errorCode.")
