# CalorieCalc

An iOS 26 calorie tracker built around **calorie banking** — averaging targets across a weekly cycle so disciplined days fund social days, without the app nagging or color-coding. See [`CalorieCalc/calorie_bank_app_prompt.md`](CalorieCalc/calorie_bank_app_prompt.md) for the original product brief.

> Status: early scaffolding. iOS-only, will likely grow a backend + web surface later.

## Stack

- **Xcode 26.4** / Swift 6 / strict MainActor default
- **SwiftUI + SwiftData** (iOS 26+, macOS 26+ builds but HealthKit/camera are iOS-only gated)
- **HealthKit** (read active energy + workouts)
- **AVFoundation + Vision** for barcode scanning
- **USDA FoodData Central API** for food search
- MVVM with `@Observable` view models, protocol-based services (`FoodDataSource`)

## Setup

### 1. Open the project

```
open CalorieCalc.xcodeproj
```

### 2. USDA FoodData Central API key

1. Get a free key: <https://fdc.nal.usda.gov/api-key-signup.html>
2. Copy the example:
   ```
   cp Secrets.xcconfig.example Secrets.xcconfig
   ```
3. Put your key in `Secrets.xcconfig`:
   ```
   USDA_API_KEY = your_actual_key_here
   ```
4. In Xcode: select the **project** (not target) in the navigator → **Info** tab → under **Configurations**, expand **Debug** and **Release** and set both to use `Secrets` as the base configuration file. This wires `USDA_API_KEY` into the app's Info.plist at build time.

`Secrets.xcconfig` is gitignored; `Secrets.xcconfig.example` is committed.

### 3. HealthKit capability

The entitlements file already declares HealthKit, but you need to enable the capability once in Xcode so your signing profile picks it up:

1. Select the **CalorieCalc** target → **Signing & Capabilities**
2. Verify **HealthKit** is present. If not, click **+ Capability** and add it.

If you're not signed in to a developer team, HealthKit features will fail at runtime but the app will still build.

### 4. Build & run

Pick an iOS 26 simulator or device and run. HealthKit requires a real device for active-energy data; simulators return zero.

## Running Tests

Swift Testing suite in `CalorieCalcTests/CalorieBankCalculatorTests.swift` covers the banking math end to end:

```
xcodebuild test -project CalorieCalc.xcodeproj -scheme CalorieCalc -destination 'platform=iOS Simulator,name=iPhone 17'
```

Or just `⌘U` in Xcode.

Cases covered:
- Exact-plan week (matches the worked example in the prompt: 11,200 / 14,700 / 5,700 / 2,850)
- Overeating on a banking day → bank shrinks 1:1
- Undereating → bank grows 1:1
- Skipping a workout → allowance and bank drop by the workout goal
- Extra workout → allowance and bank grow
- Mid-week recalculation (Wed today with Mon/Tue actuals, rest projected)
- 7/0 split (no off days)
- Zero workouts all week
- Negative-net day (burn > consume)
- Daily budget display values (banking day = gross goal; past off-day = nil; future off-day = per-off-day bank share)

## Project layout

```
CalorieCalc/
├── App/                       # @main + root + service env
├── Models/                    # SwiftData @Model types + Enums
├── Services/                  # FoodDataSource, USDA, HealthKit, Barcode, Calculator, WeekAssembler
├── Features/
│   ├── Dashboard/             # 7-day week grid + weekly summary
│   ├── DayDetail/             # meals + workouts for one day
│   ├── FoodSearch/            # USDA search, portion, barcode
│   ├── Workouts/              # manual workout sheet
│   ├── Weight/                # weight log + chart
│   └── Settings/              # goals, bank split, HealthKit auth
├── Shared/Extensions/         # Date/week helpers, formatters
├── Assets.xcassets
├── Info.plist
└── CalorieCalc.entitlements
CalorieCalcTests/
├── CalorieCalcTests.swift
└── CalorieBankCalculatorTests.swift
```

## The banking model (summary)

Four user parameters: **daily net goal**, **daily gross goal**, **daily workout goal**, **bank split** (e.g., 5 / 2).

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

All math lives in `Services/CalorieBankCalculator.swift` as a pure `nonisolated` enum — no SwiftUI / SwiftData / HealthKit imports. The test target `@testable import`s it.

## Known limitations (v2 backlog)

- Mid-week banking-day swaps (e.g., swap Friday with Saturday dynamically)
- Social features, sharing, streaks
- Meal photos / AI food recognition
- Recipe builder
- Water tracking
- Notifications / reminders
- iCloud sync across devices
- Multiple food-database providers (the `FoodDataSource` protocol makes this a drop-in — just add an implementation)
- Multi-platform UI polish — the project compiles for macOS/visionOS but HealthKit and barcode scanning are iOS-only

## Notes for future full-stack expansion

The current app is fully local (SwiftData on-device). When we stand up a backend:

- Keep `CalorieBankCalculator` client-side as the source of truth — server can mirror for analytics but not override.
- `CachedFood` already maps to a generic external ID; a future `FoodDataSource` can point at our own API.
- `UserProfile` will need a user ID field once we have auth; currently singleton.

## License

TBD
