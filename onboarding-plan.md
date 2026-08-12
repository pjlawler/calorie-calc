# Onboarding Flow — Scope

> **Status (2026-08-11): steps 1–4 built and passing.** Gate, container, goal / profile / plan /
> first-log steps, and the analytics seam are in `CalorieCalc/Features/Onboarding/`. Step 5
> (reminders) is still blocked on notifications, which don't exist in the app yet. See
> "Sequencing" at the bottom for what's left.


**Goal:** get a new user from install to *a plan they chose* and *one successful AI food log* inside their first session.

**Why:** 4,677 registered devices → 1,114 ever made an AI call (24%) → 35 active in the last 7 days (3.1% of those activated). Registrations grow ~8/day while DAU sits flat at 5–13. The app currently has no first-run experience at all: `RootView` drops straight into the tab bar, and whichever view loads first silently inserts a default `UserProfile()` (2,000 net / 1,800 gross / 150 workout, 6/1 split, Monday start). The user never picks a goal and never meets the AI feature that differentiates the app.

---

## What already exists (this is mostly sequencing, not new logic)

| Piece | File | Reuse |
|---|---|---|
| Biometrics form + AI plan recommendation | `Features/PlanAnalyzer/PlanAnalyzerSheet.swift` | Sex/age/height/weight/activity/workout-goal collection, `RecommendedPlan`, validation, Apply |
| Deterministic plan math | `Services/TDEECalculator.swift` | Mifflin–St Jeor → TDEE → `suggestedNet(tdee:pace:)`. **Non-AI fallback path.** |
| Plan commit | `Services/PlanCommitter.swift` + `GoalDraft` (`Features/Settings/SettingsView.swift:260`) | Single write path shared with Settings; handles `GoalPeriod` roll-forward |
| AI consent gate | `Services/AIConsentService.swift`, `Features/Settings/AIConsentSheet.swift` | Already the standard pre-AI interstitial at every AI entry point |
| AI photo log | `Features/FoodPhoto/FoodPhotoSheet.swift` → `FoodSearchResult` → portion sheet | The activation moment, unchanged |
| Plan sanity checks | `Services/PlanValidator.swift` | Reuse as-is on commit |

The only genuinely new code is the container, the step views, and the gate.

---

## Proposed flow

`fullScreenCover` over `RootView`, gated by `@AppStorage("onboarding.completedAt")`.

**1 — Goal.** One line on what the app does. Pick Lose / Maintain / Gain. No text entry.

**2 — About you.** Sex, age, height, current weight, goal weight, non-exercise activity, workout goal. One form. Prefill from HealthKit where already authorized, and from `WeightEntry` if any exist.

**3 — Your plan.** Show the computed net / gross / workout targets straight from `TDEECalculator` — a real plan with zero further input. Secondary button: *Refine with AI* → `AIConsentSheet` → existing `PlanRecommendationService`. Either branch commits through `PlanCommitter`.

**4 — Log your first meal.** Primary CTA: snap a photo → `AIConsentSheet` (if not yet granted) → `FoodPhotoSheet` → portion sheet → logged. Secondary, quieter: *I'll do this later*. **This screen is the whole point of the flow** — everything before it is setup that earns the right to ask.

**5 — Reminders.** Notification permission + meal reminder times. Depends on notification work not yet in the codebase (`UNUserNotificationCenter` appears nowhere). Cut from v1 if that lands separately.

Dismiss into the Week tab.

---

## Files

New — `CalorieCalc/Features/Onboarding/`:
- `OnboardingFlow.swift` — container, step enum, progress indicator, completion write
- `OnboardingState.swift` — `@Observable` draft holder (biometrics + goal) that survives back-navigation
- `OnboardingGoalStep.swift`
- `OnboardingProfileStep.swift`
- `OnboardingPlanStep.swift`
- `OnboardingFirstLogStep.swift`

Modified:
- `App/RootView.swift` — the `fullScreenCover` gate; sequencing against the existing bootstrap `.task`
- `Features/Dashboard/DashboardView.swift:974` (`ensureProfile`) and `Features/WeekCalendar/WeekCalendarView.swift:176` — onboarding becomes the owner of first-profile creation; these stay as fallbacks

Tests — `CalorieCalcTests/OnboardingTests.swift`:
- gate opens on a genuinely fresh install
- gate stays shut once `onboarding.completedAt` is set
- gate stays shut when CloudKit delivers an existing profile/history (returning user, new device)
- completing the flow produces exactly one `UserProfile` and one open `GoalPeriod`
- AI-refuse and AI-failure paths still commit the deterministic plan

---

## Risks specific to this codebase

**CloudKit singleton duplication.** Onboarding must not insert a second `UserProfile`. Read the canonical row the way every other view does (`@Query(sort: \UserProfile.createdAt)`, take `.first`) and let `DataDeduplicator` remain the backstop. Getting this wrong duplicates the profile for every new user — worse than having no onboarding.

**Returning users on a new device.** CloudKit may deliver an existing profile and history *after* first launch, so "no profile yet" is not a reliable fresh-install signal. Gate on the `@AppStorage` flag plus a short grace check for synced `FoodEntry`/`GoalPeriod` history before showing the flow, and mark onboarding complete if history arrives.

**Never dead-end.** The AI plan step costs a credit and can hit consent refusal, a network failure, or (eventually) the paywall. The `TDEECalculator` path must always be able to finish the flow. No screen may be un-exitable.

**Bootstrap collision.** `RootView.task` already runs HealthKit sync, StoreKit priming, entitlement refresh, the ATT prompt, ad SDK init, and a review prompt. Onboarding must cover the UI without blocking that work, and the ATT and review prompts must not fire underneath the cover — `ReviewPromptService` in particular should not count an onboarding launch.

**Credit spend.** A user who refines with AI and logs one photo spends ~2 of their 50 free credits before seeing any value. Acceptable, and arguably the best 2 credits in the funnel.

---

## Instrumentation (do this alongside, not after)

The flow is worthless without knowing where it leaks, and there is currently no client analytics of any kind. Minimum events: `onboarding_started`, per-step completion, `plan_committed` (ai | deterministic), `first_log_attempted`, `first_log_succeeded`, `onboarding_completed`, `onboarding_skipped`, plus D1/D7 return. Without these the next iteration is guesswork.

---

## Sequencing

1. Instrumentation hooks
2. Gate + container + steps 1–3 (plan setup, deterministic path only)
3. AI refine on step 3
4. Step 4 first-log
5. Step 5 reminders — only once notifications exist

Steps 1–3 are shippable on their own and already fix the "silent default plan" problem. Step 4 is where the retention number should actually move.
