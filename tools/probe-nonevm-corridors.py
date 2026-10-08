#!/usr/bin/env python3
"""Do Solana and TON route into Monad? Retest with correctly-formatted addresses.

The previous run reported both as refusals. They were not: Relay answers
"Invalid address 0x... for chain 792703809" because it validates the *format*
of `user` against the ORIGIN chain before it looks for a route. An EVM 0x
address is malformed for Solana (base58, 32-byte ed25519 pubkey) and for TON
(workchain:hex or a checksummed EQ/UQ form). The corridor was never evaluated.

A quote is a read-only pricing call. The address does not need to be funded or
even to exist on chain -- only to be well-formed. So both are synthesised here
rather than requested from anyone.

Several origin-currency encodings are tried per chain because Relay's
convention for non-EVM natives is not documented in the response we have.

Run: python3 tools/probe-nonevm-corridors.py
"""
import json
import time
import secrets
import urllib.request
import urllib.error

RELAY = "https://api.relay.link/quote/v2"
MONAD = 143
MONAD_USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
MONAD_AUSD = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a"
EVM_RECIPIENT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
OUT = "100000000"  # exactly 100 delivered on Monad

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(b: bytes) -> str:
    n = int.from_bytes(b, "big")
    out = ""
    while n > 0:
        n, r = divmod(n, 58)
        out = B58[r] + out
    pad = 0
    for byte in b:
        if byte == 0:
            pad += 1
        else:
            break
    return "1" * pad + out


def solana_address() -> str:
    """A syntactically valid ed25519 pubkey: 32 random bytes, base58."""
    return b58encode(secrets.token_bytes(32))


def crc16_xmodem(data: bytes) -> bytes:
    crc = 0x0000
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc.to_bytes(2, "big")


def b64url_nopad(b: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def ton_address_friendly(testnet=False, bounceable=True) -> str:
    """TON user-friendly form: tag, workchain, 32-byte hash, CRC16/XMODEM, base64url."""
    tag = 0x11 | (0x80 if bounceable else 0x00) | (0x20 if testnet else 0x00)
    body = bytes([tag, 0x00]) + secrets.token_bytes(32)  # workchain 0
    return b64url_nopad(body + crc16_xmodem(body))


def ton_address_raw() -> str:
    """TON raw form: workchain ':' 64 hex chars."""
    return "0:" + secrets.token_bytes(32).hex()


def post(payload, tries=3):
    body = json.dumps(payload).encode()
    for t in range(tries):
        req = urllib.request.Request(RELAY, data=body, headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                return 200, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 429 and t < tries - 1:
                time.sleep(3 * (t + 1))
                continue
            try:
                return e.code, json.loads(e.read().decode())
            except Exception:
                return e.code, {}
        except Exception as e:
            return 0, {"errors": [{"message": str(e)[:60]}]}
    return 429, {}


def classify(status, d):
    if status == 200 and not d.get("errors"):
        det = d.get("details") or {}
        cout = (det.get("currencyOut") or {}).get("amount")
        cin = det.get("currencyIn") or {}
        cur = (cin.get("currency") or {}).get("symbol")
        if cout:
            return "ROUTE", f"out={int(cout)/1e6:.6f} pay={cin.get('amount')} {cur}"
        return "200-NO-OUTPUT", f"steps={len(d.get('steps') or [])}"
    msg = ""
    if d.get("errors"):
        msg = str(d["errors"][0].get("message"))
    elif d.get("message"):
        msg = str(d.get("message"))
    code = d.get("errorCode") or ""
    # An address-format complaint means the chain was accepted but the probe was
    # still wrong. A routing complaint means the chain was evaluated.
    if "invalid address" in msg.lower():
        return "ADDR-FORMAT", msg[:70]
    return f"HTTP-{status}", (f"{code} " if code else "") + msg[:70]


SOL = solana_address()
TON_F = ton_address_friendly()
TON_R = ton_address_raw()

SOL_USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
SOL_WSOL = "So11111111111111111111111111111111111111112"

print("synthesised addresses")
print(f"  Solana base58   {SOL}  (len {len(SOL)})")
print(f"  TON friendly    {TON_F}")
print(f"  TON raw         {TON_R}")
print()

CASES = [
    ("Solana", 792703809, SOL, "0x0", "native"),
    ("Solana", 792703809, SOL, SOL_WSOL, "wSOL"),
    ("Solana", 792703809, SOL, SOL_USDC, "USDC"),
    ("TON", 224235520, TON_F, "0x0", "friendly/native"),
    ("TON", 224235520, TON_R, "0x0", "raw/native"),
    ("TON", 224235520, TON_F, SOL_WSOL, "friendly/wSOL?"),
]

print(f"{'chain':<8}{'id':>11}  {'addr form':<16}{'origin cur':<16} -> Monad AUSD")
print("-" * 96)
for name, cid, user, orig, label in CASES:
    payload = {
        "user": user, "originChainId": cid, "destinationChainId": MONAD,
        "originCurrency": orig, "destinationCurrency": MONAD_AUSD,
        "amount": OUT, "tradeType": "EXACT_OUTPUT",
        # destination is EVM even though the origin is not
        "recipient": EVM_RECIPIENT,
    }
    status, d = post(payload)
    verdict, detail = classify(status, d)
    form = "base58" if name == "Solana" else ("friendly" if user == TON_F else "raw")
    print(f"{name:<8}{cid:>11}  {form + '/' + label:<16}{orig[:14]:<16} {verdict:<14} {detail}")
    time.sleep(1.8)

print("-" * 96)
print("ROUTE           = corridor exists, real quote returned")
print("ADDR-FORMAT     = still a probe problem, chain id was accepted")
print("HTTP-4xx + code = Relay evaluated the chain and has no such route")
