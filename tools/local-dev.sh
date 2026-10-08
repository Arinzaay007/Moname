#!/usr/bin/env bash
# Bring up a complete local Moname demo against a Monad-mode anvil.
#
#   ./tools/local-dev.sh            # deploy + write apps/web/.env.local + seed demo data
#   ./tools/local-dev.sh --no-seed  # deploy only
#
# Assumes anvil is already running on 127.0.0.1:8545:
#
#   anvil --network monad --chain-id 10143 --block-time 1
#
# Why this exists: the real AUSD has a permissioned mint and there is no public faucet, so
# the AUSD-funded flow cannot be demonstrated on a network we do not control. test/mocks/
# MockAUSD.sol is a faithful stand-in — 6 decimals, symbol AUSD, a real EIP-712 domain — so
# the permit path is exercised for real rather than mocked at the UI layer. Its open mint is
# why the app shows a "mint test funds" button in local mode ONLY.
set -euo pipefail

cd "$(dirname "$0")/.."
RPC="${RPC:-http://127.0.0.1:8545}"
# Anvil's well-known account 0. Test key, published by anvil itself, never a secret.
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
PAYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# Anvil account 1 stands in for a passkey-derived receiving key.
RECIPIENT="${RECIPIENT:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
HANDLE="${HANDLE:-arinza}"
SEED=1
[ "${1:-}" = "--no-seed" ] && SEED=0

command -v forge >/dev/null || { echo "forge not found — install Foundry and ensure it is on PATH" >&2; exit 1; }
cast chain-id --rpc-url "$RPC" >/dev/null || { echo "no chain at $RPC — start anvil first" >&2; exit 1; }

deployed() { grep -oE "Deployed to: 0x[0-9a-fA-F]{40}" | grep -oE "0x[0-9a-fA-F]{40}"; }

echo "==> deploying"
AUSD=$(forge create test/mocks/MockAUSD.sol:MockAUSD \
  --rpc-url "$RPC" --private-key "$PK" --broadcast 2>&1 | deployed)
# Stand in for Relay's destination executor so creditArrival is LIVE locally and the
# inbound path can actually be demoed. On mainnet this must be
# MonameConfig.RELAY_EXECUTOR_MONAD (0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f).
# The address is DERIVED from the key rather than hardcoded — an earlier version of this
# script assumed an anvil account index and was wrong, which left the relayer unfunded.
FWD_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
FORWARDER=$(cast wallet address --private-key "$FWD_KEY")
VAULT=$(forge create src/StreamVault.sol:StreamVault \
  --rpc-url "$RPC" --private-key "$PK" --broadcast \
  --constructor-args "$FORWARDER" 2>&1 | deployed)
REG=$(forge create src/HandleRegistry.sol:HandleRegistry \
  --rpc-url "$RPC" --private-key "$PK" --broadcast 2>&1 | deployed)

for pair in "MockAUSD:$AUSD" "StreamVault:$VAULT" "HandleRegistry:$REG"; do
  [ -n "${pair#*:}" ] || { echo "deploy failed for ${pair%%:*}" >&2; exit 1; }
  echo "    ${pair%%:*}  ${pair#*:}"
done

echo "    inbound forwarder  $FORWARDER  (stands in for Relay's executor)"
# The forwarder pays gas to call creditArrival, so it needs a balance.
cast send "$FORWARDER" --value 2ether --rpc-url "$RPC" --private-key "$PK" >/dev/null

echo "==> writing apps/web/.env.local"
# Preserve a relayer key that is already configured. Rewriting this file used to
# silently delete it, which left the relay unconfigured and quietly turned the
# "gasless" flow back into a payer-pays-gas flow.
EXISTING_RELAYER=""
if [ -f apps/web/.env.local ]; then
  EXISTING_RELAYER=$(grep '^RELAYER_PRIVATE_KEY=0x' apps/web/.env.local | cut -d= -f2 || true)
fi
# Anvil account 4's published key, used when nothing is configured. Anvil prints this
# itself, so it is not a secret; it is here so the local demo works out of the box.
RELAYER_KEY="${EXISTING_RELAYER:-0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a}"

cat > apps/web/.env.local <<EOF
NEXT_PUBLIC_CHAIN=local
NEXT_PUBLIC_STREAM_VAULT=$VAULT
NEXT_PUBLIC_HANDLE_REGISTRY=$REG
NEXT_PUBLIC_AUSD_ADDRESS=$AUSD
MONAD_RPC_URL=$RPC
# Server-side only: no NEXT_PUBLIC_ prefix, so it cannot be inlined into a client bundle.
# This key only ever pays gas for other people's permits; it can never move their funds.
RELAYER_PRIVATE_KEY=$RELAYER_KEY
# Local stand-in for Relay's destination executor (0xb92fe925… on mainnet).
# Server-side only: it calls creditArrival when a cross-chain transfer lands.
INBOUND_FORWARDER_KEY=$FWD_KEY
NEXT_PUBLIC_INBOUND_FORWARDER=$FORWARDER
EOF

# The relayer pays gas on other people's behalf, so it needs a balance. Fund whatever
# address the configured key derives to rather than assuming it is one of anvil's
# pre-funded accounts -- a relay that silently has no MON fails in a confusing way.
RADDR=$(cast wallet address --private-key "$RELAYER_KEY")
echo "==> funding relayer $RADDR"
cast send "$RADDR" --value 5ether --rpc-url "$RPC" --private-key "$PK" >/dev/null
printf '    balance    '; cast balance "$RADDR" --rpc-url "$RPC" --ether; echo " MON"

if [ "$SEED" = "1" ]; then
  echo "==> seeding demo data"
  send() { cast send "$@" --rpc-url "$RPC" --private-key "$PK" >/dev/null; }
  send "$REG"   "registerTo(string,address)"            "$HANDLE" "$RECIPIENT"
  send "$AUSD"  "mint(address,uint256)"                 "$PAYER"  100000000000
  send "$AUSD"  "approve(address,uint256)"              "$VAULT"  100000000000
  # Three streams at three different rates, so the landing page shows distinct slopes.
  send "$VAULT" "createStream(address,address,uint128,uint64)" "$RECIPIENT" "$AUSD" 500000000  600
  send "$VAULT" "createStream(address,address,uint128,uint64)" "$RECIPIENT" "$AUSD" 1200000000 3600
  send "$VAULT" "createStream(address,address,uint128,uint64)" "$RECIPIENT" "$AUSD" 75000000   120
  echo "    @$HANDLE -> $RECIPIENT, 3 streams open"
fi

echo
echo "==> verify"
printf '    resolve(@%s)  ' "$HANDLE"; cast call "$REG" "resolve(string)(address)" "$HANDLE" --rpc-url "$RPC"
printf '    nextId           '; cast call "$VAULT" "nextId()(uint256)" --rpc-url "$RPC"
printf '    AUSD symbol      '; cast call "$AUSD" "symbol()(string)" --rpc-url "$RPC"
printf '    AUSD decimals    '; cast call "$AUSD" "decimals()(uint8)" --rpc-url "$RPC"
echo
echo "Done. Start the app with:  cd apps/web && npm install && npm run dev"
echo "Then open  /  and  /h/@$HANDLE"
