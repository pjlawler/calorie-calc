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

// JWS uses base64url (RFC 4648 §5): + → -, / → _, no padding. JSON Web Tokens from
// StoreKit 2 and App Store Server Notifications V2 are emitted in this form.
export function b64urlDecode(s: string): Uint8Array {
  let normalized = s.replace(/-/g, "+").replace(/_/g, "/");
  while (normalized.length % 4 !== 0) normalized += "=";
  const bin = atob(normalized);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Convert an ECDSA-Sig-Value SEQUENCE { r INTEGER, s INTEGER } (DER) into the raw
// `r || s` format Web Crypto's ECDSA verify expects. `componentBytes` is 32 for
// P-256 and 48 for P-384. Used both for cert chain validation (varies by curve)
// and for JWS signatures wrapped in DER (AdMob SSV does this; StoreKit JWS
// signatures are already raw r||s).
export function derToRawECDSASig(der: Uint8Array, componentBytes: number): Uint8Array {
  if (der[0] !== 0x30) throw new Error("sig: outer not SEQUENCE");
  let p = 2;
  if ((der[1]! & 0x80) !== 0) p = 2 + (der[1]! & 0x7f);

  if (der[p] !== 0x02) throw new Error("sig: r not INTEGER");
  let rLen = der[p + 1]!;
  let rStart = p + 2;
  if (der[rStart] === 0x00) { rStart++; rLen--; }
  const r = der.subarray(rStart, rStart + rLen);
  p = rStart + rLen;

  if (der[p] !== 0x02) throw new Error("sig: s not INTEGER");
  let sLen = der[p + 1]!;
  let sStart = p + 2;
  if (der[sStart] === 0x00) { sStart++; sLen--; }
  const s = der.subarray(sStart, sStart + sLen);

  const out = new Uint8Array(componentBytes * 2);
  out.set(r, componentBytes - r.length);
  out.set(s, componentBytes * 2 - s.length);
  return out;
}
