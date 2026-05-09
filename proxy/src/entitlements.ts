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
  };
}

export function serializeDevice(d: StoredDevice): string {
  return JSON.stringify(d);
}

export function isSubscriptionActive(d: StoredDevice, now: number): boolean {
  return d.subscriptionExpiresAt != null && d.subscriptionExpiresAt > now;
}

export type EntitlementCheck =
  | { ok: true; reason: "subscribed" | "credits" }
  | { ok: false; reason: "no_credits" };

export function hasEntitlement(d: StoredDevice, now: number): EntitlementCheck {
  if (isSubscriptionActive(d, now)) return { ok: true, reason: "subscribed" };
  if (d.credits > 0) return { ok: true, reason: "credits" };
  return { ok: false, reason: "no_credits" };
}

// One-time grant for any device that hasn't received the initial free-credit allotment.
// Fires on first /v1/messages or /v1/account/state call after deploy. Mutates `d` in
// place; returns true if a grant was applied (caller must persist).
export function grantInitialCreditsIfNeeded(d: StoredDevice, amount: number): boolean {
  if (d.grandfatheredAt != null) return false;
  d.grandfatheredAt = Date.now();
  d.credits += amount;
  return true;
}
