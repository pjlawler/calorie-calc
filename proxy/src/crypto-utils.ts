// Small Web Crypto helpers shared between attestation and assertion paths.

export function b64decode(s: string): Uint8Array {
  // App Attest emits standard base64 (with padding); the iOS client uses the same.
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64encode(buf: Uint8Array): string {
  let s = "";
  for (let i = 0; i < buf.length; i++) s += String.fromCharCode(buf[i]!);
  return btoa(s);
}

export async function sha256(buf: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

// Read a big-endian uint32 at `off`. Used for the App Attest authenticator-data counter.
export function readUint32BE(buf: Uint8Array, off: number): number {
  return (buf[off]! * 0x1000000) + ((buf[off + 1]! << 16) | (buf[off + 2]! << 8) | buf[off + 3]!);
}
