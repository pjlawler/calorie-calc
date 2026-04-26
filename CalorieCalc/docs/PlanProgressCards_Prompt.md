# CalorieBank — Plan Progress (Two Cards)

## Read this section before anything else

This task has been attempted multiple times and produced wrong arithmetic each time. The bug is always the same: the implementer treats reference values as part of the math, computes a wrong total, and ships a screen where the visible row values do not add up to the displayed total.

This prompt is structured to make that bug impossible. The math card has four rows that look like math operands. The reference card looks like prose sentences. **If you find yourself adding any value from the reference card to anything in the math card, you are reproducing the known failure mode. Stop and re-read this prompt.**

---

## What you're building

Two SwiftUI views that render below the weekly day list on the Calc tab of CalorieBank, an iOS 26+ app (Swift 6, SwiftData). They are completely independent — they have separate data, separate layouts, separate purposes. They render on every day of the plan week.

1. **Math card** — a centered hero number with four breakdown rows that visibly sum to a total.
2. **Reference card** — three plain English sentences that describe the user's weekly state, with values inline.

## What it looks like

![Two-card mockup](images/two_cards.png)

The two cards are visually different on purpose:

- The math card uses a table-like layout with right-aligned values and `+`/`−` prefixes. It looks like arithmetic.
- The reference card uses **prose sentences**, not rows. Values appear inline within sentences. There are no `+`/`−` prefixes. There is no right-aligned column of numbers. It does not look like arithmetic because it is not arithmetic.

This visual difference is load-bearing. Do not redesign the reference card to look like the math card. Do not give the reference card a table layout, right-aligned values, or `+`/`−` prefixes.

---

## Card 1: Math card

### The only formula

```
estimated_remaining = weekly_calorie_budget
                    − already_eaten_this_week
                    + workouts_completed
                    + planned_to_workout
```

Four inputs. One output. No other values exist on this card.

### Worked example to verify against

Saturday, last day of a Sun–Sat plan week:
- weekly_calorie_budget = 11,200
- already_eaten_this_week = 13,947
- workouts_completed = 3,742
- planned_to_workout = 0

```
11,200 − 13,947 + 3,742 + 0 = 995
```

The hero shows **995**. The total row shows **995**. The four input rows displayed on screen, with their displayed signs, sum to 995.

### What the math card displays (top to bottom)

```
ESTIMATED CALORIES REMAINING
        995
   for the rest of the week

Weekly calorie budget        11,200 kCal
Already eaten this week     −13,947 kCal
Workouts completed           +3,742 kCal
Planned to workout               +0 kCal
─────────────────────────────────────────
Estimated remaining             995 kCal
```

### Math card row definitions

| Row | Sign | Color | Source value |
|---|---|---|---|
| Weekly calorie budget | None | Primary text | `weekly_calorie_budget` |
| Already eaten this week | Always `−` | Primary text | `already_eaten_this_week` |
| Workouts completed | Always `+` | Green `#1D9E75` | `workouts_completed` |
| Planned to workout | Always `+` | Green `#1D9E75` | `planned_to_workout` |
| Estimated remaining (total) | None if ≥0, `−` if <0 | Green if ≥0, red `#A32D2D` if <0 | computed: above formula |

### Math card input definitions

- **`weekly_calorie_budget`** — sum of daily eating goals across the entire plan week. A positive integer from the user's plan configuration.
- **`already_eaten_this_week`** — sum of all calories logged eating from day 1 through right now (real-world current time, including any food logged today).
- **`workouts_completed`** — sum of all workout calories burned from day 1 through right now (real-world current time, including any workout completed today). **Plain total of actuals.** Do NOT compare to the workout plan. Do NOT compute "surplus." Every burned calorie counts.
- **`planned_to_workout`** — sum of daily workout goals for **tomorrow onward**, through the last day of the plan week. Today's planned workout is NOT included. On the last day of the plan week, this is 0.

### Math card visual specification

Outer card:
- Light gray surface (`Color(uiColor: .secondarySystemBackground)`)
- 12pt corner radius
- 24pt top padding, 16pt horizontal padding, 20pt bottom padding

Hero (centered text alignment):
- Eyebrow `ESTIMATED CALORIES REMAINING` — 11pt, weight 500, uppercase, letter-spacing 0.5pt, secondary text color, 8pt bottom margin
- Hero number — 56pt, weight 500, line-height 1.0, green `#1D9E75` if ≥0, red `#A32D2D` with `−` prefix if <0
- Caption `for the rest of the week` — 13pt, secondary text color, 8pt top margin, 20pt bottom margin

Input rows (4pt vertical / 4pt horizontal padding, label left, value right, baseline-aligned):
- Label: 13pt, secondary text color
- Value: 14pt, weight 500, sign and color per the table above
- Numbers must use comma thousands separators
- Use tabular numerals so values right-align cleanly across rows

Divider: 0.5pt horizontal line, `Color.black.opacity(0.12)`, 8pt vertical margin above and below, 4pt horizontal padding.

Total row (4pt vertical / 4pt horizontal padding):
- Label `Estimated remaining` — 13pt, weight 500, primary text color
- Value — 16pt, weight 500, color per the table above

---

## Card 2: Reference card

This card is **prose, not a table**. It contains three sentences, each on its own line, with embedded values. The implementer will be tempted to render this as another row-based table — do not do that. The prose format is required.

### What the reference card displays

```
WHERE THIS WEEK STANDS

Your weekly workout plan was 3,150 kCal.
You have 0 kCal of eating planned for the rest of the week.
You're currently behind plan by 2,155 kCal.
```

The exact text is below. Substitute the numeric values; do not change the surrounding words.

### The three sentences

**Sentence 1 (always rendered):**
> Your weekly workout plan was **`weekly_workout_plan`** kCal.

Where `weekly_workout_plan` is the sum of daily workout goals across the entire plan week, formatted with comma thousands separators (e.g., `3,150`).

**Sentence 2 (always rendered):**
> You have **`planned_to_eat`** kCal of eating planned for the rest of the week.

Where `planned_to_eat` is the sum of daily eating goals for tomorrow onward through the last day of the plan week. On the last day, this is 0.

**Sentence 3 — variance** (rendered conditionally based on the sign):

If `plan_variance > 0`:
> You're currently **ahead of plan by `[plan_variance]`** kCal.

If `plan_variance < 0`:
> You're currently **behind plan by `[abs(plan_variance)]`** kCal.

If `plan_variance == 0`:
> You're currently **right on plan**.

### Plan variance formula

```
plan_variance = (planned_to_eat_so_far − already_eaten_this_week)
              + (workouts_completed − planned_to_workout_so_far)
```

Where:
- `planned_to_eat_so_far` = sum of daily eating goals from day 1 through end of today
- `planned_to_workout_so_far` = sum of daily workout goals from day 1 through end of today

### Variance worked example

For the same Saturday scenario:
```
plan_variance = (11,200 − 13,947) + (3,742 − 3,150)
              = (−2,747) + (+592)
              = −2,155
```

Sentence 3 reads: **"You're currently behind plan by 2,155 kCal."**

### Reference card visual specification

Outer card:
- Slightly darker gray surface than the math card (e.g., `#EEEEEB` in light mode — visually distinct so it doesn't read as a continuation of the math card; use a slightly more elevated dark stop in dark mode)
- 12pt corner radius
- 14pt vertical / 16pt horizontal padding
- 12pt top margin separating it from the math card

Eyebrow:
- Text: `WHERE THIS WEEK STANDS` — 11pt, weight 500, uppercase, letter-spacing 0.4pt, tertiary text color
- 4pt left padding to align with sentence text
- 8pt bottom margin

Each sentence:
- 12pt, regular weight (NOT 500), tertiary text color (`#8E8E8B` light mode), line-height 1.5
- 3pt vertical / 4pt horizontal padding per sentence
- The numeric values inside the sentence (the bolded parts in the spec above) are rendered in a slightly stronger color (secondary text color, `#6B6B68` light mode) at weight 500, but the surrounding sentence stays at regular weight tertiary color
- For sentence 3 only: the variance phrase ("ahead of plan by N", "behind plan by N", or "right on plan") uses green `#1D9E75` if ahead, red `#A32D2D` if behind, secondary text color if exactly on plan, all at weight 500

The reference card has **no right-aligned values, no `+`/`−` sign prefixes, no divider, no total row**. It is prose. Implementing it as a table is wrong.

---

## Forbidden output (known wrong answers)

These are outputs from previous failed attempts. **Do not reproduce them.**

### Forbidden output 1: math card with wrong total

```
WRONG — DO NOT REPRODUCE:

Weekly calorie budget    11,200 kCal
Already eaten this week  −13,947 kCal
Workouts completed       +3,742 kCal
Planned to workout       +0 kCal
─────────────────────────────────────
Estimated remaining      4,145 kCal       ← WRONG (should be 995)
```

The bug: `4,145 = 11,200 − 13,947 + 3,742 + 0 + 3,150` — the implementer added `weekly_workout_plan` (3,150) to the formula even though it does not appear as a row in the math card. **Do not do this.** The four math card rows shown on screen, and only those four rows, sum to the total.

If your computed `estimated_remaining` includes any of the following values, you have a bug:
- `weekly_workout_plan` (the user's planned weekly workout total)
- `planned_to_eat` (eating planned for tomorrow onward)
- `planned_to_eat_so_far` (eating planned through today)
- `planned_to_workout_so_far` (workouts planned through today)
- `plan_variance` (the variance value itself)

`estimated_remaining` is computed from exactly four values, named in the formula above. Nothing else.

### Forbidden output 2: variance row with wrong value

```
WRONG — DO NOT REPRODUCE:

WHERE THIS WEEK STANDS
Weekly workout plan      3,150 kCal
Planned to eat               0 kCal
Plan variance              995 kCal       ← WRONG
```

Two bugs here:
1. The reference card is rendered as a row-based table. It must be prose sentences instead.
2. The implementer placed `estimated_remaining` (995) in the variance row instead of computing `plan_variance`. **Plan variance and estimated remaining are different numbers and use different formulas. They will rarely be equal.** For the worked example, `estimated_remaining = 995` and `plan_variance = −2,155`.

### Forbidden output 3: combining the two cards

```
WRONG — DO NOT REPRODUCE:

(One card with a "Plan" group, "Actuals" group, and "Progress" group containing all 7 rows)
```

Card 1 and Card 2 are **two separate SwiftUI views** with a 12pt gap between them. They must not be combined into a single card with internal sections. The visual separation prevents the implementer from accidentally summing values across the two.

---

## Implementation

```swift
// Two completely separate data structs for two completely separate views.

struct MathCardData {
    let weeklyCalorieBudget: Int          // 11200
    let alreadyEatenThisWeek: Int         // 13947
    let workoutsCompleted: Int            // 3742
    let plannedToWorkout: Int             // 0 on last day; tomorrow onward otherwise
    
    var estimatedRemaining: Int {
        weeklyCalorieBudget
        - alreadyEatenThisWeek
        + workoutsCompleted
        + plannedToWorkout
    }
}

struct ReferenceCardData {
    let weeklyWorkoutPlan: Int            // 3150
    let plannedToEat: Int                 // 0 on last day; tomorrow onward otherwise
    let alreadyEatenThisWeek: Int         // 13947 (used only for variance)
    let workoutsCompleted: Int            // 3742  (used only for variance)
    let plannedToEatSoFar: Int            // sum of daily eating goals day 1 through end of today
    let plannedToWorkoutSoFar: Int        // sum of daily workout goals day 1 through end of today
    
    var planVariance: Int {
        (plannedToEatSoFar - alreadyEatenThisWeek)
        + (workoutsCompleted - plannedToWorkoutSoFar)
    }
}

struct MathCard: View {
    let data: MathCardData
    var body: some View {
        // Renders ONLY MathCardData fields.
        // Hero number = data.estimatedRemaining
        // Four input rows + divider + total row
    }
}

struct ReferenceCard: View {
    let data: ReferenceCardData
    var body: some View {
        // Renders ONLY ReferenceCardData fields.
        // Eyebrow + three sentences (prose, not rows)
    }
}

struct PlanProgressSection: View {
    let mathData: MathCardData
    let referenceData: ReferenceCardData
    
    var body: some View {
        VStack(spacing: 12) {
            MathCard(data: mathData)
            ReferenceCard(data: referenceData)
        }
    }
}
```

`alreadyEatenThisWeek` and `workoutsCompleted` appear in both data structs because the variance calculation needs them — but `MathCard` never sees `ReferenceCardData` and `ReferenceCard` never sees `MathCardData`. The values flow into both from the parent view model, but the views themselves are isolated.

Use `@Observable` view models per Swift 6 conventions. Numbers display with comma thousands separators (`Int.formatted(.number)`). All numbers are integer kCal — round at the display layer.

---

## Acceptance checklist

The implementation is correct if and only if all of these are true:

- [ ] Two physically separate `View`s with a 12pt gap between them
- [ ] `MathCard` and `ReferenceCard` are separate Swift structs in separate `View` types
- [ ] `MathCard` only references fields from `MathCardData`; `ReferenceCard` only references fields from `ReferenceCardData`
- [ ] Math card hero number equals `weekly_calorie_budget − already_eaten_this_week + workouts_completed + planned_to_workout`
- [ ] The four math card rows visibly sum (with their displayed signs) to the total row exactly
- [ ] Math card has exactly 4 input rows + divider + 1 total row. Not 5. Not 6. Not 7.
- [ ] Reference card is rendered as prose sentences, not as a table or row layout
- [ ] Reference card has no right-aligned values, no `+`/`−` prefixes, no divider, no total
- [ ] Sentence 3 of the reference card uses three different texts depending on the sign of `plan_variance` (positive, negative, zero)
- [ ] Plan variance computed as `(planned_to_eat_so_far − already_eaten_this_week) + (workouts_completed − planned_to_workout_so_far)`
- [ ] `workouts_completed` is a plain sum of all logged workouts, never compared to plan
- [ ] `planned_to_workout` and `planned_to_eat` count only tomorrow onward, not today
- [ ] Worked example produces these visible values:
  - Math card hero: `995`
  - Math card total row: `995 kCal`
  - Reference sentence 3: `You're currently behind plan by 2,155 kCal.`
- [ ] All labels and sentence templates match this document verbatim
- [ ] Cards render correctly in light and dark mode
- [ ] Numeric values update reactively as the user logs food or workouts

If the math card row values do not visibly sum to the total row, **the build is wrong.**

If any value from the reference card appears in the math card's total calculation, **the build is wrong.**

If the reference card is rendered as a table instead of prose, **the build is wrong.**
