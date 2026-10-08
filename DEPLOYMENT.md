# Monad mainnet deployment

Chain **143** (Monad mainnet). Recorded 2026-10-08 10:01 UTC
by `tools/deploy-mainnet.sh` from `broadcast/Deploy.s.sol/143/run-latest.json`.

| Contract | Address | Deploy tx |
|---|---|---|
| `HandleRegistry` | `0x87dbd64e79e11510223299600f8d67428f82e710` | [`0xe34c8097da6ecbf8…`](https://monadscan.com/tx/0xe34c8097da6ecbf8e5273da45a68f09e67dbeac40421d9e8ea100f3c325d3485) |
| `StreamVault` | `0x2c0dd3385d545d54d7185432365917abfd62e52f` | [`0xb39315ae2e37f144…`](https://monadscan.com/tx/0xb39315ae2e37f1446c24e8a6a9a2eb7b8036a0c80857b31812477670aeb71c86) |

**Token:** AUSD `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` (6 decimals)

**USDC (secondary):** `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`

**Inbound forwarder:** `0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f` — Relay's destination
executor, verified a 4,720-byte contract on chain 143. It is the `msg.sender` that calls
`creditArrival` when a cross-chain transfer lands.

## The trust this creates

Whoever holds `forwarder` can direct existing vault balance to any recipient, because
`creditArrival` pulls nothing and only checks that the vault holds the tokens. Setting
Relay's executor therefore trusts Relay's executor and its solver network. That is
better-trusted than a single key we hold, but it is not trustlessness, and it is asserted
by `test_creditArrival_trustBoundary_forwarderCanDirectExistingVaultBalance` rather than
left as a comment.

## Running the app against this deployment

`apps/web/.env.local` is gitignored, so it has to be recreated. For mainnet:

```bash
cd apps/web
cat > .env.local <<'EOF'
NEXT_PUBLIC_CHAIN=mainnet
MONAD_RPC_URL=https://rpc.monad.xyz
RELAYER_PRIVATE_KEY=<a funded key — see below>
EOF
npm install && npm run dev
```

The contract addresses are **not** needed in the env: `lib/config.ts` carries them as
mainnet-mode defaults, so a fresh clone points at this deployment with nothing but the two
lines above. Setting `NEXT_PUBLIC_CHAIN=local` or `testnet` disables those defaults on
purpose, so the app still refuses to pretend it is connected when addresses are unset.

Verify it really is on mainnet rather than trusting the label:

```bash
curl -s localhost:3000/api/relay | jq '{chainMode,chainId,configured,streamVault}'
# expect: mainnet, 143, true, 0x2c0dd3385d545d54d7185432365917abfd62e52f
```

### The relayer key

`RELAYER_PRIVATE_KEY` pays gas so that other people never have to. It can **never move a
user's funds** — it only broadcasts permits they signed — so an already-exposed key holding
a little MON is exactly the right thing to use, and a fresh privileged key is exactly the
wrong one.

If unset, `/api/relay` returns 503 and the UI says the relay is down and offers the honest
fallback: broadcast the permit yourself, which costs MON. Nothing pretends to be gasless
when it is not.

### What cannot be tested on mainnet yet

- **No handle is registered.** `HandleRegistry.totalHandles()` is 0, so every `/h/@…` page
  correctly reports the handle as unregistered rather than inventing data.
- **AUSD has a permissioned mint and no public faucet** on mainnet, so the payment flow needs
  real AUSD — bridged in via one of the twelve verified Relay corridors, or acquired from a
  Monad DEX. Local mode (`bash tools/local-dev.sh`) exists precisely so the product is fully
  drivable without it: `MockAUSD` has an open `mint` and the UI surfaces a mint button in
  local mode only, labelled as such.
