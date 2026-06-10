# Feasibility Plan: Apple Foundation Models for AI food search

**Branch:** `ai-foundation-models`
**Date:** 2026-06-08
**Question:** Can we replace Claude (via the proxy) with Apple's on-device Foundation Models for the app's AI food features?

## TL;DR verdict

**Partially, as a hybrid — not a full replacement.** Apple's on-device model can plausibly handle the two *text* flows today on Apple-Intelligence devices, but it cannot replace Claude outright because of three hard constraints:

1. **Device coverage** — Foundation Models only runs on Apple-Intelligence-capable devices (iPhone 15 Pro and later) on iOS 26+. Much of our installed base (2,283 registered devices) can't run it, so Claude must stay as the fallback.
2. **Language coverage** — the on-device model supports ~15 languages; **Thai is not among them** (and we *just* shipped Thai localization). Unsupported-language users must fall back to Claude.
3. **Image input** — the shipping (iOS 26) on-device model is **text-only**. Image input was announced today (WWDC 2026) but is an **iOS 27** feature (beta now, GA ~fall 2026). So the two *photo* flows can't go on-device today.

The realistic move is a **router**: prefer on-device when it's available + the language is supported + the flow is supported; otherwise fall back to the existing Claude path. The protocol-driven architecture makes this a clean drop-in.

## The four flows and where each can run

| Flow | Method | Input | On-device today (iOS 26)? |
|------|--------|-------|---------------------------|
| Describe food | `estimate(description:)` | text | ✅ Yes |
| Recipe nutrition | `analyzeRecipe(_:)` | text | ✅ Yes |
| Photo food | `recognize(imageData:hint:)` | image+text | ❌ Needs iOS 27 image input |
| Recipe import | `importRecipe(images:)` | images | ❌ image input (or Vision OCR → on-device text as a stopgap) |

`NutritionAnalysisService` (the history/trends summary) is a separate service on the same proxy/credit stack — out of scope for the first pass, same router pattern applies later.

## The real risk is answer *quality*, not plumbing

The on-device model is ~3B params. Our nutrition estimates lean heavily on **world knowledge** — brand/restaurant macros ("Five Guys Cheeseburger", "Skippy Creamy Peanut Butter", "Chipotle burrito bowl"). The small model is materially weaker than Claude Opus at recalling that. **Plumbing is easy; the open question is whether the numbers are good enough.** This must be answered by an eval before committing, not assumed.

## Why it's still worth doing (the upside)

- **Cost** — every on-device call avoids an Anthropic charge. The proxy budget is deliberately capped (~$30/mo per App Attest key); on-device calls don't count against it and don't burn user credits.
- **Offline + instant** — no network round-trip, no proxy, no App Attest assertion.
- **Privacy** — nothing leaves the device; no consent-to-third-party concern for those calls.
- **No rate limits** — sidesteps the 50/day per-device cap and 429s.

## Architecture: a routing layer, zero view changes

The app already injects a single `FoodRecognitionService` via `FoodRecognitionEnvironment` (`@Environment`). All four call sites go through `env.service`. So we change only the composition root in `CalorieCalcApp.swift`; **no view touches required.**

```
FoodRecognitionService (protocol, unchanged)
├── ClaudeFoodRecognitionService      (existing — the fallback)
├── OnDeviceFoodRecognitionService    (NEW — FoundationModels, @Generable output)
└── RoutingFoodRecognitionService     (NEW — picks per call, falls back on failure)
```

`RoutingFoodRecognitionService` decision per call:
1. Is the flow supported on-device? (text flows now; photo flows gated on iOS 27 availability)
2. Is `SystemLanguageModel.default.availability == .available`? (device capable, AI enabled, model downloaded)
3. Is the user's current language in the supported set? (Thai → no → Claude)
4. User/remote toggle allows on-device?
   → if all yes: try on-device, and on any error **fall back to Claude** (never a worse experience than today).

### On-device structured output

Foundation Models' **guided generation** (`@Generable` structs + `@Guide`) replaces the Claude tool-call JSON contract cleanly — we annotate Swift structs and the model returns them typed. We port the field semantics from `sharedReturnRules` / `logMealTool` into `@Guide` descriptions. One subtlety: the model's ~4k-token context is tight for the long recipe prompts — keep prompts lean.

## Decisions

**Status (2026-06-08): paused at the planning stage — no implementation yet.**

1. **Scope** — *deferred.* When we proceed, start with a throwaway spike (text `estimate` only) to eval quality on ~30 known foods before any router work; it's the cheap go/no-go gate.
2. **Monetization** — **DECIDED: keep credits/ads as-is.** On-device calls will be billed identically to Claude (debit a credit / same paywall + ad-reward flow). Preserves current monetization; revisit only if we later want to make the cheaper path a user perk.
3. **iOS 27 photo path** — *deferred.* Options when we get there: wait for GA (~fall 2026), adopt in beta behind a flag, or do a Vision-OCR-then-on-device stopgap for recipe import.

## Proposed step-by-step (after decisions)

1. **Spike & eval** (½–1 day): minimal `OnDeviceFoodRecognitionService.estimate` with `@Generable`; run a fixed food list head-to-head vs Claude; eyeball macro accuracy. **Go/no-go gate.**
2. If go: flesh out `estimate` + `analyzeRecipe` on-device with full `@Guide` semantics.
3. Add `RoutingFoodRecognitionService` (availability + language + flow + toggle, Claude fallback).
4. Wire router in `CalorieCalcApp.swift`; add a Settings toggle (default on where available).
5. Handle credits/ads per decision #2.
6. Revisit photo flows when iOS 27 image input is GA.

## Sources

- [Foundation Models — Apple Developer Documentation](https://developer.apple.com/documentation/FoundationModels)
- [Apple unveils Xcode and Foundation Models improvements (image input, server execution) — MacRumors, 2026-06-08](https://www.macrumors.com/2026/06/08/apple-unveils-xcode-and-models-improvements/)
- [Updates to Apple's On-Device and Server Foundation Language Models — Apple ML Research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates)
- [Supporting languages and locales with Foundation Models — Apple Developer Documentation](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
- [Exploring Foundation Models: Supported Languages — Rudrank Riyam](https://rudrank.com/exploring-foundation-models-supported-languages-internationalization)
