# Calorie Calc — API Proxy

Cloudflare Worker that fronts the iOS app's calls to `api.anthropic.com`. The Anthropic API key lives only on the worker; the app authenticates each request with an Apple App Attest assertion.

## Why

Embedding the Anthropic key in an iOS binary leaks it to anyone with `strings` and an `.ipa`. This worker takes the key off-device and gates each call on a hardware-backed App Attest signature, then proxies the request to Anthropic verbatim.

## Endpoints

- `POST /v1/attest/challenge` — issues a one-shot 32-byte nonce (5-min TTL).
- `POST /v1/attest/register` — `{ keyId, attestation, challenge }`. Verifies the App Attest blob and stores the public key.
- `POST /v1/messages` — same body shape as `api.anthropic.com/v1/messages`. Headers: `X-Device-Id`, `X-Assertion`. Forwarded verbatim once the assertion verifies.

## First-time deploy

Prerequisites: a Cloudflare account, your Apple Team ID, the bundle id (`com.lawlerinnovationsinc.calorie-calc` — confirm in Xcode → Signing & Capabilities), and a freshly issued Anthropic API key (do not reuse the one that was previously embedded in the app).

```bash
cd proxy
npm install

# 1. Authenticate
npx wrangler login

# 2. Create the three KV namespaces
npx wrangler kv namespace create DEVICES
npx wrangler kv namespace create CHALLENGES
npx wrangler kv namespace create RATE_LIMITS
# Paste each printed `id` into the matching [[kv_namespaces]] entry in wrangler.toml.

# 3. Set APPLE_APP_ID in wrangler.toml under [vars]
#    Format: "<TEAM_ID>.<BUNDLE_ID>" — e.g. "ABCDE12345.com.lawlerinnovationsinc.calorie-calc"

# 4. Set the Anthropic key as a secret (never commit this)
npx wrangler secret put ANTHROPIC_API_KEY
# (paste the rotated key when prompted)

# 5. Deploy
npx wrangler deploy
```

`wrangler deploy` prints the public URL (something like `https://calorie-calc-proxy.YOUR-SUBDOMAIN.workers.dev`). Paste it into `Secrets.xcconfig` as `PROXY_BASE_URL`. Remember to escape the slashes (`https:\/\/...`).

## Tail logs while testing

```bash
npx wrangler tail
```

## Going to production

When you cut a build for the App Store:

1. In `wrangler.toml`, set `ALLOW_DEV_ATTESTATION = "false"` and redeploy. (Production builds get the `appattest` AAGUID; dev/TestFlight builds get `appattestdevelop`.)
2. In `CalorieCalc/CalorieCalc.entitlements`, change `com.apple.developer.devicecheck.appattest-environment` from `development` to `production`.
3. Build and submit.

## Key rotation

Rotating the Anthropic key takes seconds and requires no app update:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy
```

Then revoke the old key in the [Anthropic console](https://console.anthropic.com/).

## Rate limits

Per-device daily cap is `DAILY_REQUEST_LIMIT` in `wrangler.toml` (default 100). Counters live in the `RATE_LIMITS` KV with a 36-hour TTL so they self-clean.

## Caveats and known limits

- **No Apple Root CA chain validation on attestation.** The credential cert in the attestation is parsed for its embedded nonce and public key, but we don't verify it chains to Apple's App Attest Root CA. An attacker who can fabricate a working attestation could register a bogus device, but per-request assertions still require the matching private key — so the worst case is "attacker registers their own real device and gets rate-limited like any user." Adding chain validation is a worthwhile follow-up if abuse appears.
- **App Attest doesn't run in Simulator.** AI features only work on a physical device once the proxy is wired up. This is an Apple platform constraint, not a worker limitation.
- **KV is eventually consistent.** Rate limits can briefly drift across regions during a fast burst. This is a soft cap, not a hard one — fine for cost-bounding.
