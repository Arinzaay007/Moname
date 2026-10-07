# Deferred, not done

Recorded so the submission is honest about its edges. Everything here was
**deliberately cut** to keep the demoed path real rather than broad.

## Cut for Metropolis

| Item | Why it was cut |
|---|---|
| Payroll / multi-recipient batches | Streaming to one recipient proves the Monad capability; batching is arithmetic on top |
| Payment walls (pay-per-article) | A second product surface, same rails, no new on-chain logic |
| Pay codes / QR | Needs a mobile surface to be credible |
| HTTP 402 agent API | Genuinely interesting, but a different judge and a different demo |
| Premium-handle marketplace | Monetisation, not capability |
| Native mobile app | Web + passkeys already removes the seed phrase |
| Aurora Intents for inbound | Withdrawals were paused across 11 networks including Monad after the 1 Oct 2026 Omni exploit. Relay is the default; CCTP V2 is the upgrade path |
| **Naira off-ramp (Switch) as a built feature** | Demoted to a documented exit. Switch settles **USDC and USDT0** on Monad, not AUSD, so a naira leg needs an AUSD→USDC hop through the Curve 3pool first — an extra swap, extra slippage and a third-party dependency, added in the final week. The on-chain product is token-in → streams → token-out; the off-ramp is a partnership to describe (and a real one — it is how WinkPay already pays out), not to wire up under deadline. Revisit once streaming and inbound are solid |
| On-chain passkey verification via the `secp256r1` precompile at `0x0100` | The precompile exists on Monad (EIP-7951) and this is the right long-term shape, but Mera + a controller allowlist gets the same security property shipped |

## Promoted during the build

- **AUSD is the primary token, not a later addition.** It was originally parked here on the reasoning that Switch does not settle it. That reasoning was wrong twice over: the Agora cross-border bounty names AUSD explicitly, and AUSD is the only dollar stablecoin deployed on both Monad networks with identical bytecode. It costs nothing to support because StreamVault is token-agnostic and both tokens are 6 decimals.

## After the hackathon

- **Naira payout in-product**, once the AUSD→USDC→Switch hop is worth the added surface. Requires either Switch adding AUSD or accepting a swap leg with its slippage.
- **CCTP V2 with `hookData`** so the inbound bridge call atomically opens the stream in one transaction, removing the relayer from the trust path.
- **Envio HyperSync indexer.** Monad full nodes do not serve arbitrary historic state, so a stream history view needs an indexer or a local mirror. Currently the UI reads live state only.
- **`secp256r1` passkey verification on-chain**, replacing the controller allowlist with keys proved directly from the passkey.
