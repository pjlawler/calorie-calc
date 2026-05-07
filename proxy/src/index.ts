import { Hono } from "hono";
import { verifyAssertion, verifyAttestation } from "./attest";
import { b64decode, b64encode, concat } from "./crypto-utils";
import { rateLimit } from "./ratelimit";

type Env = {
  ANTHROPIC_API_KEY: string;
  APPLE_APP_ID: string;
  ALLOW_DEV_ATTESTATION: string;
  DAILY_REQUEST_LIMIT: string;
  DEVICES: KVNamespace;
  CHALLENGES: KVNamespace;
  RATE_LIMITS: KVNamespace;
};

type StoredDevice = {
  spki: string;     // base64-encoded SubjectPublicKeyInfo
  counter: number;  // last assertion counter; new assertion must exceed
  registeredAt: number;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/", (c) => c.text("calorie-calc-proxy ok"));

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
  };
  await c.env.DEVICES.put(`d:${keyId}`, JSON.stringify(stored));
  return c.json({ deviceId: keyId });
});

// Authenticated proxy. Body is a verbatim Anthropic /v1/messages payload — the worker
// adds auth and rate-limits, but doesn't inspect or reshape the JSON.
app.post("/v1/messages", async (c) => {
  const deviceId = c.req.header("X-Device-Id");
  const assertion = c.req.header("X-Assertion");
  if (!deviceId || !assertion) return c.json({ error: "auth_required" }, 401);

  const stored = await c.env.DEVICES.get(`d:${deviceId}`);
  if (!stored) return c.json({ error: "unknown_device" }, 401);
  const device = JSON.parse(stored) as StoredDevice;

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

  const limit = parseInt(c.env.DAILY_REQUEST_LIMIT, 10) || 100;
  const allowed = await rateLimit(c.env.RATE_LIMITS, deviceId, limit);
  if (!allowed) return c.json({ error: "rate_limited" }, 429);

  // Persist new counter so a replayed (or older) assertion is rejected next time.
  device.counter = v.newCounter;
  await c.env.DEVICES.put(`d:${deviceId}`, JSON.stringify(device));

  const upstream = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": c.env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: rawBody,
  });

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
