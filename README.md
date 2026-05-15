# CalorieCalc

iOS calorie tracker built around **calorie banking** — averaging targets across a weekly cycle so disciplined days fund social days, without nagging or color-coded shame. See [`CalorieCalc/calorie_bank_app_prompt.md`](CalorieCalc/calorie_bank_app_prompt.md) for the original product brief.

## Features

- **Weekly calorie banking** — choose a banking split (e.g. 5 banking / 2 off), and disciplined days build budget for off days. Pure math, no auto-adjustments. Lives in `CalorieBankCalculator`.
- **Food logging**
  - USDA FoodData Central search (free API)
  - Open Food Facts fallback
  - Barcode scanning via AVFoundation + Vision
  - Photo-based food recognition (Claude vision)
  - Free-text "describe what I ate" nutrition estimation (Claude)
  - Local `CachedFood` store with favorites + tags so recently-used items are one tap away
- **Workouts** — manual entry and HealthKit ingestion (active-energy + workout sessions)
- **Supplements** — optional separate section in the daily log (toggle in Settings)
- **Weight + Progress**
  - Weight log with HealthKit handoff
  - Trend chart with Theil–Sen regression (outlier-resistant), clipped to the visible Y range
  - Lifetime delta vs. starting weight + per-week trend rate
- **History** — metric-by-metric (calories / macros / exercise / steps) with day / week / month / range totals
- **CloudKit sync** — SwiftData store mirrors to private CloudKit DB, so signing in on a second device pulls history automatically
- **CSV backup / restore** — full export of logs, weights, goals, and cached foods; round-trip import
- **Goal periods** — changing your daily targets or banking split records a new `GoalPeriod` so historical weeks keep using the goal that was in effect at the time
- **Subscriptions + AppAttest** — StoreKit 2 subscription gates the AI features, attested through a small Cloudflare Worker before reaching Anthropic's API (your API key never ships in the app)

## Stack

- **Xcode 26** / Swift 6, strict-concurrency MainActor default
- **SwiftUI + SwiftData** (iOS 26+; builds for macOS/visionOS but iOS-only feature gates apply)
- **CloudKit** (private DB, SwiftData-backed)
- **HealthKit** (active-energy reads + workouts + steps)
- **AVFoundation + Vision** (barcode scanning)
- **StoreKit 2** + AppAttest for paid AI features
- **Anthropic Claude** (food vision + describe-AI), proxied through a Cloudflare Worker (`proxy/`) so the API key stays server-side
- MVVM with `@Observable` view models, protocol-based services (`FoodDataSource`, `FoodRecognitionService`, etc.)

## Setup

### 1. Open the project

```sh
open CalorieCalc.xcodeproj
```

### 2. Secrets

Two values get injected into the app's Info.plist at build time via `Secrets.xcconfig` (gitignored). A template exists:

```sh
cp Secrets.xcconfig.example Secrets.xcconfig
```

Edit `Secrets.xcconfig`:

- `USDA_API_KEY` — get a free key at <https://fdc.nal.usda.gov/api-key-signup.html>. `DEMO_KEY` works for low-rate testing but is shared and gets throttled.
- `PROXY_BASE_URL` — only needed if you want Claude-backed AI features (food photo and "describe what I ate"). Deploy `proxy/` (Cloudflare Worker) and set this to its URL. Without it, the rest of the app still works — AI features just won't run.

In Xcode: select the **project** (not target) → **Info** tab → expand **Configurations** → set both Debug and Release to use `Secrets` as the base configuration file.

### 3. HealthKit capability

The entitlements file already declares HealthKit; you just need to enable the capability on your signing profile:

1. Select the **CalorieCalc** target → **Signing & Capabilities**
2. Verify **HealthKit** is present. If not, click **+ Capability** and add it.

If you're not signed in to a developer team, HealthKit calls fail at runtime but the rest of the app builds fine.

### 4. CloudKit (optional, for sync)

The entitlements declare a CloudKit container. You can run with the default schema on the first build — the SwiftData → CloudKit bridge pushes the schema for you. To sync between two devices, sign both into the same iCloud account.

### 5. Build & run

Pick an iOS 26 simulator or device. HealthKit's active-energy readings only work on real devices; simulators return zero.

## Running tests

```sh
xcodebuild test -project CalorieCalc.xcodeproj -scheme CalorieCalc \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Or `⌘U` in Xcode.

The headline test suite is `CalorieCalcTests/CalorieBankCalculatorTests.swift`, which covers the banking math end-to-end:

- Exact-plan week matching the worked example in the brief
- Overeat on a banking day → bank shrinks 1:1
- Undereat → bank grows 1:1
- Skipped / extra workouts shift the allowance
- Mid-week recalculation (some days actual, rest projected)
- 7/0 split (no off days)
- Zero workouts all week
- Negative-net day (burn > consume)
- Daily budget display values (banking day = gross goal; past off-day = nil; future off-day = per-off-day bank share)

## Project layout

```
CalorieCalc/
├── App/                         # @main + root + service environment
├── Models/                      # SwiftData @Model types + enums
├── Services/                    # Calculator, data sources, HealthKit,
│                                  recognition, subscriptions, attest, migration
├── Features/
│   ├── WeekCalendar/            # Calc tab: weekly grid + banking budget
│   ├── DayDetail/               # Meals / workouts / supplements for one day
│   ├── Dashboard/               # Progress tab: weight chart + history metrics
│   ├── Progress/                # Trend timeframe selector + chart helpers
│   ├── History/                 # Per-metric breakdowns (cal / macros / steps)
│   ├── FoodSearch/              # USDA + OFF search, portion picker, barcode
│   ├── FoodPhoto/               # Camera + Claude-vision photo flow
│   ├── Foods/                   # Cached-food management
│   ├── Tags/                    # Food tagging + management
│   ├── Workouts/                # Manual workout sheet
│   ├── Weight/                  # Weight log + chart
│   ├── Supplements/             # Optional supplement tracking
│   ├── Info/                    # Onboarding / explainer screens
│   ├── Settings/                # Goals, bank split, HealthKit, units
│   └── Paywall/                 # Subscription gates
├── Shared/Extensions/           # Date/week helpers, formatters
├── Assets.xcassets
├── Info.plist
└── CalorieCalc.entitlements
CalorieCalcTests/                # Swift Testing
CalorieCalcWidget/               # WidgetKit (assets only for now)
proxy/                           # Cloudflare Worker fronting Anthropic API
```

## The banking model (summary)

Four user parameters: **daily net goal**, **daily gross goal**, **daily workout goal**, **bank split** (e.g. 5/2).

```
weeklyNetTarget       = dailyNetGoal × 7
weeklyGrossAllowance  = weeklyNetTarget + Σ (actual or projected daily burn)
caloriesAlreadyEaten  = Σ consumed on past + today
committedForBanking   = future banking days × dailyGrossGoal
                      + (today, if banking) max(0, dailyGrossGoal − todayConsumed)
offDayBank            = weeklyGrossAllowance − alreadyEaten − committedForBanking
perOffDayBudget       = offDayBank / (future off-days incl. today if today is an off-day)
```

Everything re-derives from these inputs on every food log, workout log, or settings change — no auto-adjustments, no color-coded warnings.

The math lives in `Services/CalorieBankCalculator.swift` as a pure `nonisolated` enum — no SwiftUI / SwiftData / HealthKit imports. The test target `@testable import`s it.

Layout-time settings (which weekday anchors the week, which weekdays are banking days) follow the **current** `weekStart` setting so changing it re-anchors every historical week consistently. Per-period numeric goals are preserved.

## The proxy (`proxy/`)

A Cloudflare Worker that fronts Anthropic's Messages API. Why a proxy:

- Anthropic API key stays as a Worker secret (`wrangler secret put ANTHROPIC_API_KEY`) — never shipped in the iOS app
- AppAttest assertion is verified server-side before the request goes through, so a tampered client can't burn the key
- Rate-limited per attested device

See [`proxy/README.md`](proxy/README.md) for deployment steps. Without the proxy, AI food recognition is unavailable but the rest of the app works.

## Roadmap

- Recipe builder (saved compositions of cached foods)
- Notifications / reminders
- Mid-week banking-day swap (drag-to-rearrange the banking pattern in-week)
- Apple Watch surface
- Widget data (the target exists, content is stubbed)

## License

TBD — currently all-rights-reserved.
