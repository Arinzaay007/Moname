#!/usr/bin/env python3
"""Generate apps/web/lib/abi.ts from forge build artifacts.

Source of truth is the compiled contract, never a hand-written ABI. Run after any
change to src/:

    forge build && python3 tools/gen-abi.py
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def abi_of(contract, name):
    p = os.path.join(ROOT, "out", f"{contract}.sol", f"{name}.json")
    if not os.path.exists(p):
        sys.exit(f"missing {p}\nrun: forge build")
    with open(p) as f:
        return json.load(f)["abi"]

# Minimal ERC-20 + EIP-2612 surface. AUSD and USDC on Monad are both 6 decimals and
# both permit-capable (verified live on chain 143), so one ABI serves either.
ERC20_PERMIT = [
  {"type":"function","name":"balanceOf","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"decimals","stateMutability":"view","inputs":[],"outputs":[{"type":"uint8"}]},
  {"type":"function","name":"symbol","stateMutability":"view","inputs":[],"outputs":[{"type":"string"}]},
  {"type":"function","name":"allowance","stateMutability":"view","inputs":[{"name":"owner","type":"address"},{"name":"spender","type":"address"}],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"type":"bool"}]},
  {"type":"function","name":"transfer","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"type":"bool"}]},
  {"type":"function","name":"DOMAIN_SEPARATOR","stateMutability":"view","inputs":[],"outputs":[{"type":"bytes32"}]},
  {"type":"function","name":"nonces","stateMutability":"view","inputs":[{"name":"owner","type":"address"}],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"permit","stateMutability":"nonpayable","inputs":[
     {"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},
     {"name":"deadline","type":"uint256"},{"name":"v","type":"uint8"},{"name":"r","type":"bytes32"},{"name":"s","type":"bytes32"}],"outputs":[]},
]

def main():
    sv = abi_of("StreamVault", "StreamVault")
    hr = abi_of("HandleRegistry", "HandleRegistry")
    out = os.path.join(ROOT, "apps", "web", "lib", "abi.ts")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    body = [
        "// Generated from forge artifacts by tools/gen-abi.py. Do not edit by hand.",
        "// Source of truth: src/StreamVault.sol, src/HandleRegistry.sol",
        "",
        f"export const streamVaultAbi = {json.dumps(sv, indent=2)} as const;",
        "",
        f"export const handleRegistryAbi = {json.dumps(hr, indent=2)} as const;",
        "",
        f"export const erc20PermitAbi = {json.dumps(ERC20_PERMIT, indent=2)} as const;",
        "",
    ]
    open(out, "w").write("\n".join(body))
    fns = sorted({e["name"] for e in sv if e.get("type") == "function"})
    print(f"wrote {out}")
    print(f"  StreamVault:    {len(sv)} entries, {len(fns)} functions")
    print(f"  HandleRegistry: {len(hr)} entries")
    print(f"  functions: {', '.join(fns)}")

if __name__ == "__main__":
    main()
