# Decision: Every website locale has a stable, prerendered URL

Status: active
Area: release
Anchors:
- site/src/routes.ts @dec:indexable-locale-urls
- site/functions/download/[[path]].ts @dec:indexable-locale-urls
Supersedes: —
Superseded-by: —

## Problem

Crawlers cannot discover, identify, or link to localized documents when language is only React state on a single URL. The site also needs durable URLs for information that does not belong in one long landing page, and its locale set should match the eight languages offered by the macOS app.

## Decision

Each supported language and public information page has a stable, statically prerendered URL. The existing root URL is the English and `x-default` homepage. Simplified Chinese stays below `/zh/`; Traditional Chinese, Japanese, Korean, Spanish, German, and French use `/zh-hant/`, `/ja/`, `/ko/`, `/es/`, `/de/`, and `/fr/`. Privacy, security, and download information use matching paths in every locale. Every page has a self-referencing canonical, reciprocal `hreflang` links, and crawlable language and footer navigation. The sitemap is generated from the same route table so locale coverage cannot drift independently.

## Alternatives considered

**Keep all languages on one URL and switch with JavaScript or local storage.** This preserves the old interaction but gives crawlers no stable localized document and gives readers no localized URL to share.

**Move English to `/en/` and make `/` a redirect or language chooser.** This makes the language paths symmetrical but changes the established homepage canonical and adds a redirect to the main acquisition path.

**Use query parameters such as `?lang=zh`.** This creates linkable variants but is easier to duplicate or strip, and it is less clear than a dedicated language path in analytics, sitemaps, and internal links.

## Consequences

The root canonical stays stable while every locale becomes independently crawlable and shareable without JavaScript. The build produces and validates 32 localized HTML documents. Copy and metadata still require human translation, while the type system and prerender build keep routes, `hreflang`, sitemap entries, and language navigation structurally aligned.
