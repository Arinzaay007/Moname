import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Moname — money that streams in by the second",
  description:
    "Cross-border payments that land on Monad as AUSD and stream to the recipient by the second. One passkey, no seed phrase, no gas — and only the keys you actually use.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
