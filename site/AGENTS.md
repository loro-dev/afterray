# AGENTS.md — site/

afterray.com: a React 19 + Vite 6 + TypeScript static site on Cloudflare Pages, plus Pages Functions that serve the Sparkle appcast and release downloads from the R2 bucket `afterray-releases`. Releases ship by uploading to R2 (`scripts/publish-release.sh`), never by redeploying the site.

## Layout

- `src/` — the site itself. `src/i18n.tsx` defines the locale catalog and English/Simplified Chinese copy; `src/extraLocales.ts` holds Traditional Chinese, Japanese, Korean, Spanish, German, and French copy.
- `src/routes.ts` defines every indexable locale/page URL; `src/entry-server.tsx` + `scripts/prerender.mjs` bake each route into `dist/<path>/index.html` at build time with route-specific metadata. The build fails if any prerendered markup is empty.
- `functions/appcast.xml.ts` — Sparkle feed generated from R2 `releases.json`; `Cache-Control: max-age=300`.
- `functions/download/[[path]].ts` — serves `artifacts/*` from R2 with immutable caching; `/download/latest` 302-redirects (`no-cache`) to the newest installer.
- `wrangler.jsonc` — Pages project `afterray`, R2 binding `RELEASES` → bucket `afterray-releases`.
- `public/_headers` — caching/security headers (see invariants).
- `scripts/usage.mjs` — reads usage off Cloudflare's edge logs; see [Usage numbers](#usage-numbers).

## Commands

- `npm run dev` — Vite dev server.
- `npm run build` — `tsc -b` (typechecks app + functions) + `vite build` + SSR build + prerender.
- `npm run deploy` / `npm run deploy:preview` — build + `wrangler pages deploy` (`--branch preview`).
- `npm run usage -- [--days 30] [--json] [--introspect]` — usage report; reads
  `CLOUDFLARE_API_TOKEN` from the environment or from gitignored `site/.env`.

## Usage numbers

The app ships **no telemetry** and must keep shipping none — `src/i18n.tsx` sells
"no account, no telemetry, no cloud sync" across the locale catalog. Do not add a device
id, install id, or stats ping without changing that copy first; it is a product
promise, not an oversight.

Usage is read from Cloudflare's edge log instead: every install polls
`/appcast.xml` daily, so `scripts/usage.mjs` counts that path and reads the
version spread out of Sparkle's User-Agent. Raw counts include a lot of bot
traffic, the Free plan retains only 8 days, and one download click logs as two
requests — [context/usage-analytics.md](../context/usage-analytics.md) has the
full set of traps before you trust or extend a number.

## Invariants

- Site code links `/download/latest`, never a versioned filename; artifact URLs in R2 are content-stable and immutable-cached.
- English lives at `/`; Simplified Chinese stays at `/zh/`; Traditional Chinese, Japanese, Korean, Spanish, German, and French use `/zh-hant/`, `/ja/`, `/ko/`, `/es/`, `/de/`, and `/fr/`. Every public information page is prerendered for all eight locales with self-canonicals and reciprocal `hreflang` links. Add or remove a locale in `src/i18n.tsx` (`LANGS`), `src/extraLocales.ts` (or the en/zh-Hans blocks), `src/routes.ts` (SEO), `src/pages/InfoPage.tsx`, and `src/App.tsx` footer labels; `scripts/prerender.mjs` derives both pages and `dist/sitemap.xml` from `src/routes.ts`.
- `/assets/*` is Vite-fingerprinted → cache forever; files in `public/` keep stable names and must stay revalidatable (`_headers` — `og.png` especially, or a social-card fix would take a year to propagate).
- `functions/*.ts` typechecks under `tsconfig.functions.json` with `erasableSyntaxOnly` — no TS enums or namespaces in functions.
- The appcast is a Function reading R2, not a static file in `public/`; publishing a release never touches or redeploys the site.
