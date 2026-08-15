# AGENTS.md — site/

afterray.com: a React 19 + Vite 6 + TypeScript static site on Cloudflare Pages, plus Pages Functions that serve the Sparkle appcast and release downloads from the R2 bucket `afterray-releases`. Releases ship by uploading to R2 (`scripts/publish-release.sh`), never by redeploying the site.

## Layout

- `src/` — the site itself. `src/i18n.tsx` holds both locales (`en`, `zh`); adding a language = a `LANGS` entry + a `copy` block (i18n.tsx:15).
- `src/entry-server.tsx` + `scripts/prerender.mjs` — SSR prerender baked into `dist/index.html` at build time; the build fails if the prerendered markup is empty.
- `functions/appcast.xml.ts` — Sparkle feed generated from R2 `releases.json`; `Cache-Control: max-age=300`.
- `functions/download/[[path]].ts` — serves `artifacts/*` from R2 with immutable caching; `/download/latest` 302-redirects (`no-cache`) to the newest installer.
- `wrangler.jsonc` — Pages project `afterray`, R2 binding `RELEASES` → bucket `afterray-releases`.
- `public/_headers` — caching/security headers (see invariants).

## Commands

- `npm run dev` — Vite dev server.
- `npm run build` — `tsc -b` (typechecks app + functions) + `vite build` + SSR build + prerender.
- `npm run deploy` / `npm run deploy:preview` — build + `wrangler pages deploy` (`--branch preview`).

## Invariants

- Site code links `/download/latest`, never a versioned filename; artifact URLs in R2 are content-stable and immutable-cached.
- `/assets/*` is Vite-fingerprinted → cache forever; files in `public/` keep stable names and must stay revalidatable (`_headers` — `og.png` especially, or a social-card fix would take a year to propagate).
- `functions/*.ts` typechecks under `tsconfig.functions.json` with `erasableSyntaxOnly` — no TS enums or namespaces in functions.
- The appcast is a Function reading R2, not a static file in `public/`; publishing a release never touches or redeploys the site.
