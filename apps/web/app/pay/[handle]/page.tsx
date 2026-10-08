import type { Metadata } from "next";
import PayerView from "@/components/PayerView";
import { normalizeHandle } from "@/lib/scan";

// The handle only exists on-chain, so resolving it is a live read.
export const dynamic = "force-dynamic";

type Params = { handle: string };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { handle } = await params;
  // Next hands us the raw segment, so `/pay/%40arinza` arrives as "%40arinza" and the
  // `%` fails the on-chain charset. Decode here exactly as the page component does.
  const clean = normalizeHandle(decodeURIComponent(handle));
  return {
    title: clean ? `Pay @${clean} on Moname` : "Moname",
    description: clean
      ? `Stream AUSD to @${clean} by the second on Monad. Sign one permit — no account, no passkey, no gas.`
      : "Moname payment page.",
  };
}

export default async function Page({ params }: { params: Promise<Params> }) {
  const { handle } = await params;
  return <PayerView rawHandle={decodeURIComponent(handle)} />;
}
