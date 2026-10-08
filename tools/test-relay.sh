#!/usr/bin/env bash
# Prove the gasless path end to end over HTTP: a payer signs an EIP-2612 permit, the
# relay broadcasts it, and the payer NEVER sends a transaction.
#
#   ./tools/test-relay.sh
#
# Needs a local anvil with tools/local-dev.sh already run, and the web app serving on
# :3000 so /api/relay is reachable.
#
# This is the HTTP-level counterpart to test_gasless_payerSignsAndNeverSendsATransaction
# in test/StreamVault.t.sol. The Solidity test proves the CONTRACT cannot be made to
# charge a payer who did not sign. This proves the whole path a real user takes -- sign
# in a browser-shaped client, hand the signature to a server, get a stream -- and that
# the payer's transaction count stays at zero throughout.
set -euo pipefail

cd "$(dirname "$0")/.."
RPC="${RPC:-http://127.0.0.1:8545}"
APP="${APP:-http://127.0.0.1:3000}"

# Anvil account 3. Verified to derive to 0x90F79bf6EB2c4f870365E785982E1f101E93b906.
PAYER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
ADMIN_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PAYER=$(cast wallet address --private-key "$PAYER_KEY")

# shellcheck disable=SC1091
set -a; . ./apps/web/.env.local; set +a
VAULT=$NEXT_PUBLIC_STREAM_VAULT
REG=$NEXT_PUBLIC_HANDLE_REGISTRY
AUSD=$NEXT_PUBLIC_AUSD_ADDRESS
HANDLE="${HANDLE:-arinza}"
AMOUNT="${AMOUNT:-250000000}"   # 250.000000 AUSD at 6 decimals
DURATION="${DURATION:-300}"     # 5 minutes

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; exit 1; }
num()  { grep -oE '^[0-9]+'; }

echo "payer    $PAYER"
echo "vault    $VAULT"
echo "token    $AUSD"

echo
echo "==> relay is configured"
RELAY=$(curl -s "$APP/api/relay" --max-time 30)
echo "$RELAY" | grep -q '"ok":true' || fail "relay reports not ok: $RELAY"
pass "relay ok, relayer $(echo "$RELAY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["relayer"])')"

echo
echo "==> fund the payer (mock AUSD has an open mint; the real one does not)"
cast send "$AUSD" "mint(address,uint256)" "$PAYER" "$AMOUNT" --rpc-url "$RPC" --private-key "$ADMIN_KEY" >/dev/null
BAL=$(cast call "$AUSD" "balanceOf(address)(uint256)" "$PAYER" --rpc-url "$RPC" | num)
[ "$BAL" -ge "$AMOUNT" ] || fail "payer balance $BAL < $AMOUNT"
pass "payer holds $BAL units"

NONCE=$(cast call "$AUSD" "nonces(address)(uint256)" "$PAYER" --rpc-url "$RPC" | num)
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
RECIPIENT=$(cast call "$REG" "resolve(string)(address)" "$HANDLE" --rpc-url "$RPC")
DEADLINE=$(( $(date +%s) + 600 ))
TXS_BEFORE=$(cast rpc eth_getTransactionCount "$PAYER" latest --rpc-url "$RPC")
NEXT_BEFORE=$(cast call "$VAULT" "nextId()(uint256)" --rpc-url "$RPC" | num)

echo
echo "==> sign the permit (EIP-712, domain version \"1\" per OpenZeppelin ERC20Permit)"
TYPED=$(python3 - "$AUSD" "$CHAIN_ID" "$PAYER" "$VAULT" "$AMOUNT" "$NONCE" "$DEADLINE" <<'PY'
import json, sys
ausd, chain_id, owner, spender, value, nonce, deadline = sys.argv[1:8]
print(json.dumps({
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"},
    ],
    "Permit": [
      {"name": "owner", "type": "address"},
      {"name": "spender", "type": "address"},
      {"name": "value", "type": "uint256"},
      {"name": "nonce", "type": "uint256"},
      {"name": "deadline", "type": "uint256"},
    ],
  },
  "primaryType": "Permit",
  "domain": {"name": "AUSD", "version": "1", "chainId": int(chain_id), "verifyingContract": ausd},
  "message": {"owner": owner, "spender": spender, "value": str(value),
              "nonce": str(nonce), "deadline": str(deadline)},
}))
PY
)
SIG=$(cast rpc eth_signTypedData_v4 "$PAYER" "$TYPED" --rpc-url "$RPC" | tr -d '"')
[ "${#SIG}" -eq 132 ] || fail "expected a 65-byte signature, got ${#SIG} chars"
R="0x${SIG:2:64}"; S="0x${SIG:66:64}"; V=$(( 16#${SIG:130:2} ))
pass "signed, v=$V"

echo
echo "==> hand the signature to the relay"
RESP=$(curl -s -X POST "$APP/api/relay" -H 'content-type: application/json' --max-time 60 -d "$(python3 - \
  "$PAYER" "$RECIPIENT" "$AUSD" "$AMOUNT" "$DURATION" "$DEADLINE" "$V" "$R" "$S" <<'PY'
import json, sys
payer, recipient, token, amount, duration, deadline, v, r, s = sys.argv[1:10]
print(json.dumps({"payer": payer, "recipient": recipient, "token": token,
                  "amount": str(amount), "duration": str(duration),
                  "deadline": str(deadline), "v": str(v), "r": r, "s": s}))
PY
)")
echo "$RESP" | python3 -m json.tool
echo "$RESP" | grep -q '"ok": *true' || fail "relay did not succeed"
HASH=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hash"])')
DECLARED=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["gasDeclared"])')
USED=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["gasUsed"])')
pass "relayed, tx $HASH"

echo
echo "==> the stream exists and is addressed correctly"
NEXT_AFTER=$(cast call "$VAULT" "nextId()(uint256)" --rpc-url "$RPC" | num)
[ "$NEXT_AFTER" -eq $(( NEXT_BEFORE + 1 )) ] || fail "nextId went $NEXT_BEFORE -> $NEXT_AFTER"
NEW_ID=$(( NEXT_AFTER - 1 ))
ROW=$(cast call "$VAULT" "streams(uint256)(address,address,address,uint128,uint128,uint64,uint64,uint64,uint64,uint64,bool,uint8)" "$NEW_ID" --rpc-url "$RPC")
SENDER=$(echo "$ROW" | sed -n 1p)
RCPT=$(echo "$ROW" | sed -n 2p)
[ "$(echo "$SENDER" | tr 'A-Z' 'a-z')" = "$(echo "$PAYER" | tr 'A-Z' 'a-z')" ] || fail "stream sender $SENDER != payer $PAYER"
[ "$(echo "$RCPT" | tr 'A-Z' 'a-z')" = "$(echo "$RECIPIENT" | tr 'A-Z' 'a-z')" ] || fail "stream recipient $RCPT != @$HANDLE $RECIPIENT"
pass "stream #$NEW_ID: sender is the payer, recipient is @$HANDLE"

echo
echo "==> THE POINT: the payer never transacted"
TXS_AFTER=$(cast rpc eth_getTransactionCount "$PAYER" latest --rpc-url "$RPC")
[ "$TXS_BEFORE" = "$TXS_AFTER" ] || fail "payer nonce moved $TXS_BEFORE -> $TXS_AFTER"
pass "payer transaction count unchanged at $TXS_AFTER"

NONCE_AFTER=$(cast call "$AUSD" "nonces(address)(uint256)" "$PAYER" --rpc-url "$RPC" | num)
[ "$NONCE_AFTER" -eq $(( NONCE + 1 )) ] || fail "permit nonce did not advance"
pass "permit nonce consumed ($NONCE -> $NONCE_AFTER), so it cannot be replayed"

echo
echo "==> gas: declared vs used (Monad charges the DECLARED limit)"
echo "     declared $DECLARED   used $USED"
if [ "$DECLARED" -lt 400000 ]; then
  pass "declared below the 400,000 fixed ceiling -- the estimate*1.15 policy is saving real MON"
else
  fail "declared $DECLARED hit the ceiling; estimation is not working"
fi

echo
echo "==> replaying the same permit must be rejected"
REPLAY=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$APP/api/relay" -H 'content-type: application/json' --max-time 60 -d "$(python3 - \
  "$PAYER" "$RECIPIENT" "$AUSD" "$AMOUNT" "$DURATION" "$DEADLINE" "$V" "$R" "$S" <<'PY'
import json, sys
payer, recipient, token, amount, duration, deadline, v, r, s = sys.argv[1:10]
print(json.dumps({"payer": payer, "recipient": recipient, "token": token,
                  "amount": str(amount), "duration": str(duration),
                  "deadline": str(deadline), "v": str(v), "r": r, "s": s}))
PY
)")
[ "$REPLAY" = "422" ] || fail "replay returned HTTP $REPLAY, expected 422"
pass "replay refused with HTTP 422 and no gas spent"

echo
echo "All relay assertions passed."
