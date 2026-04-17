# Build Prompt: CalorieBank iOS App

## Role & Goal

You are a senior iOS engineer. Build a complete, production-ready Xcode project for an iOS app called **CalorieBank** — a calorie and macro tracker built around a "banking" paradigm that no other mainstream app (MyFitnessPal, Lose It, Cronometer) implements well.

Deliver a full Xcode project: file structure, every Swift file with complete code, `Info.plist` entries, entitlements, asset catalogs, and a README with build/run instructions. No placeholders, no "TODO: implement this" comments in critical paths.

---

## Core Concept: Calorie Banking

This is the app's differentiator. Build around it.

Most trackers enforce a rigid daily calorie target. CalorieBank lets users average across a weekly cycle so they can "bank" calories on disciplined days and spend them on social/off days.

### The math (this is the source of truth for all calculations)

The user sets four parameters:

1. **Daily net calorie goal** (e.g., 1,600 kcal) — the average they want to *net* per day across the week
2. **Daily gross intake goal** (e.g., 1,800 kcal) — what they plan to *eat* on banking days
3. **Daily workout goal** (e.g., 500 kcal burned) — planned active energy on banking days
4. **Bank split** (e.g., 5/2, 6/1, 4/3) — how many days per week are "banking days" vs. "off days"

**Weekly net target** = `daily_net_goal × 7` (e.g., 1,600 × 7 = **11,200 kcal net for the week**)

**Weekly gross allowance** = `weekly_net_target + sum(workout_calories_for_the_week)`

Example: 11,200 + (500 × 7) = **14,700 kcal** can be eaten that week if every day hits the workout goal.

**Banking day consumption** = `daily_gross_goal × banking_days`

Example: 1,800 × 5 = **9,000 kcal consumed Mon–Fri** (if user hits plan exactly)

**Off-day remaining budget** = `weekly_gross_allowance − calories_already_eaten − projected_calories_for_remaining_banking_days`

Example: 14,700 − 9,000 = 5,700 kcal for Sat+Sun → **2,850 kcal per off-day**

### Critical behavior

The dashboard is a **living calculator**. Every food log, every HealthKit workout update, every manual workout entry, every change to any day — immediately recalculates the remaining budget for all future days in the week and updates the off-day bank.

If the user overeats on Tuesday, Saturday's available calories drop in real time. If they skip a workout, same thing. If they underate or burned extra, the off-day bank grows. **The app shows truth. It does not nag, warn, color-code, or auto-adjust the plan. The user reads the numbers and decides.**

---

## Target Platform & Stack

- **iOS 26+** only
- **Swift 6** with strict concurrency
- **SwiftUI** for all UI
- **SwiftData** for persistence (no Core Data, no Firebase)
- **HealthKit** for active energy and workouts (read-only)
- **AVFoundation + Vision** for barcode scanning
- **USDA FoodData Central API** for food search (https://fdc.nal.usda.gov/api-guide)
- Architecture: MVVM with `@Observable` view models, dependency-injected services
- No third-party dependencies unless absolutely required — justify each one

---

## Features (MVP Scope)

### 1. Weekly Dashboard (primary view on app open)

- Calendar-style view showing all 7 days of the current week at once
- Default week: **Monday–Sunday**, with Saturday and Sunday as off-days (5/2 split)
- Each day cell shows:
  - Day name and date
  - Calories consumed / gross budget for that day
  - Calories burned (HealthKit active energy + manual workouts)
  - Net calories (consumed − burned)
  - A small macro ring or bar (protein/carbs/fat)
- Top of dashboard: current weight (manual entry, tappable to log new weight), trend vs. starting weight
- Bottom of dashboard (or a header card): **weekly summary**
  - Weekly net target
  - Running weekly net actual
  - Off-day calories remaining (the "bank")
- Tap any day → day detail view

### 2. Day Detail View

- Four meal sections: **Breakfast, Lunch, Dinner, Snacks**
- Each section: list of food entries with calories and macros, "+ Add food" button
- Workouts section below meals: shows HealthKit-synced active energy for the day + any manually logged workouts
- Day totals footer: consumed, burned, net, gross budget for that day, variance

### 3. Food Search & Logging

- Search bar queries USDA FoodData Central API
- Results list with food name, brand (if applicable), serving size, calories per serving
- Tap a food → portion adjustment sheet (serving size, quantity) → log to a meal
- **Barcode scanner** (camera view): scans UPC → queries USDA → falls back to manual entry if not found
- **Recent foods** and **favorites** — cached locally in SwiftData for fast re-logging
- Architect the food data source as a protocol (`FoodDataSource`) so additional providers (Open Food Facts, Nutritionix) can be added later without touching call sites

### 4. Workout Logging

- **HealthKit integration**: read `HKQuantityTypeIdentifier.activeEnergyBurned` and `HKWorkoutType` for each day
- **Manual workout entry**: name, duration, calories burned, optional notes
- Day's total burned = HealthKit active energy + manual workouts (manual workouts are additive; do not double-count if the user manually logs something already in HealthKit — show both and let the user exclude one)

### 5. Settings

- Daily net calorie goal
- Daily gross calorie goal
- Daily workout calorie goal
- Bank split (5/2 default, options: 7/0, 6/1, 5/2, 4/3, 3/4)
- Week start day (default Monday)
- Which days are banking vs. off-days (default: weekdays banking, weekend off)
- Weight unit (lb / kg)
- Energy unit (kcal only for v1)
- HealthKit permissions management
- Starting weight (for progress calculation)

### 6. Weight Tracking

- Manual entry only for v1
- Tappable weight display on dashboard opens a sheet with weight history (simple line chart using Swift Charts) and a "+ Log weight" button
- Store weight entries in SwiftData with timestamp

---

## Out of Scope for v1 (note in README for v2)

- Mid-week banking day swaps (e.g., swap Friday and Saturday) — keep rigid for v1
- Social features, sharing, streaks
- Meal photos / AI food recognition
- Recipe builder
- Water tracking
- Notifications / reminders
- iCloud sync across devices (SwiftData's CloudKit integration — nice-to-have, add if trivial)
- Multiple food database providers (architect for it, implement only USDA)

---

## Data Model (SwiftData)

Design these models. Use proper relationships, cascade deletes where appropriate, and `@Attribute(.unique)` on IDs.

- `UserProfile` — singleton: goals, bank split, week start, starting weight, units
- `DayLog` — one per calendar date: date, relationship to food entries and manual workouts
- `FoodEntry` — logged food: name, brand, serving size, quantity, calories, protein, carbs, fat, meal type enum (breakfast/lunch/dinner/snack), timestamp, source (USDA FDC id, barcode, manual), relationship to DayLog
- `ManualWorkout` — name, duration (seconds), calories burned, timestamp, notes, relationship to DayLog
- `WeightEntry` — weight, unit, timestamp
- `CachedFood` — for recents and favorites: FDC id, name, brand, default serving, calories, macros, isFavorite, lastUsed

HealthKit data is read live — do **not** mirror it into SwiftData.

---

## Architecture Requirements

- **Services layer** (protocols + implementations):
  - `FoodDataSource` protocol → `USDAFoodDataCentralService` implementation
  - `HealthKitService` — authorization, active energy query, workouts query
  - `BarcodeScannerService` — AVFoundation + Vision
  - `CalorieBankCalculator` — pure-function logic for all the banking math; this is the heart of the app and must be thoroughly unit-testable with no UIKit/SwiftUI/HealthKit dependencies
- **View models** use `@Observable` (iOS 17+ macro), inject services via initializer
- **Views** are thin; all logic lives in view models or the calculator
- **Unit tests** for `CalorieBankCalculator` covering:
  - Exact-plan week (user hits every target)
  - Overeating on a banking day
  - Underearting on a banking day
  - Skipping a workout
  - Extra workout
  - Mid-week recalculation (Wednesday state with Mon/Tue actuals + Thu/Fri/Sat/Sun projected)
  - Edge cases: 7/0 split (no off days), 0 workouts logged, negative net day

---

## USDA FoodData Central API Notes

- API docs: https://fdc.nal.usda.gov/api-guide
- Requires a free API key — instruct user in README to get one and add to `Secrets.xcconfig` (gitignored), loaded via `Info.plist` build setting
- Use the `/v1/foods/search` endpoint for text search and `/v1/food/{fdcId}` for details
- For barcodes: USDA's `gtinUpc` field is searchable via the search endpoint with the UPC as the query — handle the "not found" case gracefully with a manual-entry fallback sheet

---

## UI/UX Principles

- Native iOS 26 look and feel — SF Symbols, system materials, default navigation patterns
- No custom color coding of over/under status (user was explicit: just show numbers)
- Weekly dashboard must fit on one screen for the 7-day overview on standard iPhone sizes without scrolling the week itself (individual day content can be dense but the 7 cells should all be visible)
- Support both light and dark mode
- Dynamic Type support throughout
- VoiceOver labels on all interactive elements and all numeric displays (e.g., "Tuesday, 1,450 calories consumed of 1,800 budget")

---

## Deliverables

1. **Complete Xcode project** with correct folder structure. Suggested layout:

```
CalorieBank/
├── CalorieBank.xcodeproj
├── CalorieBank/
│   ├── App/
│   │   ├── CalorieBankApp.swift
│   │   └── RootView.swift
│   ├── Models/
│   │   ├── UserProfile.swift
│   │   ├── DayLog.swift
│   │   ├── FoodEntry.swift
│   │   ├── ManualWorkout.swift
│   │   ├── WeightEntry.swift
│   │   ├── CachedFood.swift
│   │   └── Enums.swift
│   ├── Services/
│   │   ├── FoodDataSource.swift
│   │   ├── USDAFoodDataCentralService.swift
│   │   ├── HealthKitService.swift
│   │   ├── BarcodeScannerService.swift
│   │   └── CalorieBankCalculator.swift
│   ├── Features/
│   │   ├── Dashboard/
│   │   │   ├── DashboardView.swift
│   │   │   ├── DashboardViewModel.swift
│   │   │   └── DayCellView.swift
│   │   ├── DayDetail/
│   │   │   ├── DayDetailView.swift
│   │   │   ├── DayDetailViewModel.swift
│   │   │   └── MealSectionView.swift
│   │   ├── FoodSearch/
│   │   │   ├── FoodSearchView.swift
│   │   │   ├── FoodSearchViewModel.swift
│   │   │   ├── BarcodeScannerView.swift
│   │   │   └── FoodPortionSheet.swift
│   │   ├── Workouts/
│   │   │   ├── ManualWorkoutSheet.swift
│   │   │   └── WorkoutsSectionView.swift
│   │   ├── Weight/
│   │   │   ├── WeightLogView.swift
│   │   │   └── WeightHistoryView.swift
│   │   └── Settings/
│   │       ├── SettingsView.swift
│   │       └── SettingsViewModel.swift
│   ├── Shared/
│   │   ├── Extensions/
│   │   └── Components/
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Secrets.xcconfig.example
│   └── Info.plist
├── CalorieBankTests/
│   ├── CalorieBankCalculatorTests.swift
│   └── MockServices.swift
└── README.md
```

2. **Info.plist** with:
   - `NSHealthShareUsageDescription`
   - `NSCameraUsageDescription` (for barcode scanner)
   - Background modes if needed for HealthKit

3. **Entitlements file** with HealthKit capability enabled

4. **README.md** covering:
   - Build requirements (Xcode version, iOS target)
   - How to get a USDA FoodData Central API key
   - How to set up `Secrets.xcconfig`
   - How to run the unit tests
   - Known limitations and the v2 backlog (mid-week banking day swaps, multiple food providers, iCloud sync, notifications, etc.)

5. **Unit tests** for `CalorieBankCalculator` as specified above — these must pass

---

## Build Instructions for You (the AI)

1. Start by implementing and fully testing `CalorieBankCalculator` — this is the riskiest piece and everything else depends on it being right. Write tests first, then the implementation.
2. Then the SwiftData models.
3. Then the services (HealthKit, USDA, barcode).
4. Then the views, starting with the dashboard.
5. Wire everything together in `CalorieBankApp.swift` with the SwiftData `ModelContainer` and service dependencies.
6. Verify the test suite passes.
7. Write the README last, once you know what you actually built.

If you hit a genuine ambiguity that would change the app's behavior (not a style choice), ask before guessing. For style choices, make a reasonable call and note it in the README.

Produce the full code. No stubs, no ellipses, no "implementation left as an exercise."
