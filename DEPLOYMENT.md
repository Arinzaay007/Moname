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
