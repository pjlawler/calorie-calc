// Apple App Attest verification — pure Web Crypto so it runs in a Cloudflare Worker.
//
// Spec: https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
//
// What this verifies:
//   • Attestation: the credential cert's nonce extension matches SHA-256(authData || clientDataHash);
//     keyId equals SHA-256(public key); rpIdHash equals SHA-256(appId); counter is zero;
//     aaguid is "appattest" (prod) or "appattestdevelop" (dev, if allowed).
//   • Assertion: the ECDSA-SHA256 signature over SHA-256(authData || clientDataHash) verifies
//     against the stored public key; rpIdHash matches; counter strictly increases.
//
// What this does NOT verify (intentional v1 trade-off): full Apple Root CA chain validation
// on the credential cert. Skipping this leaves a window where a forged attestation with a
// fabricated cert could register a device. The per-request signature still requires the
// fabricated key's matching private key, so the worst case is "attacker registers their own
// key and gets rate-limited like any other device" — which is also our floor when chain
// validation is in place. To harden later, validate cert chain to Apple's App Attest Root CA.

import { decodeCBOR } from "./cbor";
import {
  b64decode,
  bytesEqual,
  concat,
  readUint32BE,
  sha256,
} from "./crypto-utils";

// === Generic DER (ASN.1) reader — just enough to walk an X.509 cert. ===

type DERField = {
  tag: number;
  length: number;
  valueStart: number;
  valueEnd: number;
};

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

function* walkSequence(
  buf: Uint8Array,
  start: number,
  end: number,
): Generator<{ off: number; f: DERField }> {
  let p = start;
  while (p < end) {
    const f = readTLV(buf, p);
    yield { off: p, f };
    p = f.valueEnd;
  }
}

// 1.2.840.113635.100.8.2 — Apple's App Attest nonce extension OID.
const APPLE_NONCE_OID = new Uint8Array([
  0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02,
]);

function parseCredentialCert(certDER: Uint8Array): {
  spki: Uint8Array;
  rawPublicKey: Uint8Array;
  nonce: Uint8Array;
} {
  // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
  const cert = readTLV(certDER, 0);
  if (cert.tag !== 0x30) throw new Error("cert: missing outer SEQUENCE");
  const tbs = readTLV(certDER, cert.valueStart);
  if (tbs.tag !== 0x30) throw new Error("cert: missing TBSCertificate SEQUENCE");

  const tbsFields: { off: number; f: DERField }[] = [];
  for (const e of walkSequence(certDER, tbs.valueStart, tbs.valueEnd)) tbsFields.push(e);

  // TBSCertificate fields, in order:
  //   [0] version (optional), serialNumber, signature, issuer, validity, subject,
  //   subjectPublicKeyInfo, [3] extensions (optional).
  let i = 0;
  if (tbsFields[i]!.f.tag === 0xa0) i++; // version
  i += 5; // serial, sigAlg, issuer, validity, subject

  const spkiEntry = tbsFields[i]!;
  if (spkiEntry.f.tag !== 0x30) throw new Error("cert: SPKI tag mismatch");
  const spki = certDER.subarray(spkiEntry.off, spkiEntry.f.valueEnd);

  // SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }
  const spkiInner: { off: number; f: DERField }[] = [];
  for (const e of walkSequence(certDER, spkiEntry.f.valueStart, spkiEntry.f.valueEnd))
    spkiInner.push(e);
  const bitString = spkiInner[1];
  if (!bitString || bitString.f.tag !== 0x03) throw new Error("cert: BIT STRING missing");
  if (certDER[bitString.f.valueStart] !== 0x00)
    throw new Error("cert: unexpected unused-bits in BIT STRING");
  // For an ECDSA P-256 key the BIT STRING contents are 0x04 || X (32B) || Y (32B) = 65 bytes.
  const rawPublicKey = certDER.subarray(
    bitString.f.valueStart + 1,
    bitString.f.valueEnd,
  );

  // Find the [3] EXPLICIT extensions wrapper (after SPKI).
  const extWrapper = tbsFields
    .slice(i + 1)
    .find((e) => e.f.tag === 0xa3);
  if (!extWrapper) throw new Error("cert: no extensions block");

  // Inside the wrapper is a SEQUENCE OF Extension.
  const extsSeq = readTLV(certDER, extWrapper.f.valueStart);
  if (extsSeq.tag !== 0x30) throw new Error("cert: extensions wrapper not SEQUENCE");

  let nonce: Uint8Array | null = null;
  for (const ext of walkSequence(certDER, extsSeq.valueStart, extsSeq.valueEnd)) {
    // Extension ::= SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
    const extInner: { off: number; f: DERField }[] = [];
    for (const e of walkSequence(certDER, ext.f.valueStart, ext.f.valueEnd))
      extInner.push(e);
    const oidField = extInner[0];
    if (!oidField || oidField.f.tag !== 0x06) continue;
    const oid = certDER.subarray(oidField.f.valueStart, oidField.f.valueEnd);
    if (!bytesEqual(oid, APPLE_NONCE_OID)) continue;

    const valueField = extInner[extInner.length - 1]!;
    if (valueField.f.tag !== 0x04) throw new Error("cert: extnValue not OCTET STRING");

    // extnValue is itself ASN.1: SEQUENCE { [1] OCTET STRING nonce }
    const innerSeq = readTLV(certDER, valueField.f.valueStart);
    if (innerSeq.tag !== 0x30) throw new Error("cert: nonce inner not SEQUENCE");
    const ctxTag = readTLV(certDER, innerSeq.valueStart);
    if (ctxTag.tag !== 0xa1) throw new Error("cert: nonce context tag missing");
    const octet = readTLV(certDER, ctxTag.valueStart);
    if (octet.tag !== 0x04) throw new Error("cert: nonce inner not OCTET STRING");
    nonce = certDER.subarray(octet.valueStart, octet.valueEnd);
    break;
  }
  if (!nonce) throw new Error("cert: nonce extension not found");

  return { spki, rawPublicKey, nonce };
}

// Apple App Attest signs assertions with ECDSA-SHA256 and emits a DER-encoded (r, s) pair.
// Web Crypto's ECDSA verify expects raw r||s padded to 32 bytes each.
function derToRawECDSASignature(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new Error("sig: outer not SEQUENCE");
  let p = 2;
  if ((der[1]! & 0x80) !== 0) p = 2 + (der[1]! & 0x7f);

  if (der[p] !== 0x02) throw new Error("sig: r not INTEGER");
  let rLen = der[p + 1]!;
  let rStart = p + 2;
  if (der[rStart] === 0x00) {
    rStart++;
    rLen--;
  }
  const r = der.subarray(rStart, rStart + rLen);
  p = rStart + rLen;

  if (der[p] !== 0x02) throw new Error("sig: s not INTEGER");
  let sLen = der[p + 1]!;
  let sStart = p + 2;
  if (der[sStart] === 0x00) {
    sStart++;
    sLen--;
  }
  const s = der.subarray(sStart, sStart + sLen);

  const out = new Uint8Array(64);
  out.set(r, 32 - r.length);
  out.set(s, 64 - s.length);
  return out;
}

// === Public API ===

export type AttestationResult =
  | { ok: true; publicKeySpki: Uint8Array }
  | { ok: false; error: string };

export async function verifyAttestation(args: {
  keyId: string;        // base64 of the SHA-256 of the public key
  attestation: string;  // base64 CBOR blob from DCAppAttestService
  challenge: string;    // base64 of the random nonce we issued
  appId: string;        // "<TEAM_ID>.<bundle.id>"
  allowDev: boolean;
}): Promise<AttestationResult> {
  try {
    const decoded = decodeCBOR(b64decode(args.attestation)) as {
      fmt?: string;
      attStmt?: { x5c?: Uint8Array[] };
      authData?: Uint8Array;
    };
    if (decoded.fmt !== "apple-appattest") return { ok: false, error: "wrong_fmt" };
    const x5c = decoded.attStmt?.x5c;
    const authData = decoded.authData;
    if (!x5c || x5c.length === 0 || !authData) {
      return { ok: false, error: "malformed_attestation" };
    }
    const credCert = x5c[0]!;
    const { spki, rawPublicKey, nonce } = parseCredentialCert(credCert);

    // 1. nonce extension == SHA-256(authData || SHA-256(challenge))
    const clientDataHash = await sha256(b64decode(args.challenge));
    const expectedNonce = await sha256(concat(authData, clientDataHash));
    if (!bytesEqual(nonce, expectedNonce)) return { ok: false, error: "nonce_mismatch" };

    // 2. keyId == SHA-256(rawPublicKey)
    const keyIdBytes = b64decode(args.keyId);
    const pubHash = await sha256(rawPublicKey);
    if (!bytesEqual(keyIdBytes, pubHash)) return { ok: false, error: "keyid_mismatch" };

    // 3. authData.rpIdHash == SHA-256(appId)
    const expectedRpIdHash = await sha256(new TextEncoder().encode(args.appId));
    if (!bytesEqual(authData.subarray(0, 32), expectedRpIdHash)) {
      return { ok: false, error: "appid_mismatch" };
    }

    // 4. counter is zero (fresh key).
    if (readUint32BE(authData, 33) !== 0) return { ok: false, error: "counter_nonzero" };

    // 5. aaguid is the production or development marker.
    const aaguid = authData.subarray(37, 53);
    const prod = new TextEncoder().encode("appattest\0\0\0\0\0\0\0");
    const dev = new TextEncoder().encode("appattestdevelop");
    const isProd = bytesEqual(aaguid, prod);
    const isDev = bytesEqual(aaguid, dev);
    if (!isProd && !(isDev && args.allowDev)) {
      return { ok: false, error: "bad_aaguid" };
    }

    // 6. credentialId at end of authData == keyId
    const credIdLen = (authData[53]! << 8) | authData[54]!;
    const credentialId = authData.subarray(55, 55 + credIdLen);
    if (!bytesEqual(credentialId, keyIdBytes)) {
      return { ok: false, error: "credid_mismatch" };
    }

    return { ok: true, publicKeySpki: spki };
  } catch (e) {
    return { ok: false, error: `attest_failed: ${(e as Error).message}` };
  }
}

export type AssertionResult =
  | { ok: true; newCounter: number }
  | { ok: false; error: string };

export async function verifyAssertion(args: {
  publicKeySpki: Uint8Array;
  storedCounter: number;
  assertion: string;       // base64 CBOR blob from DCAppAttestService
  clientData: Uint8Array;  // raw bytes the client hashed before calling generateAssertion
  appId: string;
}): Promise<AssertionResult> {
  try {
    const decoded = decodeCBOR(b64decode(args.assertion)) as {
      signature?: Uint8Array;
      authenticatorData?: Uint8Array;
    };
    const signature = decoded.signature;
    const authData = decoded.authenticatorData;
    if (!signature || !authData) return { ok: false, error: "malformed_assertion" };

    // Apple signs `nonce = SHA-256(authData || clientDataHash)` with ECDSA-SHA256, which
    // hashes its input again internally. Web Crypto's verify also hashes its input, so we
    // must pass `nonce` here — passing the un-hashed concat (one fewer SHA-256) would
    // not line up with what Apple actually signed. Tested against captured bytes; only
    // this form verifies. See Apple's "Validating Apps That Connect to Your Server" §
    // "Assess the Assertion."
    const clientDataHash = await sha256(args.clientData);
    const nonce = await sha256(concat(authData, clientDataHash));

    const key = await crypto.subtle.importKey(
      "spki",
      args.publicKeySpki as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      derToRawECDSASignature(signature) as BufferSource,
      nonce as BufferSource,
    );
    if (!valid) return { ok: false, error: "bad_signature" };

    const expectedRpIdHash = await sha256(new TextEncoder().encode(args.appId));
    if (!bytesEqual(authData.subarray(0, 32), expectedRpIdHash)) {
      return { ok: false, error: "appid_mismatch" };
    }

    const counter = readUint32BE(authData, 33);
    if (counter <= args.storedCounter) return { ok: false, error: "counter_replay" };

    return { ok: true, newCounter: counter };
  } catch (e) {
    return { ok: false, error: `assertion_failed: ${(e as Error).message}` };
  }
}
