import { Hono } from "hono";
import { verifyAssertion, verifyAttestation } from "./attest";
import { verifySSV } from "./admobssv";
import {
  decodeNotification,
  decodeTransaction,
  verifyJWS,
  type AppleTransaction,
} from "./applestore";
import { b64decode, b64encode, concat } from "./crypto-utils";
import {
  consumeDailyRequest,
  grantInitialCreditsIfNeeded,
  hasEntitlement,
  isSubscriptionActive,
  parseDevice,
  serializeDevice,
  type StoredDevice,
} from "./entitlements";

type Env = {
  ANTHROPIC_API_KEY: string;
  APPLE_APP_ID: string;
  ALLOW_DEV_ATTESTATION: string;
  DAILY_REQUEST_LIMIT: string;
  CREDITS_PER_AD: string;
  INITIAL_FREE_CREDITS: string;
  SUBSCRIPTION_PRODUCT_ID: string;
  APPSTORE_BUNDLE_ID: string;
  APPSTORE_ENVIRONMENT: string;
  DEVICES: KVNamespace;
  CHALLENGES: KVNamespace;
  RATE_LIMITS: KVNamespace;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/", (c) => c.text("calorie-calc-proxy ok"));

// Returns the per-request initial-credit grant. Production builds get the env-var
// amount; debug iOS builds (signaled by the X-Debug-Build header) get exactly 1
// so the paywall flow can be retested quickly on a fresh device record. The
// header is purely a hint — App Attest still authenticates the device, and a
// debug build can only lower its OWN starting credits, not anyone else's.
function initialCreditsFor(env: Env, headers: Headers): number {
  if (headers.get("X-Debug-Build") === "1") return 1;
  return parseInt(env.INITIAL_FREE_CREDITS, 10) || 0;
}

// Step 1 of registration: server issues a fresh challenge that the client passes to
// `attestKey(_:clientDataHash:)`. Single-use, 5-minute TTL.
app.post("/v1/attest/challenge", async (c) => {
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const challengeB64 = b64encode(challenge);
  await c.env.CHALLENGES.put(`c:${challengeB64}`, "1", { expirationTtl: 300 });
  return c.json({ challenge: challengeB64 });
});

// Step 2 of registration: client posts the keyId and attestation blob. We verify the
// attestation, store the public key, and return the deviceId (which is the keyId).
app.post("/v1/attest/register", async (c) => {
  let body: { keyId?: string; attestation?: string; challenge?: string };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "bad_json" }, 400);
  }
  const { keyId, attestation, challenge } = body;
  if (!keyId || !attestation || !challenge) {
    return c.json({ error: "missing_fields" }, 400);
  }

  const issued = await c.env.CHALLENGES.get(`c:${challenge}`);
  if (!issued) return c.json({ error: "invalid_or_expired_challenge" }, 400);
  await c.env.CHALLENGES.delete(`c:${challenge}`);

  const result = await verifyAttestation({
    keyId,
    attestation,
    challenge,
    appId: c.env.APPLE_APP_ID,
    allowDev: c.env.ALLOW_DEV_ATTESTATION === "true",
  });
  if (!result.ok) return c.json({ error: result.error }, 400);

  // Refuse re-registration of a keyId we already know — prevents counter rollback.
  const existing = await c.env.DEVICES.get(`d:${keyId}`);
  if (existing) return c.json({ error: "already_registered" }, 409);

  const stored: StoredDevice = {
    spki: b64encode(result.publicKeySpki),
    counter: 0,
    registeredAt: Date.now(),
    credits: 0,
    subscriptionExpiresAt: null,
    originalTransactionId: null,
    grandfatheredAt: null,
    rateLimitDay: "",
    rateLimitCount: 0,
  };
  await c.env.DEVICES.put(`d:${keyId}`, serializeDevice(stored));
  return c.json({ deviceId: keyId });
});

// Read-only entitlement state. Authenticated by an App Attest assertion bound to
// `deviceId || "GET:/v1/account/state:" || X-Timestamp`. Timestamp must be within
// 60s of server time to defeat capture-and-replay. Also runs the grandfather grant,
// so opening the app on a TestFlight device that pre-dates this deploy is enough to
// hand them their initial credits without making an AI call first.
app.get("/v1/account/state", async (c) => {
  const deviceId = c.req.header("X-Device-Id");
  const assertion = c.req.header("X-Assertion");
  const timestamp = c.req.header("X-Timestamp");
  if (!deviceId || !assertion || !timestamp) {
    return c.json({ error: "auth_required" }, 401);
  }

  const ts = parseInt(timestamp, 10);
  if (!Number.isFinite(ts) || Math.abs(Date.now() - ts) > 60_000) {
    return c.json({ error: "timestamp_skew" }, 401);
  }

  const stored = await c.env.DEVICES.get(`d:${deviceId}`);
  if (!stored) return c.json({ error: "unknown_device" }, 401);
  const device = parseDevice(stored);

  // Reconstruct exactly the bytes the client hashed: keyId || "GET:..." || timestamp.
  const clientData = concat(
    b64decode(deviceId),
    new TextEncoder().encode(`GET:/v1/account/state:${timestamp}`),
  );

  const v = await verifyAssertion({
    publicKeySpki: b64decode(device.spki),
    storedCounter: device.counter,
    assertion,
    clientData,
    appId: c.env.APPLE_APP_ID,
  });
  if (!v.ok) return c.json({ error: v.error }, 401);

  device.counter = v.newCounter;
  const initial = initialCreditsFor(c.env, c.req.raw.headers);
  const installId = c.req.header("X-Install-Id");
  await grantInitialCreditsIfNeeded(c.env, device, deviceId, installId, initial);
  await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));

  return c.json({
    subscriptionActive: isSubscriptionActive(device, Date.now()),
    creditsRemaining: device.credits,
    subscriptionExpiresAt: device.subscriptionExpiresAt,
  });
});

// Client-initiated subscription verification. iOS sends the JWS representation of a
// StoreKit 2 transaction (returned by `Transaction.currentEntitlements` or right
// after a purchase). We verify the JWS signature + chain to Apple Root CA G3,
// confirm the bundle/product match, and update this device's entitlement record.
//
// Same auth as /v1/messages: an App Attest assertion bound to the request body.
app.post("/v1/subscriptions/verify", async (c) => {
  const deviceId = c.req.header("X-Device-Id");
  const assertion = c.req.header("X-Assertion");
  if (!deviceId || !assertion) return c.json({ error: "auth_required" }, 401);

  const stored = await c.env.DEVICES.get(`d:${deviceId}`);
  if (!stored) return c.json({ error: "unknown_device" }, 401);
  const device = parseDevice(stored);

  const rawBody = new Uint8Array(await c.req.raw.arrayBuffer());
  const v = await verifyAssertion({
    publicKeySpki: b64decode(device.spki),
    storedCounter: device.counter,
    assertion,
    clientData: concat(b64decode(deviceId), rawBody),
    appId: c.env.APPLE_APP_ID,
  });
  if (!v.ok) return c.json({ error: v.error }, 401);
  device.counter = v.newCounter;

  let body: { jwsRepresentation?: string };
  try {
    body = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({ error: "bad_json" }, 400);
  }
  if (!body.jwsRepresentation) {
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({ error: "missing_jws" }, 400);
  }

  const jws = await verifyJWS(body.jwsRepresentation);
  if (!jws.ok) {
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({ error: jws.error }, 400);
  }
  const tx = decodeTransaction(jws.payload);
  if (tx.bundleId !== c.env.APPSTORE_BUNDLE_ID) {
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({ error: "wrong_bundle" }, 400);
  }
  if (tx.productId !== c.env.SUBSCRIPTION_PRODUCT_ID) {
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({ error: "wrong_product" }, 400);
  }

  await applyTransactionToDevice(c.env, deviceId, device, tx);

  console.log("subscriptions/verify ok", deviceId, tx.originalTransactionId, tx.expiresDate);
  return c.json({
    subscriptionActive: isSubscriptionActive(device, Date.now()),
    creditsRemaining: device.credits,
    subscriptionExpiresAt: device.subscriptionExpiresAt,
  });
});

// Apple App Store Server Notifications V2. Apple POSTs us {"signedPayload": "<JWS>"};
// the JWS contains the notification metadata and a nested signedTransactionInfo we
// need to recover originalTransactionId + expiry. Auth is the JWS signature itself —
// no App Attest, since Apple doesn't have our keys.
app.post("/v1/subscriptions/notify", async (c) => {
  let body: { signedPayload?: string };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "bad_json" }, 400);
  }
  if (!body.signedPayload) return c.json({ error: "missing_payload" }, 400);

  const outer = await verifyJWS(body.signedPayload);
  if (!outer.ok) {
    console.log("notify outer JWS failed", outer.error);
    // Apple retries on non-2xx indefinitely. Return 200 so a malformed payload
    // doesn't pin Apple's retry queue forever; we've already logged it.
    return c.json({ error: outer.error }, 200);
  }
  const note = decodeNotification(outer.payload);
  if (!note.signedTransactionInfo) {
    console.log("notify missing signedTransactionInfo", note.notificationType);
    return c.json({ ok: true });
  }

  const inner = await verifyJWS(note.signedTransactionInfo);
  if (!inner.ok) {
    console.log("notify inner JWS failed", inner.error);
    return c.json({ error: inner.error }, 200);
  }
  const tx = decodeTransaction(inner.payload);
  if (tx.bundleId !== c.env.APPSTORE_BUNDLE_ID) {
    console.log("notify bundle mismatch", tx.bundleId);
    return c.json({ ok: true });
  }
  if (tx.productId !== c.env.SUBSCRIPTION_PRODUCT_ID) {
    return c.json({ ok: true });
  }

  // Look up which devices own this originalTransactionId (populated by /verify).
  const deviceListRaw = await c.env.DEVICES.get(`o:${tx.originalTransactionId}`);
  if (!deviceListRaw) {
    console.log("notify no devices for", tx.originalTransactionId);
    return c.json({ ok: true });
  }
  const deviceIds = JSON.parse(deviceListRaw) as string[];

  // Map notification type → effective expiry. EXPIRED/REFUND/REVOKE clear the sub
  // by setting expiry to a past time; renewals push it forward to tx.expiresDate.
  const clearTypes = new Set(["EXPIRED", "REVOKE", "REFUND", "GRACE_PERIOD_EXPIRED"]);
  const effectiveExpiry = clearTypes.has(note.notificationType)
    ? Date.now() - 1
    : tx.expiresDate;

  for (const deviceId of deviceIds) {
    const stored = await c.env.DEVICES.get(`d:${deviceId}`);
    if (!stored) continue;
    const device = parseDevice(stored);
    device.subscriptionExpiresAt = effectiveExpiry;
    device.originalTransactionId = tx.originalTransactionId;
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    console.log("notify applied", note.notificationType, deviceId, effectiveExpiry);
  }

  return c.json({ ok: true });
});

// AdMob Server-Side Verification callback. AdMob hits this URL with a GET when a
// user finishes a rewarded video. The signature on the query string proves the
// callback came from Google. We grant `CREDITS_PER_AD` credits to the device id
// we set on the ad request via `setUserId`.
app.get("/v1/credits/grant", async (c) => {
  // Verify against the RAW query string exactly as AdMob put it on the wire. AdMob
  // signs those literal bytes (everything before `&signature=`), so we must not
  // round-trip through `new URL(...).search` — the WHATWG URL parser can re-normalize
  // the percent-encoding of values like the base64 `user_id` (`%3D`/`%2B`/`%2F`),
  // which changes the bytes and makes every real reward fail `bad_signature`. The
  // field-less save-time health ping has no percent-encoding, so it verifies either
  // way — which is exactly why this only bit real rewards.
  const rawUrl = c.req.url;
  const qIdx = rawUrl.indexOf("?");
  const rawQuery = qIdx >= 0 ? rawUrl.slice(qIdx + 1) : "";

  // AdMob's UI runs a reachability check on the SSV URL when you save it — a GET
  // with no query string. Treat that as a health check and 200, otherwise the
  // setup form flags the URL as broken and refuses to save it.
  if (!rawQuery) {
    return c.json({ ok: true });
  }

  const ssv = await verifySSV(rawQuery);
  if (!ssv.ok) {
    // Per Google's SSV guidance, return 200 even on rejection — non-2xx puts the
    // callback into AdMob's retry queue, which serves no purpose for malformed
    // signatures. We log internally so the rejection is still observable.
    console.log("ssv rejected", ssv.error);
    return c.json({ ok: false, reason: ssv.error });
  }

  const txId = ssv.params.get("transaction_id");
  const deviceId = ssv.params.get("user_id");
  if (!txId || !deviceId) {
    console.log("ssv missing_fields", { txId, deviceId });
    return c.json({ ok: false, reason: "missing_fields" });
  }

  // Idempotency: AdMob retries SSV callbacks on transient errors. A 30-day TTL is
  // well past their retry window and well under our KV storage budget.
  const seen = await c.env.RATE_LIMITS.get(`g:${txId}`);
  if (seen) {
    return c.json({ ok: true, alreadyGranted: true });
  }
  await c.env.RATE_LIMITS.put(`g:${txId}`, "1", { expirationTtl: 60 * 60 * 24 * 30 });

  const stored = await c.env.DEVICES.get(`d:${deviceId}`);
  if (!stored) {
    // Same retry-suppression rationale as the SSV-rejection branch above: an
    // unknown device id can't be fixed by retrying, so return 200 + log.
    console.log("ssv unknown device", deviceId);
    return c.json({ ok: false, reason: "unknown_device" });
  }
  const device = parseDevice(stored);
  const amount = parseInt(c.env.CREDITS_PER_AD, 10) || 5;
  const before = device.credits;
  device.credits += amount;
  await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));

  console.log("ssv granted", deviceId, txId, before, "->", device.credits);
  return c.json({ ok: true });
});

// Persists `tx` against `device` and updates the originalTransactionId → [deviceId]
// reverse-lookup KV entry used by /v1/subscriptions/notify. Mutates `device` and
// writes its KV record. Idempotent — calling multiple times for the same tx is a
// no-op beyond touching `subscriptionExpiresAt`.
async function applyTransactionToDevice(
  env: Env,
  deviceId: string,
  device: StoredDevice,
  tx: AppleTransaction,
): Promise<void> {
  device.subscriptionExpiresAt = tx.expiresDate;
  device.originalTransactionId = tx.originalTransactionId;
  await env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));

  // Append this deviceId to o:<originalTransactionId> if it isn't there already.
  // Multiple devices on the same Apple ID share one originalTransactionId, so
  // notifications can fan out to all of them.
  const existing = await env.DEVICES.get(`o:${tx.originalTransactionId}`);
  const list = existing ? (JSON.parse(existing) as string[]) : [];
  if (!list.includes(deviceId)) {
    list.push(deviceId);
    await env.DEVICES.put(
      `o:${tx.originalTransactionId}`,
      JSON.stringify(list),
    );
  }
}

// Authenticated proxy. Body is a verbatim Anthropic /v1/messages payload — the worker
// adds auth and rate-limits, but doesn't inspect or reshape the JSON.
app.post("/v1/messages", async (c) => {
  const deviceId = c.req.header("X-Device-Id");
  const assertion = c.req.header("X-Assertion");
  if (!deviceId || !assertion) return c.json({ error: "auth_required" }, 401);

  const stored = await c.env.DEVICES.get(`d:${deviceId}`);
  if (!stored) return c.json({ error: "unknown_device" }, 401);
  const device = parseDevice(stored);

  const rawBody = new Uint8Array(await c.req.raw.arrayBuffer());

  // The client signed SHA-256(deviceId || rawBody). Tying the assertion to the body
  // means a captured assertion can't be replayed for a different prompt.
  const clientData = concat(b64decode(deviceId), rawBody);

  const v = await verifyAssertion({
    publicKeySpki: b64decode(device.spki),
    storedCounter: device.counter,
    assertion,
    clientData,
    appId: c.env.APPLE_APP_ID,
  });
  if (!v.ok) return c.json({ error: v.error }, 401);

  // Grant initial credits before checking entitlement so a brand-new device — or a
  // pre-existing TestFlight device upgrading into this build — never sees a 402 on
  // their very first AI call. Idempotent (no-op once `grandfatheredAt` is set).
  // Install id (iCloud-synced) prevents the same Apple ID from re-rolling the grant
  // by uninstalling and reinstalling — see grantInitialCreditsIfNeeded for the gating.
  const initial = initialCreditsFor(c.env, c.req.raw.headers);
  const installId = c.req.header("X-Install-Id");
  if (await grantInitialCreditsIfNeeded(c.env, device, deviceId, installId, initial)) {
    console.log("messages grandfather", deviceId, "install", installId ?? "(none)", "+", initial, "->", device.credits);
  }

  const now = Date.now();
  const ent = hasEntitlement(device, now);
  if (!ent.ok) {
    // Persist the counter and any grandfather grant before bailing — otherwise a
    // valid assertion gets "wasted" without storing the new counter, breaking the
    // next request (which would fail counter-replay verification).
    device.counter = v.newCounter;
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({
      error: "no_credits",
      creditsRemaining: 0,
      subscriptionActive: false,
    }, 402);
  }

  // Abuse ceiling, not the paywall. Subscribers and credit users alike are bounded
  // here so a compromised key can't run our Anthropic bill into the ground. The count
  // lives on the device record (persisted below), so this adds no extra KV write.
  const limit = parseInt(c.env.DAILY_REQUEST_LIMIT, 10) || 50;
  if (!consumeDailyRequest(device, limit, now)) {
    device.counter = v.newCounter;
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    return c.json({ error: "rate_limited" }, 429);
  }

  const upstream = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": c.env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: rawBody,
  });

  // Persist counter regardless of upstream outcome — the assertion was valid and
  // must not be replayable. Only debit credits when Anthropic actually served us a
  // 2xx, so an upstream 5xx doesn't cost the user a search.
  device.counter = v.newCounter;
  const before = device.credits;
  if (upstream.status >= 200 && upstream.status < 300 && ent.reason === "credits") {
    device.credits -= 1;
  }
  await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
  console.log(
    "messages",
    deviceId,
    "status", upstream.status,
    "ent", ent.reason,
    "credits", before, "->", device.credits,
  );

  if (upstream.status >= 400) {
    const text = await upstream.text();
    console.log("anthropic", upstream.status, text);
    return new Response(text, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  }

  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "content-type":
        upstream.headers.get("content-type") ?? "application/json",
    },
  });
});

export default app;
