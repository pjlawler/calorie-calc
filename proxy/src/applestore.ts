// JWS verification for StoreKit 2 transactions and App Store Server Notifications V2.
//
// Apple emits all StoreKit 2 receipts and notifications as JWS in compact form:
//   header.payload.signature  (each segment base64url-encoded)
//
// The header carries an `x5c` certificate chain (leaf → intermediate → root) that we
// validate against Apple Root CA G3. The leaf cert's public key verifies the JWS
// signature itself; the chain ties that public key back to a pinned trust anchor so
// an attacker can't forge a JWS by minting their own cert.
//
// What this verifies:
//   • JWS structure: three base64url-encoded segments, ES256 alg, non-empty x5c.
//   • Cert chain: each cert's signature was made by the next cert's public key,
//     using ECDSA over the SHA-* indicated by each cert's signatureAlgorithm OID.
//   • Trust anchor: the topmost cert in the chain is Apple Root CA G3 (or signed
//     by its public key, in case Apple omits the self-signed root).
//   • JWS signature: the leaf cert's public key verifies ECDSA-SHA-256 over
//     `headerB64.payloadB64`.
//
// What this does NOT verify (intentional scope):
//   • Cert validity periods (notBefore/notAfter). Apple-issued certs are well-managed.
//   • Cert revocation (CRL/OCSP). Cloudflare Workers don't have a great fetch story
//     for these, and Apple controls the chain — revocation is theirs to enforce.
//   • Application-level claims (bundleId, productId, environment). Callers do that.

import { b64decode, b64urlDecode, bytesEqual, derToRawECDSASig } from "./crypto-utils";

// Apple Root CA G3, base64-encoded DER. Issued April 30 2014, valid through April 30
// 2039. Extracted from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer.
// The full DER is broken across lines for readability; b64decode handles concatenation.
const APPLE_ROOT_G3_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS" +
  "QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u" +
  "IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN" +
  "MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS" +
  "b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y" +
  "aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49" +
  "AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf" +
  "TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517" +
  "IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr" +
  "MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA" +
  "MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4" +
  "at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM" +
  "6BgD56KyKA==";

const APPLE_ROOT_G3_DER = b64decode(APPLE_ROOT_G3_B64);

// === Tiny DER reader (mirrors attest.ts's pattern; kept local for self-containment) ===

type DERField = { tag: number; length: number; valueStart: number; valueEnd: number };

function readTLV(buf: Uint8Array, off: number): DERField {
  const tag = buf[off]!;
  let p = off + 1;
  const first = buf[p]!;
  let length: number;
  if ((first & 0x80) === 0) {
    length = first;
    p += 1;
  } else {
    const n = first & 0x7f;
    if (n === 0 || n > 4) throw new Error("der: unsupported length encoding");
    length = 0;
    for (let i = 1; i <= n; i++) length = (length << 8) | buf[p + i]!;
    p += 1 + n;
  }
  return { tag, length, valueStart: p, valueEnd: p + length };
}

// Returns the bytes of the TBSCertificate SEQUENCE (the bytes that were signed),
// the raw signature value (BIT STRING contents, minus the leading unused-bits byte),
// and the bytes of the SubjectPublicKeyInfo SEQUENCE (suitable for importKey "spki").
function dissectCert(certDER: Uint8Array): {
  tbs: Uint8Array;
  signature: Uint8Array;
  spki: Uint8Array;
  sigHashAlg: "SHA-256" | "SHA-384";
} {
  const cert = readTLV(certDER, 0);
  if (cert.tag !== 0x30) throw new Error("cert: outer not SEQUENCE");

  // tbsCertificate — the bytes that were signed are the entire SEQUENCE including
  // its tag and length, hence subarray from `cert.valueStart` (which is where the
  // tbs SEQUENCE begins) to `tbsField.valueEnd`.
  const tbsField = readTLV(certDER, cert.valueStart);
  if (tbsField.tag !== 0x30) throw new Error("cert: tbs not SEQUENCE");
  const tbs = certDER.subarray(cert.valueStart, tbsField.valueEnd);

  // signatureAlgorithm
  const sigAlgField = readTLV(certDER, tbsField.valueEnd);
  if (sigAlgField.tag !== 0x30) throw new Error("cert: sigAlg not SEQUENCE");
  const sigAlgOidField = readTLV(certDER, sigAlgField.valueStart);
  if (sigAlgOidField.tag !== 0x06) throw new Error("cert: sigAlg OID missing");
  // Last byte of the sigAlg OID for ECDSA-with-SHA-X disambiguates the hash:
  //   1.2.840.10045.4.3.2 = ECDSA-SHA256 (final byte 0x02)
  //   1.2.840.10045.4.3.3 = ECDSA-SHA384 (final byte 0x03)
  const lastOidByte = certDER[sigAlgOidField.valueEnd - 1]!;
  const sigHashAlg: "SHA-256" | "SHA-384" =
    lastOidByte === 0x03 ? "SHA-384" : "SHA-256";

  // signatureValue (BIT STRING)
  const sigField = readTLV(certDER, sigAlgField.valueEnd);
  if (sigField.tag !== 0x03) throw new Error("cert: sig not BIT STRING");
  if (certDER[sigField.valueStart] !== 0x00) {
    throw new Error("cert: BIT STRING with unused bits");
  }
  const signature = certDER.subarray(sigField.valueStart + 1, sigField.valueEnd);

  // Inside TBSCertificate: walk fields counting position to find SubjectPublicKeyInfo.
  // Per RFC 5280: [0] version (optional), serialNumber, signature, issuer, validity,
  // subject, subjectPublicKeyInfo, ... — so SPKI is the 6th field after [0] is consumed.
  let p = tbsField.valueStart;
  const first = readTLV(certDER, p);
  if (first.tag === 0xa0) p = first.valueEnd; // skip [0] version if present
  // Skip serialNumber, signature alg, issuer, validity, subject — 5 fields.
  for (let k = 0; k < 5; k++) {
    const f = readTLV(certDER, p);
    p = f.valueEnd;
  }
  const spkiField = readTLV(certDER, p);
  if (spkiField.tag !== 0x30) throw new Error("cert: SPKI not SEQUENCE");
  const spki = certDER.subarray(p, spkiField.valueEnd);

  return { tbs, signature, spki, sigHashAlg };
}

// Identify the curve of an EC public key embedded in a SubjectPublicKeyInfo. The
// curve OID lives as the second field of the AlgorithmIdentifier inside SPKI:
//   P-256 = 1.2.840.10045.3.1.7 (DER tail byte 0x07)
//   P-384 = 1.3.132.0.34        (DER tail byte 0x22)
function spkiCurve(spki: Uint8Array): "P-256" | "P-384" {
  const seq = readTLV(spki, 0);
  const algSeq = readTLV(spki, seq.valueStart);
  const algOid = readTLV(spki, algSeq.valueStart);
  const curveOid = readTLV(spki, algOid.valueEnd);
  if (curveOid.tag !== 0x06) throw new Error("spki: curve OID missing");
  const tail = spki[curveOid.valueEnd - 1]!;
  if (tail === 0x07) return "P-256";
  if (tail === 0x22) return "P-384";
  throw new Error(`spki: unsupported curve oid (last byte 0x${tail.toString(16)})`);
}

// Verify `child` certificate's signature using `parentSpki` as the issuer's public key.
async function verifyCertSignedBy(
  child: Uint8Array,
  parentSpki: Uint8Array,
): Promise<boolean> {
  const { tbs, signature, sigHashAlg } = dissectCert(child);
  const curve = spkiCurve(parentSpki);
  const componentBytes = curve === "P-256" ? 32 : 48;
  const key = await crypto.subtle.importKey(
    "spki",
    parentSpki as BufferSource,
    { name: "ECDSA", namedCurve: curve },
    false,
    ["verify"],
  );
  const rawSig = derToRawECDSASig(signature, componentBytes);
  return crypto.subtle.verify(
    { name: "ECDSA", hash: sigHashAlg },
    key,
    rawSig as BufferSource,
    tbs as BufferSource,
  );
}

// === Public API ===

export type JWSResult =
  | { ok: true; payload: Record<string, unknown> }
  | { ok: false; error: string };

export async function verifyJWS(jws: string): Promise<JWSResult> {
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return { ok: false, error: "malformed_jws" };
    const [headerB64, payloadB64, sigB64] = parts as [string, string, string];

    const header = JSON.parse(
      new TextDecoder().decode(b64urlDecode(headerB64)),
    ) as { alg?: string; x5c?: string[] };
    if (header.alg !== "ES256") return { ok: false, error: "unsupported_alg" };
    const x5c = header.x5c;
    if (!Array.isArray(x5c) || x5c.length === 0) {
      return { ok: false, error: "missing_x5c" };
    }
    const chain = x5c.map((c) => b64decode(c));

    // Verify chain links: each cert is signed by the next.
    for (let i = 0; i < chain.length - 1; i++) {
      const issuerSpki = dissectCert(chain[i + 1]!).spki;
      const ok = await verifyCertSignedBy(chain[i]!, issuerSpki);
      if (!ok) return { ok: false, error: `chain_break_${i}` };
    }

    // Trust anchor: the last cert is either Apple Root CA G3 byte-for-byte, or it
    // is signed by Apple Root G3's public key (Apple sometimes truncates the chain
    // and omits the self-signed root since the recipient has it pinned).
    const lastCert = chain[chain.length - 1]!;
    if (!bytesEqual(lastCert, APPLE_ROOT_G3_DER)) {
      const rootSpki = dissectCert(APPLE_ROOT_G3_DER).spki;
      const ok = await verifyCertSignedBy(lastCert, rootSpki);
      if (!ok) return { ok: false, error: "untrusted_root" };
    }

    // Verify the JWS signature itself. JWS ES256 signatures are raw r||s (64 bytes),
    // not DER-wrapped — this is per RFC 7515 §4.1.1, distinct from the DER format
    // used inside the cert chain.
    const leafSpki = dissectCert(chain[0]!).spki;
    if (spkiCurve(leafSpki) !== "P-256") {
      return { ok: false, error: "leaf_not_p256" };
    }
    const key = await crypto.subtle.importKey(
      "spki",
      leafSpki as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const sig = b64urlDecode(sigB64);
    if (sig.length !== 64) return { ok: false, error: "bad_jws_sig_length" };
    const signedBytes = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      sig as BufferSource,
      signedBytes as BufferSource,
    );
    if (!valid) return { ok: false, error: "bad_signature" };

    const payload = JSON.parse(
      new TextDecoder().decode(b64urlDecode(payloadB64)),
    ) as Record<string, unknown>;
    return { ok: true, payload };
  } catch (e) {
    return { ok: false, error: `jws_failed: ${(e as Error).message}` };
  }
}

// === Typed payload helpers ===

export type AppleTransaction = {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  expiresDate: number | null;
  environment: "Sandbox" | "Production";
  bundleId: string;
};

export function decodeTransaction(payload: Record<string, unknown>): AppleTransaction {
  return {
    originalTransactionId: String(payload.originalTransactionId ?? ""),
    transactionId: String(payload.transactionId ?? ""),
    productId: String(payload.productId ?? ""),
    expiresDate: payload.expiresDate != null ? Number(payload.expiresDate) : null,
    environment: payload.environment === "Production" ? "Production" : "Sandbox",
    bundleId: String(payload.bundleId ?? ""),
  };
}

export type AppleNotification = {
  notificationType: string;
  subtype: string | null;
  signedTransactionInfo: string | null;
  signedRenewalInfo: string | null;
};

export function decodeNotification(
  payload: Record<string, unknown>,
): AppleNotification {
  const data = (payload.data ?? {}) as Record<string, unknown>;
  return {
    notificationType: String(payload.notificationType ?? ""),
    subtype: payload.subtype != null ? String(payload.subtype) : null,
    signedTransactionInfo:
      typeof data.signedTransactionInfo === "string"
        ? data.signedTransactionInfo
        : null,
    signedRenewalInfo:
      typeof data.signedRenewalInfo === "string" ? data.signedRenewalInfo : null,
  };
}
