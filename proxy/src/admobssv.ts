// AdMob Server-Side Verification (SSV) for rewarded ads.
//
// When a user finishes a rewarded video, AdMob hits our callback URL with a GET
// containing query params describing the reward, plus `signature` and `key_id` at
// the end. We verify the signature is from one of AdMob's published keys before
// crediting the user — without this check, anyone could grant themselves credits
// by curling the callback URL with arbitrary params.
//
// Spec: https://developers.google.com/admob/android/ssv
//
// What's signed: the canonical query string is everything BEFORE `signature=`. The
// `key_id` parameter sits AFTER `signature` in AdMob's canonicalization (it's the
// only param outside the signed prefix that we need to read).
//
// Key rotation: AdMob occasionally rotates these keys with prior notice. To rotate,
// fetch https://gstatic.com/admob/reward/verifier-keys.json and replace PUBLIC_KEYS
// below with the current entries. The failure mode of stale keys is loud (every ad
// reward fails with `unknown_key_id_<n>`) and easy to fix.

import { b64decode, derToRawECDSASig } from "./crypto-utils";

// Map of AdMob keyId → base64-encoded SubjectPublicKeyInfo (from the `base64` field
// of the verifier-keys.json entries). Empty until populated during Phase 3 setup —
// a deploy with this empty will reject every reward callback, which is the intended
// fail-closed behavior.
//
// To populate: `curl https://gstatic.com/admob/reward/verifier-keys.json` and copy
// each `keyId` (numeric, stringified) and `base64` field into this map.
const PUBLIC_KEYS: Record<string, string> = {
  // "3335741209": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQg...",
};

export type SSVResult =
  | { ok: true; params: URLSearchParams }
  | { ok: false; error: string };

// Verify the signature on an AdMob SSV callback URL. Returns the parsed params on
// success so the caller can read `transaction_id`, `user_id`, etc. without parsing
// the query string twice.
export async function verifySSV(rawQueryString: string): Promise<SSVResult> {
  try {
    // AdMob signs everything before `&signature=`. Split deliberately on that
    // boundary so we get the exact bytes that were signed regardless of how
    // permissive any URL parser is about ordering or encoding.
    const sigMarker = "&signature=";
    const sigIdx = rawQueryString.indexOf(sigMarker);
    if (sigIdx < 0) return { ok: false, error: "missing_signature" };

    const signedMessage = rawQueryString.slice(0, sigIdx);
    const tail = rawQueryString.slice(sigIdx + 1); // "signature=...&key_id=..."

    // Pull `signature` and `key_id` out of the tail. Tail order per spec is always
    // signature first, key_id second, but we tolerate either order.
    const tailParams = new URLSearchParams(tail);
    const signatureB64Url = tailParams.get("signature");
    const keyId = tailParams.get("key_id");
    if (!signatureB64Url || !keyId) {
      return { ok: false, error: "missing_sig_or_keyid" };
    }

    const spkiB64 = PUBLIC_KEYS[keyId];
    if (!spkiB64) return { ok: false, error: `unknown_key_id_${keyId}` };

    // AdMob's signature is base64url-encoded DER ECDSA-Sig-Value (r,s SEQUENCE),
    // distinct from JWS where the same algorithm uses raw r||s. Convert to raw.
    const sigDer = b64UrlOrStandardDecode(signatureB64Url);
    const rawSig = derToRawECDSASig(sigDer, 32);

    const spki = b64decode(spkiB64);
    const key = await crypto.subtle.importKey(
      "spki",
      spki as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      rawSig as BufferSource,
      new TextEncoder().encode(signedMessage) as BufferSource,
    );
    if (!valid) return { ok: false, error: "bad_signature" };

    // Re-parse the full query so the caller sees every reward field.
    return { ok: true, params: new URLSearchParams(rawQueryString) };
  } catch (e) {
    return { ok: false, error: `ssv_failed: ${(e as Error).message}` };
  }
}

// AdMob historically used standard base64 with URL-unsafe chars; current docs use
// base64url. Accept both so a future change in their encoding doesn't silently
// start failing verification.
function b64UrlOrStandardDecode(s: string): Uint8Array {
  let normalized = s.replace(/-/g, "+").replace(/_/g, "/");
  while (normalized.length % 4 !== 0) normalized += "=";
  const bin = atob(normalized);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
