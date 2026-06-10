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
  // Temporary "free AI for everyone" promo. "1"/"true" entitles every authenticated
  // device for /v1/messages regardless of credits or subscription, without draining
  // balances. Flip off (or remove) to restore normal credit/subscription gating.
  PROMO_FREE_AI?: string;
  DEVICES: KVNamespace;
  CHALLENGES: KVNamespace;
  RATE_LIMITS: KVNamespace;
  // Slack Incoming Webhook for the daily SSV monitor verdict. Set with
  // `wrangler secret put ALERT_WEBHOOK_URL`. Optional — the monitor no-ops (and
  // logs the verdict instead) when unset, so deploys don't require it.
  ALERT_WEBHOOK_URL?: string;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/", (c) => c.text("calorie-calc-proxy ok"));

// Returns the per-request initial-credit grant. Production App Store builds get the
// env-var amount. Two cases get exactly 1 credit so the paywall is reachable after a
// single AI call: debug iOS builds (X-Debug-Build header) for local retesting, and
// Sandbox installs (X-StoreKit-Env: Sandbox) — App Review + TestFlight. The Sandbox
// case is what lets the reviewer hit the paywall/IAP: App Review runs Release builds
// (so X-Debug-Build is absent) and, with the promo suppressed in Sandbox, would
// otherwise start with the full 50 credits and never reach the purchase. Both headers
// are hints — App Attest still authenticates the device, and a client can only lower
// its OWN starting credits, never anyone else's.
function initialCreditsFor(env: Env, headers: Headers): number {
  if (headers.get("X-Debug-Build") === "1") return 1;
  if (headers.get("X-StoreKit-Env") === "Sandbox") return 1;
  return parseInt(env.INITIAL_FREE_CREDITS, 10) || 0;
}

// Temporary promo switch — see PROMO_FREE_AI in wrangler.toml. When on, everyone gets
// AI access without spending credits, so users don't hit the paywall while the
// subscription + rewarded-ad updates are still pending App Store approval.
//
// The promo is limited to the **Production** StoreKit environment (real App Store
// downloads). App Review and TestFlight builds run in **Sandbox**, signaled by the
// `X-StoreKit-Env` header the app attaches; there the promo is suppressed so the
// reviewer falls through to the normal credit/paywall flow and can actually reach the
// in-app purchase (App Store guideline 2.1(b)). A missing header is treated as
// production, so old clients and any request that can't resolve its environment keep
// the promo — only an explicit non-Production value turns it off.
function promoFreeAI(env: Env, headers: Headers): boolean {
  if (env.PROMO_FREE_AI !== "1" && env.PROMO_FREE_AI !== "true") return false;
  const skEnv = headers.get("X-StoreKit-Env");
  return skEnv == null || skEnv === "Production";
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
    installId: null,
    lastCountry: null,
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
  await linkInstallToDevice(c.env, device, deviceId, installId);
  await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));

  // During the free-AI promo, surface a non-zero balance so the app's paywall poll
  // auto-dismisses and never treats the user as out of credits. The stored value is
  // untouched — this only affects what we report, not what's banked.
  return c.json({
    subscriptionActive: isSubscriptionActive(device, Date.now()),
    creditsRemaining: promoFreeAI(c.env, c.req.raw.headers) ? Math.max(device.credits, 1) : device.credits,
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
  // Environment gate: a Sandbox (TestFlight) receipt must not unlock a Production
  // entitlement. Apple signs both Sandbox and Production JWS with a valid cert chain,
  // so the signature check above can't distinguish them — only the `environment`
  // claim can. Reject any mismatch with APPSTORE_ENVIRONMENT.
  if (tx.environment !== c.env.APPSTORE_ENVIRONMENT) {
    await c.env.DEVICES.put(`d:${deviceId}`, serializeDevice(device));
    console.log("subscriptions/verify wrong_environment", tx.environment, "expected", c.env.APPSTORE_ENVIRONMENT);
    return c.json({ error: "wrong_environment" }, 400);
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
  // Same environment gate as /verify: ignore notifications from the wrong environment
  // so a Sandbox renewal/refund can't move a Production entitlement (and vice versa).
  // 200 + log, since a non-2xx just pins Apple's retry queue.
  if (tx.environment !== c.env.APPSTORE_ENVIRONMENT) {
    console.log("notify environment mismatch", tx.environment, "expected", c.env.APPSTORE_ENVIRONMENT);
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

// Diagnostics for the rewarded-ad grant pipeline. Rewarded-video volume is ~1/day,
// so a read-modify-write on a single KV record races essentially never — good enough
// to settle the question the Worker logs can't (they only retain a few days): of the
// SSV callbacks that arrive, how many actually land credits vs. drop as `unknown_device`
// because the App Attest identity churned out from under the reward. `recent` keeps the
// credited `deviceId` for each event so an `unknown_device` can be cross-referenced
// against the device table to confirm churn. Read it back with:
//   wrangler kv key get --binding RATE_LIMITS ssv:stats --remote
async function recordSSVOutcome(
  env: Env,
  outcome: string,
  detail?: { deviceId?: string | null; txId?: string | null },
): Promise<void> {
  try {
    const raw = await env.RATE_LIMITS.get("ssv:stats");
    const stats = raw
      ? (JSON.parse(raw) as { counts: Record<string, number>; recent: unknown[] })
      : { counts: {}, recent: [] };
    stats.counts[outcome] = (stats.counts[outcome] ?? 0) + 1;
    stats.recent.unshift({
      outcome,
      deviceId: detail?.deviceId ?? null,
      txId: detail?.txId ?? null,
      at: new Date().toISOString(),
    });
    // Keep a bounded ring so the record can't grow without limit.
    stats.recent = stats.recent.slice(0, 100);
    await env.RATE_LIMITS.put("ssv:stats", JSON.stringify(stats));
  } catch (e) {
    // Instrumentation must never affect the grant outcome — swallow and lean on the
    // existing console.log lines if this write fails.
    console.log("ssv stat write failed", String(e));
  }
}

// Ad-reward churn stopgap. Remembers the install's CURRENT device so a rewarded-ad
// grant tagged with an older (churned-away) device id can be redirected to the device
// the app is actually polling now. Mutates `device.installId` (persisted by the
// caller's existing device put) and writes the forward pointer cur:<installId> ->
// deviceId. The `installId === device.installId` guard keeps this to one extra KV write
// per (device, install) first-sight rather than on every authed call.
async function linkInstallToDevice(
  env: Env,
  device: StoredDevice,
  deviceId: string,
  installId: string | undefined,
): Promise<void> {
  if (!installId || device.installId === installId) return;
  device.installId = installId;
  await env.DEVICES.put(`cur:${installId}`, deviceId);
}

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
    await recordSSVOutcome(c.env, `rejected:${ssv.error}`);
    return c.json({ ok: false, reason: ssv.error });
  }

  const txId = ssv.params.get("transaction_id");
  const deviceId = ssv.params.get("user_id");
  if (!txId || !deviceId) {
    console.log("ssv missing_fields", { txId, deviceId });
    await recordSSVOutcome(c.env, "missing_fields", { deviceId, txId });
    return c.json({ ok: false, reason: "missing_fields" });
  }

  // Idempotency: AdMob retries SSV callbacks on transient errors. A 30-day TTL is
  // well past their retry window and well under our KV storage budget.
  const seen = await c.env.RATE_LIMITS.get(`g:${txId}`);
  if (seen) {
    return c.json({ ok: true, alreadyGranted: true });
  }
  await c.env.RATE_LIMITS.put(`g:${txId}`, "1", { expirationTtl: 60 * 60 * 24 * 30 });

  let stored = await c.env.DEVICES.get(`d:${deviceId}`);
  // Churn rescue: the reward must land on the device the app is polling NOW. If the
  // granted id has since churned to a new identity for the same install, follow its
  // installId -> cur:<installId> to the install's current device and credit that
  // instead. No-op when there's no churn (cur points back at deviceId) or no mapping.
  let targetId = deviceId;
  if (stored) {
    const grantedDev = parseDevice(stored);
    if (grantedDev.installId) {
      const current = await c.env.DEVICES.get(`cur:${grantedDev.installId}`);
      if (current && current !== deviceId) {
        const currentStored = await c.env.DEVICES.get(`d:${current}`);
        if (currentStored) {
          targetId = current;
          stored = currentStored;
        }
      }
    }
  }
  if (!stored) {
    // Same retry-suppression rationale as the SSV-rejection branch above: an
    // unknown device id can't be fixed by retrying, so return 200 + log.
    console.log("ssv unknown device", deviceId);
    await recordSSVOutcome(c.env, "unknown_device", { deviceId, txId });
    return c.json({ ok: false, reason: "unknown_device" });
  }
  const device = parseDevice(stored);
  const amount = parseInt(c.env.CREDITS_PER_AD, 10) || 5;
  const before = device.credits;
  device.credits += amount;
  await c.env.DEVICES.put(`d:${targetId}`, serializeDevice(device));

  if (targetId !== deviceId) {
    console.log("ssv granted (redirected churn)", deviceId, "->", targetId, txId, before, "->", device.credits);
  } else {
    console.log("ssv granted", targetId, txId, before, "->", device.credits);
  }
  await recordSSVOutcome(c.env, "granted", { deviceId: targetId, txId });
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
  await linkInstallToDevice(c.env, device, deviceId, installId);

  const now = Date.now();
  const ent = hasEntitlement(device, now, promoFreeAI(c.env, c.req.raw.headers));
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

  // Stamp the Cloudflare-observed country of this AI call onto the record (kept on
  // both persist paths below). Observability only — never used for gating.
  const country = (c.req.raw.cf?.country as string | undefined) ?? null;
  if (country) device.lastCountry = country;

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

// === Daily SSV reward monitor (Cron Trigger) ===
// Runs in the Worker itself, so it reads `ssv:stats` and the device table through the
// native KV bindings — no external auth/token. Posts a RED/YELLOW/GREEN verdict to Slack.

type SSVStats = {
  counts: Record<string, number>;
  recent: Array<{ outcome: string; deviceId: string | null; txId: string | null; at: string }>;
};

async function postSlack(env: Env, text: string): Promise<void> {
  if (!env.ALERT_WEBHOOK_URL) {
    console.log("ssv monitor (no webhook set):", text);
    return;
  }
  try {
    const r = await fetch(env.ALERT_WEBHOOK_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text }),
    });
    if (!r.ok) console.log("ssv monitor slack post non-2xx", r.status);
  } catch (e) {
    console.log("ssv monitor slack post failed", String(e));
  }
}

async function runSSVMonitor(env: Env): Promise<void> {
  const raw = await env.RATE_LIMITS.get("ssv:stats");
  if (!raw) {
    await postSlack(env, "⏳ SSV reward monitor: no rewarded-ad callbacks recorded yet.");
    return;
  }
  const stats = JSON.parse(raw) as SSVStats;
  const now = Date.now();
  const DAY = 24 * 60 * 60 * 1000;

  // Tally outcomes seen within a time window from the `recent` ring (capped at 100;
  // at ~1 ad/day that's many weeks of history, plenty for 24h/7d windows).
  const tally = (cutoff: number) => {
    const w = { granted: 0, unknown_device: 0, rejected: 0, missing_fields: 0 };
    for (const e of stats.recent) {
      const t = Date.parse(e.at);
      if (Number.isNaN(t) || t < cutoff) continue;
      if (e.outcome === "granted") w.granted++;
      else if (e.outcome === "unknown_device") w.unknown_device++;
      else if (e.outcome === "missing_fields") w.missing_fields++;
      else if (e.outcome.startsWith("rejected")) w.rejected++;
    }
    return w;
  };
  const d1 = tally(now - DAY);
  const d7 = tally(now - 7 * DAY);

  // Churn confirmation: an unknown_device id that EXISTS in the device table now means
  // the identity did register — just after the reward fired against an id it had
  // already abandoned. That's the churn smoking gun.
  const unknownRecent = stats.recent.filter(
    (e) => e.outcome === "unknown_device" && e.deviceId && Date.parse(e.at) >= now - 7 * DAY,
  );
  let churnConfirmed = 0;
  for (const e of unknownRecent) {
    if (await env.DEVICES.get(`d:${e.deviceId}`)) churnConfirmed++;
  }

  const denom = d1.granted + d1.unknown_device;
  const unknownShare = denom > 0 ? d1.unknown_device / denom : 0;
  let emoji = "🟢";
  let level = "GREEN";
  if (denom > 0 && (d1.unknown_device >= d1.granted || unknownShare > 0.2)) {
    emoji = "🔴";
    level = "RED";
  } else if (d1.rejected > 0) {
    emoji = "🟡";
    level = "YELLOW";
  }

  const cumulative =
    Object.entries(stats.counts)
      .map(([k, v]) => `${k}=${v}`)
      .join(", ") || "none";
  const lines = [
    `${emoji} *SSV reward monitor — ${level}*`,
    `Last 24h: ${d1.granted} granted, ${d1.unknown_device} unknown_device` +
      (d1.rejected ? `, ${d1.rejected} rejected` : "") +
      (d1.missing_fields ? `, ${d1.missing_fields} missing_fields` : ""),
    `Last 7d: ${d7.granted} granted, ${d7.unknown_device} unknown_device`,
    unknownRecent.length
      ? `Churn check: ${churnConfirmed}/${unknownRecent.length} stranded ids are registered now → churn ${churnConfirmed ? "confirmed" : "unconfirmed"}.`
      : "Churn check: no unknown_device events in the last 7d.",
    `Cumulative: ${cumulative}`,
  ];
  await postSlack(env, lines.join("\n"));
}

export default {
  fetch: (req: Request, env: Env, ctx: ExecutionContext) => app.fetch(req, env, ctx),
  scheduled: (_event: ScheduledEvent, env: Env, ctx: ExecutionContext) => {
    ctx.waitUntil(runSSVMonitor(env));
  },
};
