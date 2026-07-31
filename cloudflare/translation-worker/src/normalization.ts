const whitespacePattern = /\s+/gu;
const combiningMarkPattern = /\p{M}/gu;

export function trimmedAndCollapsedSource(source: string): string {
  return source.trim().replace(whitespacePattern, " ");
}

export function normalizedSource(source: string): string {
  return trimmedAndCollapsedSource(source)
    .normalize("NFKD")
    .replace(combiningMarkPattern, "")
    .toLocaleLowerCase("en-US");
}

export async function sha256Digest(value: string): Promise<ArrayBuffer> {
  const bytes = new TextEncoder().encode(value);
  return crypto.subtle.digest("SHA-256", bytes);
}

export async function sha256(value: string): Promise<string> {
  const digest = await sha256Digest(value);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
