import { parseSignature, type PublicClient, type WalletClient } from "viem";
import { erc20PermitAbi } from "./abi";

/**
 * EIP-2612 permit signing for AUSD / USDC on Monad.
 *
 * This is the whole gasless wedge: the payer signs a typed-data message and never sends a
 * transaction, so they never need MON. StreamVault.createStreamWithPermit consumes the
 * signature and pulls the funds, and anyone may submit it — the signature is the
 * authorisation, not the submitter.
 *
 * Both AUSD and USDC on Monad expose a real DOMAIN_SEPARATOR and are 6 decimals, verified
 * live on chain 143 by test/Fork.t.sol. OZ's ERC20Permit uses EIP-712 version "1", which
 * is what MockAUSD matches in the unit tests.
 */

export const PERMIT_DOMAIN_VERSION = "1";

export type Permit = {
  owner: `0x${string}`;
  spender: `0x${string}`;
  value: bigint;
  nonce: bigint;
  deadline: bigint;
};

export type SignedPermit = Permit & { v: number; r: `0x${string}`; s: `0x${string}` };

export async function signPermit(
  publicClient: PublicClient,
  walletClient: WalletClient,
  token: `0x${string}`,
  tokenName: string,
  permit: Permit,
): Promise<SignedPermit> {
  const chainId = await publicClient.getChainId();
  const [account] = await walletClient.getAddresses();
  if (!account) throw new Error("wallet client has no account");

  const signature = await walletClient.signTypedData({
    account,
    domain: {
      name: tokenName,
      version: PERMIT_DOMAIN_VERSION,
      chainId,
      verifyingContract: token,
    },
    types: {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Permit",
    message: permit,
  });

  // viem 2.37 replaced splitSignature with parseSignature, which returns a Signature
  // object. EIP-2612 wants v as a uint8 recovery id in {27,28}.
  const sig = parseSignature(signature);
  const v = sig.yParity + 27;
  return { ...permit, v, r: sig.r, s: sig.s };
}

/** Reads the token's current nonce for an owner. A permit replaying an old nonce reverts. */
export async function permitNonce(
  publicClient: PublicClient,
  token: `0x${string}`,
  owner: `0x${string}`,
): Promise<bigint> {
  return publicClient.readContract({
    address: token,
    abi: erc20PermitAbi,
    functionName: "nonces",
    args: [owner],
  });
}
