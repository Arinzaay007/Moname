import type { Metadata } from "next";
import RecipientView from "@/components/RecipientView";
import { normalizeHandle } from "@/lib/scan";

// The handle only exists on-chain, so this route cannot be statically generated:
// resolving it is a live read. The shell still renders without one.
export const dynamic = "force-dynamic";

type Params = { handle: string };

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { handle } = await params;
  // Next hands us the raw segment, so `/h/%40arinza` arrives as "%40arinza" and the
  // `%` fails the on-chain charset. Decode here exactly as the page component does,
  // or the shared link loses its title.
  const clean = normalizeHandle(decodeURIComponent(handle));
  const title = clean ? `@${clean} is being paid on Moname` : "Moname";
  return {
    title,
    description: clean
      ? `Watch payments stream to @${clean} in real time on Monad. No wallet, no account, no setup — this page is read-only.`
      : "Moname recipient page.",
  };
}

export default async function Page({ params }: { params: Promise<Params> }) {
  const { handle } = await params;
  return <RecipientView rawHandle={decodeURIComponent(handle)} />;
}
