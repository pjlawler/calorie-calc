# My Learning — UI Design Reference

Source-of-truth visual & UX spec for the **My Learning** page across every supported device, orientation, and appearance. Use it as the brief when re-building this page in another app or stack.

> This page has **three sub-tabs** (My Courses, Achievements, Logbook). All three are documented in full below. Each platform has its own implementation but the three-tab structure is identical across platforms.

Source files in this prototype:
- iOS / iPadOS / Web body — `src/components/content.tsx` → `CoursesContent` (lines ~196–283)
- iOS / iPadOS / Web chrome (header, SubNavBar / glass-pill sub-nav, bottom nav) — `src/components/ios.tsx` → `NavApp`
- Android phone/tablet body — `src/components/android.tsx` → `AnContentSection` (branch `active === 'courses'`, lines ~168–310)
- Android phone/tablet chrome — `src/components/android.tsx` → `AnCirrusPhone` / `AnCirrusTabletPortrait` / `AnCirrusTabletLandscape`
- Sub-tab labels & contextual actions — `src/constants.ts` → `PAGE_CONFIGS.courses`, `AN_PAGE_CONFIGS.courses`
- Action icons — `src/components/icons.tsx` → `ActionIcon`, `EXTERNAL_LINK_ACTIONS`

---

## 1. Page identity & platform variants

There are **two distinct page designs** sharing the same name and the same sub-tab structure:

| Variant | Devices | Content component |
|---|---|---|
| **Apple / Web** | iPhone 16 Pro, iPad mini 6, iPad Air, iPad Pro 11, iPad Pro 13, Desktop Web, Tablet Web, Mobile Web | `CoursesContent` |
| **Android (Material)** | Android Phone, Android Tablet (portrait & landscape) | `AnContentSection` branch `'courses'` |

The page title in chrome is **"My Learning"** (`PAGE_CONFIGS.courses.title = 'MY LEARNING'` on Apple/Web, `AN_PAGE_CONFIGS.courses.title = 'My Learning'` on Android).

### 1.1 Sub-tabs (3 across all platforms)

| Index | Label | Purpose |
|---|---|---|
| `0` | **My Courses** | Enrolled / in-progress courses; Android adds a "Browse" recommended list below. |
| `1` | **Achievements** | Earned badges; Android adds an "Upcoming Milestones" section and a header stat strip. |
| `2` | **Logbook** | Flight/training history; Android adds a header stat strip. |

### 1.2 Contextual header actions

When My Learning is open, the page-level header reveals extra actions depending on the active sub-tab (Apple/Web only — Android does not render these):

| Active sub-tab | Apple/Web actions | Notes |
|---|---|---|
| `My Courses` | `Course Catalog`, `Training Network` | Both flagged `EXTERNAL_LINK_ACTIONS`; render with external-link icon. Hidden on phone (filtered out via `EXTERNAL_LINK_ACTIONS` filter). |
| `Achievements` | `Certificates`, `Transcripts` | Show as buttons in the SubNavBar with leading SVG icons. |
| `Logbook` | `Export CSV` | Shown in the SubNavBar action slot with the export icon. |

---

## 2. Device specifications

Same physical frames as the Recent Activity reference. Inherited summary:

| Device id | Name | Portrait W × H | Side padding | Sub-nav style |
|---|---|---|---|---|
| `iphone` | iPhone 16 Pro | 393 × 852 | 20 px | Glass pill, equal-width tabs |
| `mini` | iPad mini 6 | 560 × 853 | 20 px | Glass pill, equal-width tabs |
| `air` | iPad Air | 688 × 980 | 20 px | Glass pill, equal-width tabs |
| `pro` | iPad Pro 11 | 748 × 1068 | 40 px | Glass pill, equal-width tabs |
| `pro13` | iPad Pro 13 | 860 × 1180 | 40 px | Glass pill, equal-width tabs |
| `desktop` | Desktop Web | 1120 × 720 | 60 px | Underlined-link SubNavBar (My Courses · Achievements · Logbook) + right-aligned action buttons |
| `tabweb` | Tablet Web | 834 × 1112 | 60 px | Underlined-link SubNavBar |
| `mobweb` | Mobile Web | 390 × 780 | 20 px | Glass pill |
| `aphone` | Android Phone | 393 × 852 | 16 px | Material TabRow pinned to bottom of content above the bottom nav (stretched, blue underline) |
| `atab` | Android Tablet | 768 × 1024 | 28 px (portrait) / 36 px (landscape) | Same Material TabRow pattern |

Vertical chrome padding mirrors Recent Activity (collapsing header ~76 px on iOS; Android status bar 28 px + top bar ~58 px).

---

## 3. Design tokens

Identical to the Recent Activity doc — same `DARK`/`LIGHT` (Apple) and `MD`/`ML` (Android) maps from `src/constants.ts`. Brief recap of the values used heavily on this page:

### 3.1 Apple / Web
| Token | Dark | Light |
|---|---|---|
| `bg` | `linear-gradient(160deg, #0d1628 0%, #0a0f1a 55%, #090e18 100%)` | `linear-gradient(160deg, #f2ede6 0%, #eee9e2 55%, #ece7e0 100%)` |
| `text` | `#ffffff` | `#1c1c1e` |
| `textSub` | `rgba(255,255,255,0.5)` | `rgba(0,0,0,0.5)` |
| `textMuted` | `rgba(255,255,255,0.3)` | `rgba(0,0,0,0.3)` |
| `separator` | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.07)` |
| Card bg | `rgba(255,255,255,0.05)` | `rgba(0,0,0,0.04)` |
| Card border | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.08)` |
| Progress track | `rgba(255,255,255,0.1)` | `rgba(0,0,0,0.1)` |

### 3.2 Android
| Token | MD (dark) | ML (light) |
|---|---|---|
| `bg` | `#0b0e14` | `#ebebef` |
| `surface` | `#101215` | `#ffffff` |
| `text` | `#e4e8f2` | `#0d1426` |
| `dim` | `rgba(196,206,228,0.68)` | `rgba(13,20,38,0.62)` |
| `primary` | `#3b9eff` | `#0057aa` |
| Surface fill | `rgba(255,255,255,0.055)` | `rgba(13,20,38,0.05)` |
| Surface border | `rgba(255,255,255,0.06)` | `rgba(13,20,38,0.07)` |
| Progress track | `rgba(255,255,255,0.1)` | `rgba(13,20,38,0.1)` |

### 3.3 Semantic accent colors (constant across themes)

Heavily used on this page:

| Purpose | Color |
|---|---|
| Primary action / IFR badge / progress < 80 % | `#0a84ff` (Apple) · `#3b9eff` (Android dark) · `#0057aa` (Android light) |
| Success / VFR badge / progress > 80 % | `#30d158` |
| Achievement gold / streak / star icons | `#ffd60a` |
| Warning / "Ground" log type | `#ff9f0a` |
| Secondary accent / "Sim" log type | `#5e5ce6` |
| Destructive / notification dot | `#FF3B30` / `#FF453A` |

---

## 4. Typography

Font family: `'Inter', -apple-system, sans-serif`. Brand Cirrus fonts referenced in `App.tsx` (commented out, ready to enable).

Common styles on this page:

| Style | Size | Weight | Color | Usage |
|---|---|---|---|---|
| Section overline | 10–11 px | 600/700 | `T.textMuted` (Apple) / `T.primary` (Android) | "IN PROGRESS", "EARNED", "TRAINING LOG", etc. — tracking 1.2 (Apple) / 1.4 (Android), UPPERCASE |
| Card title (course) | 14–15 px | 600 | `T.text` | "Instrument Currency Review" |
| Card title (badge / log row) | 13–14 px | 500/600 | `T.text` | "Instrument Currency" badge name |
| Category overline | 9–10 px | 700 | category color (or `T.primary` Android) | "IFR", "AVIONICS", "SAFETY", tracking 0.8–1, UPPERCASE |
| Card meta | 11–12 px | 400 | `T.textMuted` (Apple) / `T.dim` (Android) | "8 of 12 modules", date, hrs |
| Progress percent | 12 px | 700 | `#30d158` (>80) or `#0a84ff` | "68%" |
| Stat value (Android) | 22 (logbook) – 28 (achievements) px | 700 | `T.text` | "142.3", "5", "3" |
| Stat label (Android) | 9 px | 600 | `T.dim` | "TOTAL\nHOURS" (tracking 0.5, UPPERCASE, two-line) |
| Date column (logbook iOS) | 13 px | 600 | `T.text` | "Apr 28" |
| Hours column (logbook iOS) | 13 px | 600 | `T.text` | "1.2h" + 10 px / 600 IFR/VFR tag below |
| Type tag (Android log) | 9 px | 700 | type color | "FLIGHT", "GROUND", "SIM", tracking 0.3 |

---

## 5. Apple / Web variant — Sub-tab 0: My Courses

Container: `CoursesContent` with `subTab === 0` (lines ~202–227 of `content.tsx`).
Outer wrapper: `<div style={{ paddingTop: 10 }}>`. Inherits side padding from chrome (see §2).

### 5.1 Section overline
- "IN PROGRESS" — 11 px / 600 / `T.textMuted` / tracking 1.2 / UPPERCASE / `marginBottom: 14`.

### 5.2 Course card (repeats N times, full width)
Each card stacked vertically with `marginBottom: 10`.

- `padding: 16 px`
- `background: cardBg` (`rgba(0,0,0,0.04)` light / `rgba(255,255,255,0.05)` dark)
- `border: 1px solid cardBorder`
- `borderRadius: 16`, `cursor: pointer`
- Tapping a card → opens course detail (`onOpenCourse(i + 1)`).

Card internals (top → bottom):
1. **Category** — 10 px / 600 / `#0a84ff` / tracking 1 / UPPERCASE / `marginBottom: 6`
2. **Title** — 15 px / 600 / `T.text` / line-height 1.3 / `marginBottom: 14`
3. **Progress track** — `height: 3 px; background: trackBg; borderRadius: 2; overflow: hidden; marginBottom: 10`
   - Fill: `height: 100%; width: ${progress}%; borderRadius: 2`; color = `#30d158` if `progress > 80` else `#0a84ff`
4. **Meta row** (`display: flex; justifyContent: space-between; alignItems: center`):
   - Left: `${done} of ${total} modules` — 12 px / 400 / `T.textMuted`
   - Right: `${progress}%` — 12 px / 700 / progress color

### 5.3 Mock data
| Category | Title | Progress | Done | Total |
|---|---|---|---|---|
| IFR | Instrument Currency Review | 68 % | 8 | 12 |
| Avionics | Advanced Avionics: G1000 NXi | 24 % | 2 | 9 |
| Safety | Emergency Procedures Essentials | 91 % | 6 | 7 |

---

## 6. Apple / Web variant — Sub-tab 1: Achievements

Container: `CoursesContent` with `subTab === 1` (lines ~229–251 of `content.tsx`).

### 6.1 Section overline
- "EARNED" — 11 px / 600 / `T.textMuted` / tracking 1.2 / UPPERCASE / `marginBottom: 14`.

### 6.2 Badge row (repeats N times, full width)
Each row stacked vertically with `marginBottom: 10`.

- `display: flex; alignItems: center; gap: 14`
- `padding: 14 px`
- `background: cardBg`, `border: 1px solid cardBorder`, `borderRadius: 16`

Children left → right:
1. **Badge icon** — 44 × 44 rounded square (`borderRadius: 12`).
   - `background: ${color}22` (color + 13 % alpha hex)
   - `border: 1.5px solid ${color}44`
   - Star glyph `★` centered, 20 px font-size.
2. **Body** (flex 1, min-width 0):
   - Title 14 px / 600 / `T.text`
   - Description 12 px / 400 / `T.textMuted` / `marginTop: 2`
3. **Date** — 11 px / 400 / `T.textMuted` / nowrap, right-aligned.

### 6.3 Mock data
| Title | Description | Date | Color |
|---|---|---|---|
| Instrument Currency | Completed IFR currency review | Apr 22, 2026 | `#ffd60a` |
| Systems Expert — Level 1 | Passed advanced systems assessment | Mar 14, 2026 | `#5e5ce6` |
| 10-Course Streak | Completed 10 courses consecutively | Feb 8, 2026 | `#ff9f0a` |
| PPL Ground School | Finished all 18 ground school modules | Jan 3, 2026 | `#30d158` |

### 6.4 Header actions (Apple/Web only)
When this sub-tab is active, the page-level chrome reveals two action buttons in the SubNavBar (desktop/tablet only):
- **Certificates** — leading icon `IcoCertificates`
- **Transcripts** — leading icon `IcoTranscripts`

Action button style (from `SubNavBar`):
- `padding: 4px 10px`, `borderRadius: 6`
- `border: 1px solid T.separator`
- 11 px / 500 / `T.textSub`
- On hover: `color` and `borderColor` swap to `T.text`.

---

## 7. Apple / Web variant — Sub-tab 2: Logbook

Container: `CoursesContent` with `subTab === 2` (lines ~253–282 of `content.tsx`).

### 7.1 Header row
- `display: flex; justifyContent: space-between; alignItems: baseline; marginBottom: 14`
- Left: section overline **"RECENT FLIGHTS"** (same spec as §5.1, §6.1).
- Right: total hours **"142.5 hrs total"** — 12 px / 500 / `#0a84ff`.

### 7.2 Flight row (repeats N times)
Each row `display: flex; alignItems: center; gap: 14; padding: 13px 0`, bottom-border 1 px `cardBorder` except last.

Children left → right:
1. **Date column** — fixed `width: 44; textAlign: center; flexShrink: 0`:
   - Date 13 px / 600 / `T.text` (e.g. "Apr 28")
2. **Body** (flex 1, min-width 0):
   - Route 14 px / 500 / `T.text` (e.g. "KBUR → KLAX")
   - Remarks 11 px / 400 / `T.textMuted` / `marginTop: 2` (e.g. "ILS Rwy 24R · Night")
3. **Hours column** (right, `flexShrink: 0`, right-aligned):
   - Hours 13 px / 600 / `T.text` (e.g. "1.2h")
   - Type tag 10 px / 600 / type color / tracking 0.5 below; color = `#0a84ff` for IFR, `#30d158` for VFR

### 7.3 Mock data
| Date | Route | Type | Hours | Remarks |
|---|---|---|---|---|
| Apr 28 | KBUR → KLAX | IFR | 1.2 | ILS Rwy 24R · Night |
| Apr 22 | KSMF → KSFO | IFR | 0.9 | RNAV approach · IMC |
| Apr 18 | KVNY → KBUR | VFR | 0.4 | Pattern work |
| Apr 10 | KLAX → KLAS | IFR | 2.1 | Cross-country · IMC |

### 7.4 Header actions (Apple/Web only)
- **Export CSV** — renders inside the SubNavBar action slot. Same button style as Certificates/Transcripts but with `IcoExport` (10 × 11 leading icon).

---

## 8. Apple / Web chrome — My Learning specifics

Same `NavApp` chrome as Recent Activity, with three differences:

### 8.1 Glass-pill sub-nav (phone & tablet variants)
Always rendered on this page (3 sub-tabs).

- Container: full-width inside `padding: 0 16px 12px` (`0 16px 10px` for mobile web)
- Glass pill (`makeGlassPill(T)`) with `padding: 4 px; alignItems: center`
- Max width on tablets: `440 px` (no max on phones)
- Three equal flex children:
  - Mobile web: `padding: 7px 16px`, font-size 13
  - All others: `padding: 7px 10px`, font-size 11
  - Active: `background: T.subTabActiveBg` (`rgba(255,255,255,0.12)` dark / `rgba(0,0,0,0.1)` light), `color: T.subTabActiveColor` (white-ish dark / `#1c1c1e` light), weight 600
  - Inactive: transparent, `color: T.subTabInactiveColor` (`rgba(255,255,255,0.32)` dark / `rgba(0,0,0,0.35)` light), weight 400
  - `borderRadius: 9999`
  - Horizontal scroll fallback if pills overflow (`overflowX: auto`, `scrollbarWidth: none`).

### 8.2 SubNavBar — desktop & tablet web only
Used in addition to / instead of the glass pill on `desktop` / `tabweb` (the `borderless && !phone` branch).

- Bottom-bordered horizontal row (`borderBottom: 1px solid T.separator`, `marginBottom: 20`)
- Left side: three tab labels (`My Courses · Achievements · Logbook`):
  - `padding: 7px 0; marginRight: 20`
  - 11 px / 600 active (color `T.text`, underline `2px solid #0a84ff`)
  - 11 px / 400 inactive (`color: T.textSub`)
- Right side: action buttons (Certificates / Transcripts / Export CSV — see §6.4 & §7.4 for styling).

### 8.3 Centered page title
On phones & mobile-web, since this is not the home page, the top bar's centered title slot reads **"MY LEARNING"** — 13 px / 400 / `T.text` / tracking 1.2 / UPPERCASE / `whiteSpace: nowrap`, positioned absolute-center.

### 8.4 Back button
The top bar's left zone shows a 36 × 36 circular back button instead of the Cirrus logo (this is true any time `!isHome`, i.e. `active !== 'activity'` or `courseId > 0`). The button uses `T.circleBg` / `T.circleBorder` and a left-chevron SVG.

---

## 9. Android variant — Sub-tab 0: My Courses

Container: `AnContentSection` branch `'courses'` with `subTab === 0` (lines ~181–215 of `android.tsx`).

This sub-tab has **two stacked lists**: "In Progress" (large image cards) and "Browse" (compact rows).

### 9.1 "IN PROGRESS" overline
- 10 px / 700 / `T.primary` / tracking 1.4 / UPPERCASE / `marginBottom: 10`.

### 9.2 In-progress course card (repeats N times)
Each card stacked with `marginBottom: 12`, `borderRadius: 18`, `overflow: hidden`, `cursor: pointer`. Tapping opens course detail (`setCourseId(i + 1); setCourseTab(0); setLessonId(0)`).

Two-part structure:

**Top: `ImgHeader` (height 100 px)**
- Background image `c.img` (`IMG_AIRCRAFT`, `IMG_VPO`, `IMG_EVENT_0`) sized cover, over `c.fallback` linear-gradient.
- Dark gradient overlay `linear-gradient(180deg, rgba(0,0,0,0.05) 0%, rgba(0,0,0,0.75) 100%)`.
- Bottom-inset text (`padding: 12px 16px`):
  - Category overline — 9.5 px / 700 / `rgba(255,255,255,0.55)` / tracking 1.2 / UPPERCASE / `marginBottom: 3`
  - Title — 15 px / 600 / `#fff` / letter-spacing -0.2 / line-height 1.25

**Bottom: Progress strip (`padding: 11px 16px 14px`, `background: surf`)**
- Progress track `height: 3; background: trackBg; borderRadius: 2; marginBottom: 7`
- Fill color = `#30d158` if `p > 80` else `c.c`
- Meta row (`justifyContent: space-between; alignItems: center`):
  - Left: full subtitle (e.g. "IFR · Module 3 of 8") — 11 px / 400 / `T.dim`
  - Right: percent — 11 px / 700 / `#30d158` or `c.c`

### 9.3 In-progress mock data
| Title | Category / sub | Progress | Accent | Hero image |
|---|---|---|---|---|
| Instrument Currency Review | IFR · Module 3 of 8 | 68 % | `T.primary` | `IMG_AIRCRAFT` |
| SR22T Type Proficiency | Aircraft · 12 hrs | 25 % | `#5e5ce6` | `IMG_VPO` |
| Emergency Procedures Essentials | Safety · Module 7 of 8 | 91 % (→ green) | `#30d158` | `IMG_EVENT_0` |

### 9.4 "BROWSE" overline
- Same spec as 9.1, `marginTop: 4`.

### 9.5 Browse course row (repeats N times)
Each row `display: flex; alignItems: center; gap: 12; marginBottom: 10; borderRadius: 14; overflow: hidden; background: surf; cursor: pointer`.

Children left → right:
1. **Thumb** — `width: 64; height: 56`, image cover over fallback gradient, no padding.
2. **Body** (flex 1, `padding: 8px 0`):
   - Category overline 10 px / 700 / `T.primary` / tracking 0.8 / UPPERCASE / `marginBottom: 2`
   - Title 12.5 px / 500 / `T.text` / line-height 1.3
3. **Duration** — `paddingRight: 14`, 10.5 px / 400 / `T.dim` (e.g. "6 hr").

### 9.6 Browse mock data
| Title | Category | Duration | Image |
|---|---|---|---|
| SR Series Cross Country Procedures | IFR | 6 hr | `IMG_EVENT_1` |
| Weather Decision Making | Safety | 4 hr | `IMG_ARTICLE_1` |
| Garmin Perspective+ Mastery | Avionics | 8 hr | `IMG_VPO` |
| Mountain Flying & High-Density Altitude | Operations | 3 hr | `IMG_ARTICLE_2` |
| Night VFR Proficiency | Currency | 2 hr | `IMG_EVENT_0` |

---

## 10. Android variant — Sub-tab 1: Achievements

Container: `AnContentSection` with `subTab === 1` (lines ~217–267 of `android.tsx`).

Three stacked blocks: stats strip → "Earned Badges" → "Upcoming Milestones".

### 10.1 Stats strip — `marginBottom: 22`
Three equal cards (`display: flex; gap: 8`):
- `padding: 14px 10px 12px; background: surf; borderRadius: 16; textAlign: center`
- Value 28 px / 700 / `T.text` / letter-spacing -1
- Label 9 px / 600 / `T.dim` / tracking 0.5 / UPPERCASE / `marginTop: 4` / `whiteSpace: pre-line` (two-line stacked)

Mock data:
| Value | Label |
|---|---|
| 5 | Badges earned |
| 3 | Courses complete |
| 142 | Total hours |

### 10.2 "EARNED BADGES" overline (same spec as 9.1)

### 10.3 Earned badge row (repeats N times)
Each row `display: flex; alignItems: center; gap: 14; padding: 12px 0`, bottom-border 1 px `border` except last, `cursor: pointer`.

Children left → right:
1. **Badge** — 44 × 44 circle (`borderRadius: 50%`):
   - `background: ${color}20`
   - `border: 1.5px solid ${color}50`
   - Glyph 18 px / center / color = `a.color`
2. **Body** (flex 1):
   - Label 13 px / 600 / `T.text`
   - Description 11 px / 400 / `T.dim` / `marginTop: 2`
3. **Date** — 10 px / 400 / `T.dim` / nowrap, right-aligned.

Mock data:
| Glyph | Label | Description | Date | Color |
|---|---|---|---|---|
| ✓ | IFR Proficient | Completed Instrument Currency Review | Apr 2026 | `T.primary` |
| ★ | 100 hr PIC | Logged 100 hours pilot-in-command | Mar 2026 | `#ff9f0a` |
| ⊕ | CAPS Trained | CAPS activation recurrency complete | Feb 2026 | `#30d158` |
| ⛅ | Weather Wise | Passed Weather Decision Making course | Jan 2026 | `#5e5ce6` |
| ◎ | 50 hr IFR | 50 hours logged in IMC conditions | Dec 2025 | `T.primary` |

### 10.4 "UPCOMING MILESTONES" overline (`marginTop: 20`, same overline spec)

### 10.5 Milestone row (repeats N times, `marginBottom: 12`)
Per row:
- Header (`justifyContent: space-between; marginBottom: 5`):
  - Label 12.5 px / 500 / `T.text`
  - Right text — 11 px / 600 / `m.color` if `pct > 0` else `T.dim`; text = `${pct}%` or `"Not started"`
- Track — `height: 4; background: trackBg; borderRadius: 2; overflow: hidden`
- Fill — `height: 100%; width: ${pct}%; background: m.color; borderRadius: 2`

Mock data:
| Label | Progress | Color |
|---|---|---|
| SR22T Type Proficiency | 25 % | `#5e5ce6` |
| Mountain Flying | 0 % | `#ff9f0a` |
| Night VFR Proficiency | 0 % | `T.primary` |

---

## 11. Android variant — Sub-tab 2: Logbook

Container: `AnContentSection` with `subTab === 2` (lines ~270–309 of `android.tsx`).

Two stacked blocks: stats strip → "Training Log" grouped card.

### 11.1 Stats strip — `marginBottom: 22`
Same chrome as 10.1, but value font-size 22 (instead of 28) and letter-spacing -0.5.

Mock data:
| Value | Label |
|---|---|
| 142.3 | Total hours |
| 58.4 | IFR hours |
| 83.9 | VFR hours |

### 11.2 "TRAINING LOG" overline (same spec)

### 11.3 Training log grouped card
- `borderRadius: 16; overflow: hidden; background: surf`
- Stacks all entries inside the same card, bottom-bordered 1 px `border` between rows except last.

Each row `display: flex; alignItems: center; gap: 12; padding: 11px 14px; cursor: pointer`:

1. **Type tag tile** — 36 × 36 rounded square (`borderRadius: 9`):
   - `background: ${typeColor[e.type]}18`
   - Type label 9 px / 700 / `typeColor[e.type]` / tracking 0.3 / centered. Labels rendered UPPERCASE ("FLIGHT" / "GROUND" / "SIM").
2. **Body** (flex 1, min-width 0):
   - Title 12.5 px / 500 / `T.text`, single-line truncated with ellipsis (`overflow: hidden; textOverflow: ellipsis; whiteSpace: nowrap`)
   - Meta 10.5 px / 400 / `T.dim` / `marginTop: 1`, format: `${date} · ${course}`
3. **Duration** — 11 px / 600 / `typeColor[e.type]`, right-aligned, nowrap.

Type colors:
| Type | Color |
|---|---|
| Flight | `T.primary` |
| Ground | `#ff9f0a` |
| Sim | `#5e5ce6` |

### 11.4 Mock data
| Date | Type | Title | Duration | Course |
|---|---|---|---|---|
| Apr 29 | Ground | ILS Approach Review | 1.0 hr | Instrument Currency |
| Apr 27 | Flight | IFR Currency Flight — BNA/SDF | 1.2 hr | Instrument Currency |
| Apr 22 | Flight | Cross-country IFR — BNA/MEM/BNA | 3.7 hr | Independent |
| Apr 18 | Sim | CAPS Activation Procedure | 0.5 hr | Emergency Procedures |
| Apr 14 | Ground | Perspective+ Avionics Study | 2.0 hr | SR22T Proficiency |
| Apr 10 | Flight | SR22T Night Proficiency | 1.4 hr | Independent |
| Apr 6 | Ground | Weather Decision Making | 1.5 hr | Weather Course |
| Mar 31 | Flight | VFR Cross-country — KPWK/KGYY | 0.9 hr | Independent |

---

## 12. Android chrome — My Learning specifics

Same `AnCirrusPhone` / `AnCirrusTabletPortrait` / `AnCirrusTabletLandscape` shell as Recent Activity. The difference for My Learning is that **the bottom sub-tab row IS rendered** because `AN_PAGE_CONFIGS.courses.subTabs.length > 0`.

### 12.1 Bottom TabRow (Material style)
Pinned to the bottom of the scroll area (`position: absolute; bottom: 0; left: 0; right: 0; zIndex: 10`).

- Background: `rgba(16,22,36,0.58)` dark / `rgba(242,244,250,0.76)` light.
- `backdropFilter: blur(36px) saturate(2)`.
- Box shadow `0 -10px 28px rgba(0,0,0,0.28)` dark / `0 -6px 20px rgba(0,0,0,0.04)` light.
- `paddingBottom: 24` (safe-area for gesture nav).

Tab row (`TabRow` from `common.tsx`, `stretch` mode):
- `display: flex; maxWidth: 600; margin: 0 auto; width: 100%`
- Each tab: `flex: 1; padding: 18px 16px 16px; textAlign: center; cursor: pointer; position: relative`
- Label — 12.5 px / 700 active / 400 inactive; color = `T.primary` active / `T.dim` inactive; letter-spacing -0.1 when active
- Active underline: `position: absolute; bottom: 0; left: 25 %; right: 25 %; height: 2; borderRadius: 2px 2px 0 0; background: T.primary`

### 12.2 Content scroll padding
Because the bottom tab row is present, the content padding's bottom is **64 px** on phone (vs 32 px for Recent Activity) and **72 px** on tablet portrait/landscape.

### 12.3 Top bar
Same `AnHamburgerBtn` + `CirrusApproachLogo` + `AnTopBarActions` row as Recent Activity. The page title appears in the drawer/system area only; Android does not place a centered title in the top bar.

---

## 13. Orientation behavior

### 13.1 iPhone (`iphone`)
- Portrait: 4-tab bottom nav (PHONE_TABS), glass-pill sub-nav at top with all 3 tabs equal-width.
- Landscape: 5-tab bottom nav (TABS), same glass-pill sub-nav, side padding remains 20 px.

### 13.2 iPad (`mini` / `air` / `pro` / `pro13`)
- Portrait: 5-tab bottom nav, glass-pill sub-nav (max-width 440 px). Side padding 20 px (`mini`, `air`) / 40 px (`pro`, `pro13`).
- Landscape: same nav, side padding always 40 px.

### 13.3 Desktop & Tablet Web (`desktop`, `tabweb`)
- No orientation toggle. Underlined `SubNavBar` (not glass pill) rendered inside the scroll area, action buttons on the right.

### 13.4 Mobile Web (`mobweb`)
- Glass-pill sub-nav inside header, sub-tab pills sized larger (13 px font, 7 × 16 padding) for thumb reach.

### 13.5 Android Phone (`aphone`)
- Portrait: bottom Material TabRow centered (clamped to `maxWidth: 600`).
- Landscape: same component reflows; the TabRow stays clamped, content scrolls.

### 13.6 Android Tablet (`atab`)
- Portrait (`AnCirrusTabletPortrait`): content padding `20px 28px 72px`; bottom TabRow clamped to 600 px wide.
- Landscape (`AnCirrusTabletLandscape`): content padding `20px 36px 72px`. Course-detail screens clamp body content to `maxWidth: 860px` for readability; the My Learning list itself does **not** clamp width.

---

## 14. Appearance toggle (Light ↔ Dark)

Same rules as Recent Activity. On this page specifically:

- **All progress fills**, **percentage labels**, and **category overlines** keep their semantic accent colors across both themes — they never dim for light mode.
- **Badge circle backgrounds** use `${color}22`/`${color}20` (alpha tints) on both themes; the surrounding card chrome swaps light/dark like everywhere else.
- **IFR/VFR/Flight/Ground/Sim tag pills** retain their tint backgrounds (alpha 0.12–0.18 over white in light mode, over black in dark mode — both work without modification).
- **Logbook hours / dates / route text** uses `T.text` so they invert with the theme.

---

## 15. Behavior & interaction notes

- **Switching sub-tabs** resets the scroll position implicitly because the content list re-renders. Sub-tab state lives in `subTab` (`useCanvasState<number>('sn-subtab')` on Apple, `'an-subtab'` on Android). Switching pages from the bottom nav resets sub-tab to 0.
- **Tapping a course card** (sub-tab 0):
  - iOS phone / iPad: full-screen slide-up `IosCourseDetail` overlay (with hero image and progress ring).
  - Desktop / Tablet Web: replaces the scroll-area content with `WebCourseDetail`.
  - Android: pushes `CourseOverviewContent` overlay inside the same shell, with overview/lessons/enrollment-history sub-tabs at the bottom.
- **Achievements & log rows** are clickable affordances (`cursor: pointer`) but no destinations are wired in the prototype — in production they should open a badge detail / lesson summary.
- **Header chrome** (collapsing header on Apple phones/tablets) behaves exactly like Recent Activity: hides on scroll-down > 8 px once `scrollY > 60`, returns on scroll-up > 5 px; transitions out the bottom nav in tandem.
- **Export CSV** (sub-tab 2, Apple/Web only) is wired as a header SubNavBar action — no destination yet; it should trigger a CSV download in production.
- **Certificates / Transcripts** (sub-tab 1, Apple/Web only) should navigate to the documents pages defined under `MORE_MENU` (`certs`, `transcripts`).

---

## 16. Imagery & assets

iOS/Web My Learning **does not use imagery** in any sub-tab — all cards rely on color + typography only.

Android My Learning uses these CDN-hosted Figma assets via constants in `src/constants.ts`:

| Constant | Used in |
|---|---|
| `IMG_AIRCRAFT` | In-Progress course #1 hero (SR22T) |
| `IMG_VPO` | In-Progress #2 (SR22T Type Proficiency) + Browse "Garmin Perspective+ Mastery" |
| `IMG_EVENT_0` | In-Progress #3 (Emergency Procedures) + Browse "Night VFR Proficiency" |
| `IMG_EVENT_1` | Browse "SR Series Cross Country Procedures" |
| `IMG_ARTICLE_1` | Browse "Weather Decision Making" |
| `IMG_ARTICLE_2` | Browse "Mountain Flying & High-Density Altitude" |

Each image sits over a per-card linear-gradient `fallback` so a failed load still produces a tasteful gradient. Swap the CDN URLs for your own asset host in production.

---

## 17. Spacing & layout summary

- **Vertical rhythm between sections**: 14–22 px headers, 10–12 px between cards in a stacked list.
- **Card radius**: 14 px (Browse row, badge tile), 16 px (full-width course card, badge row, stat card), 18 px (Android in-progress card).
- **Card padding**:
  - Apple/Web course card: 16 px all sides.
  - Apple/Web badge row: 14 px all sides.
  - Apple/Web flight row: `13px 0` (no horizontal padding — flush to scroll-area padding).
  - Android in-progress card body: `11px 16px 14px`.
  - Android browse row body: `8px 0`.
  - Android log row: `11px 14px`.
- **Card gap in a stacked list**: 10–12 px.
- **Section overline → first child gap**: 14 px (Apple) / 10 px (Android).
- **Side padding** by device: see §2.

---

## 18. Build checklist when re-creating this page

- [ ] Pick the platform variant (Apple/Web vs Android) — visually distinct in sub-tabs 0 (imagery vs no imagery) and 1 (stats strip + milestones on Android only).
- [ ] Implement the 3-sub-tab structure with `subTab` integer state defaulting to 0; reset to 0 on page change.
- [ ] Wire device + orientation prop down so the chrome picks the right sub-nav (glass pill vs underlined SubNavBar vs bottom Material TabRow).
- [ ] Wire a `theme` prop / context so every component reads from the correct token map (`DARK`/`LIGHT` for Apple, `MD`/`ML` for Android).
- [ ] Implement contextual header actions (Apple/Web only): `[Course Catalog, Training Network]` (tab 0), `[Certificates, Transcripts]` (tab 1), `[Export CSV]` (tab 2). On phone, filter out `EXTERNAL_LINK_ACTIONS`.
- [ ] Build the seed data arrays with the shapes documented above — keep IFR/VFR distinction visible via accent color.
- [ ] Use Inter (and brand Cirrus fonts when available).
- [ ] Verify accent colors stay constant across light/dark — only chrome/text colors should swap.
- [ ] All cards in stacked lists are `cursor: pointer`. Wire tap targets: course cards → course detail; log rows → lesson detail; badges → badge detail (TBD in production).
- [ ] Test landscape on `iphone` (bottom nav swaps 4 → 5 tabs) and `atab` (orientation switches between `AnCirrusTabletPortrait` and `AnCirrusTabletLandscape` — same body component, different chrome paddings).
- [ ] Test scroll-to-hide chrome on Apple phones/tablets — sub-nav pill should animate out together with the header.
