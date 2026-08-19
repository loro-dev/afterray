# L10n — UI chrome i18n

Typed catalogs (`AfterRayCopy`) for `en` / `zh-Hans` / `zh-Hant` / `ja` / `ko` / `es` / `de` / `fr`. `ui_language=auto` follows `Locale.preferredLanguages` (`AfterRayUILanguage.match`); zh-TW/HK/MO → zh-Hant, other zh → zh-Hans. Summary *output* is a separate 17-language daemon catalogue (`summary_language`) — do not conflate the two.

## Completeness (required)

Catalog complete ≠ chrome complete. A user-facing string is unfinished until **all** of:

1. A field on `AfterRayCopy` (compile error until every `AfterRayCopy+*.swift` fills it).
2. Every live path that shows it reads the catalog: `Text`, `.help`, `.accessibilityLabel` / Hint, menu titles, alerts, recorder placeholders, download-queue labels. Hardcoded English (or a one-off Chinese string) in a shipped view is a miss.
3. The call site is actually wired. Model/API types keep an English default (`title` → `title(.english)`) so XCTest pins do not churn; the UI **must** call `title(copy)` / `stageLabel(copy)` / `message(copy)` / `systemConflictNote(copy)`.
4. Host views that draw chrome themselves use `@ObservedObject AfterRayLocalization.shared`, **or** `.afterRayLocalized()` is on the `NSHostingView` root. `.afterRayLocalized()` feeds *children*, not the view it is attached to; `@Environment(\.afterRayCopy)` at an `NSHostingView` root stays English.

Visual Lab / snapshot tooling may stay English. Shipped app, overlay, settings, onboarding, chat, compute, permissions, CLI status, and the hotkey recorder must not.

New chrome uses Apple system terms where they exist (聚焦 / Spotlight, 输入法 / 輸入方式 / 入力ソース / Eingabequellen, 热压力, Auslastung, 转录 not 转写).

## Adding a string or language

- String: field + all eight catalogs + wire the call site in the same change.
- Language: `AfterRayUILanguage` case, `AfterRayCopy+xx.swift`, `Info.plist` `CFBundleLocalizations`, `apps/AfterRay/Resources/<loc>.lproj/InfoPlist.strings`, and the locale loops in `scripts/build-release.sh` / `scripts/run-v0.sh`.

## Key files

- `AfterRayCopy.swift` — field list (adding one is a compile error until every locale fills it)
- `AfterRayCopy+*.swift` — one file per shipped locale
- `AfterRayUILanguage.swift` — `resolve` / `match`
- `AfterRayLocalization.swift` — process-wide `shared`, `.afterRayLocalized()`
