// Entitlement bookkeeping for AI access — the "do they have credits or an active sub"
// layer that sits between assertion verification and the upstream Anthropic call.
//
// Two sources of access:
//   • Active subscription (`subscriptionExpiresAt > now`) — bypass credit accounting.
//   • Credit balance (`credits > 0`) — debited once per successful Anthropic 2xx.
//
// Both live on the same `StoredDevice` record in KV (originally just `{ spki, counter,
// registeredAt }`). Existing TestFlight devices predate these fields; `parseDevice`
// tolerates missing keys so we don't need a separate migration job. New users — and
// pre-existing devices on first read after this deploys — get `INITIAL_FREE_CREDITS`
// granted via `grantInitialCreditsIfNeeded` so nobody hits a 402 on launch.

export type StoredDevice = {
  spki: string;
  counter: number;
  registeredAt: number;
  credits: number;
  subscriptionExpiresAt: number | null;
  originalTransactionId: string | null;
  grandfatheredAt: number | null;
  rateLimitDay: string;
  rateLimitCount: number;
  // Most recent iCloud install id seen on an authed call from this device. Lets the
  // rewarded-ad grant handler reverse-map a churned-away device id back to its install
  // and redirect the credit to the install's current device. Null on legacy records
  // and devices that have never sent X-Install-Id.
  installId: string | null;
};

export function parseDevice(raw: string): StoredDevice {
  const obj = JSON.parse(raw) as Partial<StoredDevice>;
  return {
    spki: obj.spki ?? "",
    counter: obj.counter ?? 0,
    registeredAt: obj.registeredAt ?? 0,
    credits: obj.credits ?? 0,
    subscriptionExpiresAt: obj.subscriptionExpiresAt ?? null,
    originalTransactionId: obj.originalTransactionId ?? null,
    grandfatheredAt: obj.grandfatheredAt ?? null,
    rateLimitDay: obj.rateLimitDay ?? "",
    rateLimitCount: obj.rateLimitCount ?? 0,
    installId: obj.installId ?? null,
  };
}

// Per-device daily request ceiling, stored on the device record itself so it costs
// no extra KV op — the record is already read and written on every /v1/messages.
// Resets when the UTC day rolls over. Mutates `d`; returns false when the limit is
// already reached (caller still persists `d` to save the verified Attest counter).
// Like the old KV counter, this is keyed by the App Attest device, so it resets on
// reinstall — intentionally, since it's a per-device abuse ceiling, not the paywall.
export function consumeDailyRequest(d: StoredDevice, dailyLimit: number, now: number): boolean {
  const day = new Date(now).toISOString().slice(0, 10);
  if (d.rateLimitDay !== day) {
    d.rateLimitDay = day;
    d.rateLimitCount = 0;
  }
  if (d.rateLimitCount >= dailyLimit) return false;
  d.rateLimitCount += 1;
  return true;
}

export function serializeDevice(d: StoredDevice): string {
  return JSON.stringify(d);
}

export function isSubscriptionActive(d: StoredDevice, now: number): boolean {
  return d.subscriptionExpiresAt != null && d.subscriptionExpiresAt > now;
}

export type EntitlementCheck =
  | { ok: true; reason: "subscribed" | "credits" | "promo" }
  | { ok: false; reason: "no_credits" };

// `promoFreeAI` is the temporary "free AI for everyone" switch (PROMO_FREE_AI env
// var), used to bridge the gap until the subscription + rewarded-ad flows are live in
// the App Store. When on, a device with no sub and no credits is still entitled — but
// crucially the promo check is placed BEFORE the credit check, so users with real
// credits are reported as "promo" too and never get debited (the caller only spends a
// credit when reason === "credits"). Flip the env var off and every balance is exactly
// where it was before the promo.
export function hasEntitlement(d: StoredDevice, now: number, promoFreeAI = false): EntitlementCheck {
  if (isSubscriptionActive(d, now)) return { ok: true, reason: "subscribed" };
  if (promoFreeAI) return { ok: true, reason: "promo" };
  if (d.credits > 0) return { ok: true, reason: "credits" };
  return { ok: false, reason: "no_credits" };
}

// One-time grant for any device that hasn't received the initial free-credit allotment.
// Fires on first /v1/messages or /v1/account/state call after deploy. Mutates `d` in
// place; returns true if a grant was applied (caller must persist).
//
// `installId` is an iCloud-synced identifier from the iOS app (X-Install-Id header) —
// stable across uninstall/reinstall on the same Apple ID, unlike the App Attest keyId
// which resets. When supplied, we consult a per-install KV marker so a reinstall on
// the same Apple ID lands on the existing grant record rather than re-rolling free
// credits. Old clients (and clients with iCloud signed out) supply no install id;
// they fall through to the legacy per-device grandfathering, preserving the original
// behavior.
export async function grantInitialCreditsIfNeeded(
  env: { DEVICES: KVNamespace },
  d: StoredDevice,
  deviceId: string,
  installId: string | undefined,
  amount: number,
): Promise<boolean> {
  if (d.grandfatheredAt != null) return false;

  if (installId) {
    const marker = await env.DEVICES.get(`i:${installId}`);
    if (marker) {
      // This iCloud install already received its grant on a prior device record —
      // mark this new device as grandfathered (so we don't keep checking KV) and
      // skip the credit bump. The proxy logs make this case visible at the call site.
      d.grandfatheredAt = Date.now();
      return false;
    }
  }

  d.grandfatheredAt = Date.now();
  d.credits += amount;
  if (installId) {
    await env.DEVICES.put(
      `i:${installId}`,
      JSON.stringify({ grantedAt: Date.now(), firstDeviceId: deviceId, amount }),
    );
  }
  return true;
}
