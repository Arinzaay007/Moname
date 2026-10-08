#!/usr/bin/env bash
# Deploy Moname to Monad MAINNET (chain 143) and record everything §9.2 asks for.
#
#   MONAD_PRIVATE_KEY=0x... bash tools/deploy-mainnet.sh            # dry run only
#   MONAD_PRIVATE_KEY=0x... bash tools/deploy-mainnet.sh --broadcast
#
# Refuses to broadcast without the explicit flag, so an accidental invocation
# cannot spend real MON.
#
# SECURITY: use a FRESH key funded with only what the deploy needs (~0.6 MON),
# never a key that holds anything else. Sweep the remainder afterwards and
# abandon the key. See the balance line this script prints before it broadcasts.
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.foundry/bin:$PATH"
RPC="https://rpc.monad.xyz"
BROADCAST=0
[ "${1:-}" = "--broadcast" ] && BROADCAST=1

# Relay's destination executor on Monad, verified with `cast codesize` = 4720 bytes.
# This is the msg.sender that will call creditArrival when a cross-chain transfer lands.
FORWARDER="${FORWARDER_ADDRESS:-0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f}"
# base fee measured at 100 gwei; 105 gives a little headroom without overpaying.
# Monad charges gas on the DECLARED limit, not gas used, so this is real money.
GAS_PRICE="${GAS_PRICE:-105000000000}"

command -v forge >/dev/null || { echo "foundry not installed: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2; exit 1; }
[ -n "${MONAD_PRIVATE_KEY:-}" ] || { echo "MONAD_PRIVATE_KEY is not set" >&2; exit 1; }

echo "==> preflight"
CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN" = "143" ] || { echo "  expected chain 143, got $CHAIN" >&2; exit 1; }
echo "    chain id        $CHAIN"
echo "    block           $(cast block-number --rpc-url "$RPC")"

DEPLOYER=$(cast wallet address --private-key "$MONAD_PRIVATE_KEY")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
BAL_MON=$(python3 -c "print(f'{$BAL/1e18:.9f}')")
echo "    deployer        $DEPLOYER"
echo "    balance         $BAL_MON MON"

# The measured dry-run cost, so the check is against a real number rather than a guess.
NEEDED=$(python3 -c "print(int(0.60 * 10**18))")
python3 -c "import sys; sys.exit(0 if $BAL >= $NEEDED else 1)" || {
  echo "  balance is below the 0.6 MON the dry run estimated as required" >&2
  echo "  (dry run: 2,672,289 gas at a 202 gwei max fee = 0.539802378 MON)" >&2
  exit 1
}

echo "    forwarder       $FORWARDER"
echo "    forwarder code  $(cast codesize "$FORWARDER" --rpc-url "$RPC") bytes"
[ "$(cast codesize "$FORWARDER" --rpc-url "$RPC")" -gt 0 ] || { echo "  forwarder is not a contract" >&2; exit 1; }

echo "    token           $(cast call 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a 'symbol()(string)' --rpc-url "$RPC") (AUSD, 6 dp)"
echo "    gas price       $(python3 -c "print(f'{$GAS_PRICE/1e9:.2f}')") gwei"

echo
echo "==> compiling"
{ forge build 2>&1 | grep -iE "^Error|Compiler run" | head -3; } || true

echo
echo "==> simulating"
set +e
FORWARDER_ADDRESS="$FORWARDER" forge script script/Deploy.s.sol:Deploy --rpc-url monad \
  --private-key "$MONAD_PRIVATE_KEY" --gas-price "$GAS_PRICE" 2>&1 | \
  grep -E "StreamVault:|HandleRegistry:|forwarder:|primary token:|Estimated total gas|Estimated amount|Error" | sed 's/^/    /'
set -e

if [ "$BROADCAST" != "1" ]; then
  echo
  echo "==> dry run only. Nothing was broadcast and no MON was spent."
  echo "    To deploy for real:  bash tools/deploy-mainnet.sh --broadcast"
  exit 0
fi

echo
echo "==> BROADCASTING — this spends real MON"
FORWARDER_ADDRESS="$FORWARDER" forge script script/Deploy.s.sol:Deploy --rpc-url monad \
  --broadcast --private-key "$MONAD_PRIVATE_KEY" --gas-price "$GAS_PRICE" 2>&1 | tee /tmp/deploy.log | tail -25

RUN=broadcast/Deploy.s.sol/143/run-latest.json
[ -f "$RUN" ] || { echo "  no broadcast record at $RUN" >&2; exit 1; }

echo
echo "==> recording"
python3 - "$RUN" <<'PY' > DEPLOYMENT.md
import json, sys, datetime
run = json.load(open(sys.argv[1]))
txs = run.get("transactions", [])
deploys = [t for t in txs if t.get("transactionType") == "CREATE"]
print("# Monad mainnet deployment")
print()
print(f"Chain **143** (Monad mainnet). Recorded {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
print(f"by `tools/deploy-mainnet.sh` from `broadcast/Deploy.s.sol/143/run-latest.json`.")
print()
print("| Contract | Address | Deploy tx |")
print("|---|---|---|")
for t in deploys:
    name = (t.get("contractName") or "?")
    addr = (t.get("contractAddress") or "?")
    h = (t.get("hash") or "?")
    print(f"| `{name}` | `{addr}` | [`{h[:18]}…`](https://monadscan.com/tx/{h}) |")
print()
print("**Token:** AUSD `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` (6 decimals)")
print()
print("**USDC (secondary):** `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`")
print()
print("**Inbound forwarder:** `0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f` — Relay's destination")
print("executor, verified a 4,720-byte contract on chain 143. It is the `msg.sender` that calls")
print("`creditArrival` when a cross-chain transfer lands.")
print()
print("## The trust this creates")
print()
print("Whoever holds `forwarder` can direct existing vault balance to any recipient, because")
print("`creditArrival` pulls nothing and only checks that the vault holds the tokens. Setting")
print("Relay's executor therefore trusts Relay's executor and its solver network. That is")
print("better-trusted than a single key we hold, but it is not trustlessness, and it is asserted")
print("by `test_creditArrival_trustBoundary_forwarderCanDirectExistingVaultBalance` rather than")
print("left as a comment.")
PY
cat DEPLOYMENT.md
echo
echo "==> verifying on chain"
for name in StreamVault HandleRegistry; do
  ADDR=$(python3 -c "
import json
run=json.load(open('$RUN'))
for t in run.get('transactions',[]):
    if t.get('contractName')=='$name': print(t.get('contractAddress')); break
")
  [ -n "$ADDR" ] || { echo "    $name: address not found in the broadcast record" >&2; continue; }
  printf "    %-16s %s  codesize=%s\n" "$name" "$ADDR" "$(cast codesize "$ADDR" --rpc-url "$RPC")"
done
VAULT=$(python3 -c "
import json
run=json.load(open('$RUN'))
for t in run.get('transactions',[]):
    if t.get('contractName')=='StreamVault': print(t.get('contractAddress')); break
") || true
if [ -n "$VAULT" ]; then
  printf "    %-16s forwarder() = %s\n" "StreamVault" "$(cast call "$VAULT" 'forwarder()(address)' --rpc-url "$RPC")"
  printf "    %-16s nextId()    = %s\n" "" "$(cast call "$VAULT" 'nextId()(uint256)' --rpc-url "$RPC")"
fi

echo
echo "==> done"
echo "    DEPLOYMENT.md written — commit it."
echo "    Sweep the leftover MON off $DEPLOYER and abandon that key."
