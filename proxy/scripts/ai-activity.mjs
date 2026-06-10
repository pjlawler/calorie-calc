#!/usr/bin/env node
// AI activity report + historical recorder for the calorie_calc proxy.
//
// What it measures: for the CURRENT UTC day, how many AI calls (/v1/messages) were
// made and from how many UNIQUE devices — read straight from the per-device daily
// counters in the DEVICES KV namespace (rateLimitDay / rateLimitCount, which only the
// /v1/messages handler increments). It then UPSERTS today's snapshot into a CSV so a
// historical record accrues every time you run it.
//
// IMPORTANT — why a daily snapshot is required: the per-device counter resets at UTC
// midnight and only ever holds the device's most recent active day. There is no way to
// recover unique-device counts for a past day after the fact. So unique-device history
// only exists for days on which this script ran. Run it once per day (ideally late in
// the UTC day, or on a schedule) for a clean trend. The `total_worker_requests` column
// is backfilled from Cloudflare analytics, which DOES retain history, so that column
// self-heals for any day in the analytics window.
//
// Auth: reuses Wrangler's stored OAuth token. We shell out to `wrangler kv key list`
// first, which both paginates the full key set AND refreshes the token if expired;
// then we read the freshened token from Wrangler's config for the parallel value
// fetches and the analytics query. No separate API token to manage.
//
// Usage:  node proxy/scripts/ai-activity.mjs
// Output: prints a report to stdout and updates proxy/data/ai-activity-history.csv

import { execSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";

const ACCOUNT_ID = "e8dc1c255e3cebe5a01b3d4c8e72e1fd";
const DEVICES_NS = "5a6501f17e33481d92ae7a5a99edda58";
const SCRIPT_NAME = "calorie-calc-proxy";
const CONCURRENCY = 32;
const TREND_DAYS = 14;

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROXY_DIR = resolve(__dirname, "..");
const CSV_PATH = resolve(PROXY_DIR, "data/ai-activity-history.csv");
const WRANGLER_CFG = resolve(homedir(), "Library/Preferences/.wrangler/config/default.toml");

const todayUTC = () => new Date().toISOString().slice(0, 10);

function wranglerToken() {
  const cfg = readFileSync(WRANGLER_CFG, "utf8");
  const m = cfg.match(/oauth_token\s*=\s*"([^"]+)"/);
  if (!m) throw new Error("No oauth_token in Wrangler config — run `wrangler login`.");
  return m[1];
}

async function pool(items, n, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (i < items.length) {
        const idx = i++;
        out[idx] = await fn(items[idx], idx);
      }
    }),
  );
  return out;
}

async function fetchDeviceRecords(token) {
  // wrangler handles pagination + token refresh as a side effect.
  const raw = execSync(`npx wrangler kv key list --namespace-id ${DEVICES_NS}`, {
    cwd: PROXY_DIR,
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"],
  }).toString();
  const keys = JSON.parse(raw)
    .map((k) => k.name)
    .filter((name) => name.startsWith("d:"));

  const base = `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${DEVICES_NS}/values/`;
  const results = await pool(keys, CONCURRENCY, async (key) => {
    const res = await fetch(base + encodeURIComponent(key), {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    try {
      const rec = JSON.parse(await res.text());
      rec._key = key;
      return rec;
    } catch {
      return null;
    }
  });
  return { records: results.filter(Boolean), keyCount: keys.length };
}

async function dailyTotals(token) {
  // Total worker requests per day across all routes (analytics retains history).
  const end = new Date().toISOString().slice(0, 10);
  const start = new Date(Date.now() - TREND_DAYS * 86400_000).toISOString().slice(0, 10);
  const query = `query($acc:String!,$start:Date!,$end:Date!){viewer{accounts(filter:{accountTag:$acc}){workersInvocationsAdaptive(limit:1000,filter:{date_geq:$start,date_leq:$end,scriptName:"${SCRIPT_NAME}"}){sum{requests}dimensions{date}}}}}`;
  try {
    const res = await fetch("https://api.cloudflare.com/client/v4/graphql", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query, variables: { acc: ACCOUNT_ID, start, end } }),
    });
    const json = await res.json();
    const rows = json?.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? [];
    return new Map(rows.map((r) => [r.dimensions.date, r.sum.requests]));
  } catch {
    return new Map();
  }
}

const COLS = [
  "date",
  "unique_active_devices",
  "ai_requests",
  "registered_devices",
  "active_subscribers",
  "total_worker_requests",
  // Of today's unique active AI devices, how many registered on an earlier calendar day
  // (i.e. came back to use AI after the day they signed up). New = unique - returning, so
  // only the returning count is stored. Appended last so old rows just read "" for it.
  "returning_devices",
];

function loadHistory() {
  if (!existsSync(CSV_PATH)) return new Map();
  const lines = readFileSync(CSV_PATH, "utf8").trim().split("\n");
  const map = new Map();
  for (const line of lines.slice(1)) {
    if (!line.trim()) continue;
    const cells = line.split(",");
    const row = Object.fromEntries(COLS.map((c, i) => [c, cells[i] ?? ""]));
    map.set(row.date, row);
  }
  return map;
}

function saveHistory(map) {
  mkdirSync(dirname(CSV_PATH), { recursive: true });
  const dates = [...map.keys()].sort();
  const body = dates.map((d) => COLS.map((c) => map.get(d)[c] ?? "").join(",")).join("\n");
  writeFileSync(CSV_PATH, COLS.join(",") + "\n" + body + "\n");
}

function fmtTable(history, totals) {
  const dates = [...new Set([...history.keys(), ...totals.keys()])].sort().slice(-TREND_DAYS);
  const head = "  date         uniq.devices   returning   ai.reqs   total.reqs";
  const rows = dates.map((d) => {
    const h = history.get(d) ?? {};
    const uniq = h.unique_active_devices ?? "·";
    const ret = h.returning_devices || "·";
    const ai = h.ai_requests ?? "·";
    const tot = h.total_worker_requests || totals.get(d) || "·";
    return `  ${d}   ${String(uniq).padStart(10)}   ${String(ret).padStart(9)}   ${String(ai).padStart(7)}   ${String(tot).padStart(9)}`;
  });
  return [head, ...rows].join("\n");
}

async function main() {
  const token = wranglerToken();
  const [{ records, keyCount }, totals] = await Promise.all([
    fetchDeviceRecords(token),
    dailyTotals(token),
  ]);

  const today = todayUTC();
  const nowMs = Date.now();
  const activeToday = records.filter((d) => d.rateLimitDay === today && (d.rateLimitCount ?? 0) > 0);
  const aiRequests = activeToday.reduce((s, d) => s + (d.rateLimitCount ?? 0), 0);
  const uniqueDevices = activeToday.length;
  const registered = records.length;
  const subscribers = records.filter(
    (d) => d.subscriptionExpiresAt && d.subscriptionExpiresAt > nowMs,
  ).length;

  // Returning = active today AND first registered on an earlier calendar day. New = the rest.
  const regDay = (d) => (d.registeredAt ? new Date(d.registeredAt).toISOString().slice(0, 10) : "");
  const returningDevices = activeToday.filter((d) => regDay(d) && regDay(d) < today).length;
  const newDevices = uniqueDevices - returningDevices;

  // Retention snapshot (as-of-now) from the durable per-device fields. rateLimitDay is the
  // device's most recent AI-call day; counter is its lifetime authed-call count.
  const aiEver = records.filter((d) => d.rateLimitDay);
  const dayDiff = (d) => Math.floor((new Date(today) - new Date(d)) / 86400_000);
  const recency = (d) => dayDiff(d.rateLimitDay);
  const within = (n) => aiEver.filter((d) => recency(d) <= n).length;
  const counters = aiEver.map((d) => d.counter ?? 0).sort((a, b) => a - b);
  const pct = (p) => (counters.length ? counters[Math.floor((counters.length - 1) * p)] : 0);
  const oneAndDone = counters.filter((c) => c <= 2).length;

  // Upsert today's snapshot, backfill total_worker_requests for every analytics day.
  const history = loadHistory();
  for (const [d, reqs] of totals) {
    const row = history.get(d) ?? Object.fromEntries(COLS.map((c) => [c, ""]));
    row.date = d;
    row.total_worker_requests = String(reqs);
    history.set(d, row);
  }
  history.set(today, {
    date: today,
    unique_active_devices: String(uniqueDevices),
    ai_requests: String(aiRequests),
    registered_devices: String(registered),
    active_subscribers: String(subscribers),
    total_worker_requests: String(totals.get(today) ?? history.get(today)?.total_worker_requests ?? ""),
    returning_devices: String(returningDevices),
  });
  saveHistory(history);

  const hourUTC = new Date().getUTCHours();
  const partial = hourUTC < 23 ? `  (partial — UTC day in progress, ${23 - hourUTC}h+ to go)` : "";

  console.log(`\n=== calorie_calc AI activity — ${today} UTC ===\n`);
  console.log(`AI calls today           : ${aiRequests}${partial}`);
  console.log(`Unique devices today     : ${uniqueDevices}  (${newDevices} new / ${returningDevices} returning)`);
  console.log(
    `Avg calls / device       : ${uniqueDevices ? (aiRequests / uniqueDevices).toFixed(1) : "—"}`,
  );
  console.log(`Registered devices       : ${registered}  (${keyCount} device records)`);
  console.log(`Active subscribers       : ${subscribers}`);

  const share = (n) => (aiEver.length ? ((100 * n) / aiEver.length).toFixed(1) : "—");
  console.log(`\n--- Retention (live snapshot of all devices that ever used AI) ---`);
  console.log(`Devices that ever used AI : ${aiEver.length}`);
  console.log(`Last used AI today        : ${within(0)}  (${share(within(0))}%)`);
  console.log(`Last used AI ≤7 days ago  : ${within(7)}  (${share(within(7))}%)`);
  console.log(`Last used AI ≤30 days ago : ${within(30)}  (${share(within(30))}%)`);
  console.log(`Dormant 30+ days          : ${aiEver.length - within(30)}  (${share(aiEver.length - within(30))}%)`);
  console.log(`Lifetime calls / device   : median ${pct(0.5)}  p90 ${pct(0.9)}  max ${counters[counters.length - 1] ?? 0}`);
  console.log(`One-and-done (≤2 calls)   : ${oneAndDone}  (${share(oneAndDone)}%)`);
  console.log(`  Caveats: install base is young, so low "dormant" is expected — repeat usage`);
  console.log(`  over a 30/60-day window is the real test. "Lifetime calls" counts all authed`);
  console.log(`  calls (registration, credit grants, AI), so it slightly overstates AI depth.`);

  // Heavy hitters: top devices by lifetime authed calls, so day-over-day runs show
  // whether the same devices keep coming back. Key is truncated — enough to recognize
  // a device across runs without printing the full identity.
  const top = [...aiEver].sort((a, b) => (b.counter ?? 0) - (a.counter ?? 0)).slice(0, 5);
  console.log(`\n--- Top devices by lifetime calls (watchlist) ---`);
  console.log(`  device           lifetime   last.ai.day   today   registered   region`);
  for (const d of top) {
    const id = (d._key ?? "").replace(/^d:/, "").slice(0, 12);
    const todayCalls = d.rateLimitDay === today ? (d.rateLimitCount ?? 0) : 0;
    console.log(
      `  ${id.padEnd(14)}   ${String(d.counter ?? 0).padStart(8)}   ${d.rateLimitDay ?? "—"}    ${String(todayCalls).padStart(5)}   ${regDay(d) || "—"}   ${d.lastCountry ?? "—"}`,
    );
  }

  console.log(`\n--- Trend (last ${TREND_DAYS} days; "·" = not captured) ---`);
  console.log(fmtTable(history, totals));
  console.log(`\nHistory file: ${CSV_PATH}`);
  console.log(
    `Note: unique-device, returning & ai-call columns exist only for days this ran; total.reqs backfills from analytics.\n`,
  );
}

main().catch((e) => {
  console.error("ai-activity failed:", e.message);
  process.exit(1);
});
