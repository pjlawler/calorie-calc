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
      return JSON.parse(await res.text());
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
  const head = "  date         uniq.devices   ai.reqs   total.reqs";
  const rows = dates.map((d) => {
    const h = history.get(d) ?? {};
    const uniq = h.unique_active_devices ?? "·";
    const ai = h.ai_requests ?? "·";
    const tot = h.total_worker_requests || totals.get(d) || "·";
    return `  ${d}   ${String(uniq).padStart(10)}   ${String(ai).padStart(7)}   ${String(tot).padStart(9)}`;
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
  });
  saveHistory(history);

  const hourUTC = new Date().getUTCHours();
  const partial = hourUTC < 23 ? `  (partial — UTC day in progress, ${23 - hourUTC}h+ to go)` : "";

  console.log(`\n=== calorie_calc AI activity — ${today} UTC ===\n`);
  console.log(`AI calls today           : ${aiRequests}${partial}`);
  console.log(`Unique devices today     : ${uniqueDevices}`);
  console.log(
    `Avg calls / device       : ${uniqueDevices ? (aiRequests / uniqueDevices).toFixed(1) : "—"}`,
  );
  console.log(`Registered devices       : ${registered}  (${keyCount} device records)`);
  console.log(`Active subscribers       : ${subscribers}`);
  console.log(`\n--- Trend (last ${TREND_DAYS} days; "·" = not captured) ---`);
  console.log(fmtTable(history, totals));
  console.log(`\nHistory file: ${CSV_PATH}`);
  console.log(
    `Note: unique-device & ai-call columns exist only for days this ran; total.reqs backfills from analytics.\n`,
  );
}

main().catch((e) => {
  console.error("ai-activity failed:", e.message);
  process.exit(1);
});
