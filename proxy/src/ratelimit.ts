// Per-device daily request counter in Workers KV. KV is eventually consistent across
// regions, so this is a soft cap — a fast attacker hammering from multiple regions can
// briefly exceed the limit. That's fine; the goal is bounding cost per device, not
// strict enforcement. Daily key resets naturally via TTL; UTC bucket is good enough.

export async function rateLimit(
  kv: KVNamespace,
  deviceId: string,
  dailyLimit: number,
): Promise<boolean> {
  const day = new Date().toISOString().slice(0, 10);
  const key = `r:${deviceId}:${day}`;
  const current = parseInt((await kv.get(key)) ?? "0", 10);
  if (current >= dailyLimit) return false;
  // 36h TTL ensures the key outlives any timezone-induced wraparound while still
  // freeing storage promptly.
  await kv.put(key, String(current + 1), { expirationTtl: 60 * 60 * 36 });
  return true;
}
