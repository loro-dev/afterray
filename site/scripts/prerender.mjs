// Bakes every public route and the sitemap into dist so crawlers and readers
// receive the full page before JavaScript runs.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import path from 'node:path'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const indexPath = path.join(root, 'dist/index.html')
const ssrEntry = path.join(root, 'dist-ssr/entry-server.js')
const template = readFileSync(indexPath, 'utf8')
const target = '<div id="root"></div>'
const headPattern = /<!-- seo-head:start -->[\s\S]*<!-- seo-head:end -->/

if (!template.includes(target)) {
  throw new Error(`prerender could not find ${target} in dist/index.html`)
}
if (!headPattern.test(template)) {
  throw new Error('prerender could not find the SEO head markers in dist/index.html')
}

const { prerenderPaths, render } = await import(pathToFileURL(ssrEntry).href)
const origin = 'https://afterray.com'

const escapeHtml = (value) => value
  .replaceAll('&', '&amp;')
  .replaceAll('"', '&quot;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')

const absolute = (pathname) => new URL(pathname, origin).href

function structuredData(route, alternates) {
  const canonical = absolute(route.path)
  const graph = [
    {
      '@type': 'WebSite',
      '@id': `${origin}/#website`,
      name: 'AfterRay',
      url: `${origin}/`,
      inLanguage: alternates.localized.map((alternate) => alternate.hreflang),
    },
    {
      '@type': 'WebPage',
      '@id': `${canonical}#webpage`,
      url: canonical,
      name: route.title,
      description: route.description,
      inLanguage: route.htmlLang,
      isPartOf: { '@id': `${origin}/#website` },
    },
  ]

  if (route.page === 'home') {
    graph.push({
      '@type': 'SoftwareApplication',
      '@id': `${origin}/#app`,
      name: 'AfterRay',
      url: `${origin}/`,
      downloadUrl: `${origin}/download/latest`,
      image: `${origin}/og.png`,
      applicationCategory: 'UtilitiesApplication',
      operatingSystem: 'macOS 15 or later, Apple Silicon',
      description: route.description,
      license: 'https://github.com/loro-dev/afterray/blob/main/LICENSE',
      featureList: route.featureList,
      isPartOf: { '@id': `${origin}/#website` },
    })
  }

  return JSON.stringify({ '@context': 'https://schema.org', '@graph': graph })
    .replaceAll('<', '\\u003c')
}

function seoHead(route, alternates) {
  const canonical = absolute(route.path)
  const title = escapeHtml(route.title)
  const description = escapeHtml(route.description)
  const languageLinks = alternates.localized
    .map((alternate) => `    <link rel="alternate" hreflang="${alternate.hreflang}" href="${absolute(alternate.path)}" />`)
    .join('\n')
  const alternateLocales = alternates.localized
    .filter((alternate) => alternate.ogLocale !== route.ogLocale)
    .map((alternate) => `    <meta property="og:locale:alternate" content="${alternate.ogLocale}" />`)
    .join('\n')

  return `<!-- seo-head:start -->
    <meta name="description" content="${description}" />
    <title>${title}</title>
    <link rel="canonical" href="${canonical}" />
${languageLinks}
    <link rel="alternate" hreflang="x-default" href="${absolute(alternates.xDefault)}" />
    <meta property="og:url" content="${canonical}" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="AfterRay" />
    <meta property="og:locale" content="${route.ogLocale}" />
${alternateLocales}
    <meta property="og:title" content="${title}" />
    <meta property="og:description" content="${description}" />
    <meta property="og:image" content="${origin}/og.png" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:alt" content="${escapeHtml(route.imageAlt)}" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${title}" />
    <meta name="twitter:description" content="${description}" />
    <meta name="twitter:image" content="${origin}/og.png" />
    <script type="application/ld+json">${structuredData(route, alternates)}</script>
    <!-- seo-head:end -->`
}

function count(text, pattern) {
  return [...text.matchAll(pattern)].length
}

function validateHtml(html, route, alternates) {
  const canonical = absolute(route.path)
  const required = [
    `<html lang="${route.htmlLang}">`,
    `<title>${escapeHtml(route.title)}</title>`,
    `<link rel="canonical" href="${canonical}" />`,
    `hreflang="x-default" href="${absolute(alternates.xDefault)}"`,
    '<script type="application/ld+json">',
    '<link rel="icon" type="image/png" sizes="64x64" href="/favicon.png" />',
  ]
  for (const alternate of alternates.localized) {
    required.push(
      `hreflang="${alternate.hreflang}" href="${absolute(alternate.path)}"`,
      `href="${alternate.path}"`,
    )
  }
  for (const fragment of required) {
    if (!html.includes(fragment)) {
      throw new Error(`prerendered ${route.path} is missing ${fragment}`)
    }
  }
  if (count(html, /<h1(?:\s|>)/g) !== 1) {
    throw new Error(`prerendered ${route.path} must contain exactly one h1`)
  }
  if (count(html, /rel="canonical"/g) !== 1) {
    throw new Error(`prerendered ${route.path} must contain exactly one canonical`)
  }

  const jsonLd = html.match(/<script type="application\/ld\+json">([^<]+)<\/script>/)?.[1]
  if (!jsonLd) throw new Error(`prerendered ${route.path} has no JSON-LD payload`)
  JSON.parse(jsonLd)
}

let totalBytes = 0
const titles = new Set()
const renderedRoutes = []
for (const pathname of prerenderPaths) {
  const { markup, route, alternates } = render(pathname)
  if (!markup.trim()) throw new Error(`prerender produced empty markup for ${pathname}`)

  const html = template
    .replace('<html lang="en">', `<html lang="${route.htmlLang}">`)
    .replace(headPattern, seoHead(route, alternates))
    .replace(target, `<div id="root">${markup}</div>`)

  validateHtml(html, route, alternates)
  if (titles.has(route.title)) throw new Error(`duplicate page title: ${route.title}`)
  titles.add(route.title)

  const output = pathname === '/'
    ? indexPath
    : path.join(root, 'dist', pathname.slice(1), 'index.html')
  mkdirSync(path.dirname(output), { recursive: true })
  writeFileSync(output, html)
  totalBytes += Buffer.byteLength(markup)
  renderedRoutes.push({ route, alternates })
}

const sitemapEntries = renderedRoutes.map(({ route, alternates }) => {
  const languageLinks = alternates.localized
    .map((alternate) => `    <xhtml:link rel="alternate" hreflang="${alternate.hreflang}" href="${absolute(alternate.path)}" />`)
    .join('\n')
  return `  <url>
    <loc>${absolute(route.path)}</loc>
${languageLinks}
    <xhtml:link rel="alternate" hreflang="x-default" href="${absolute(alternates.xDefault)}" />
  </url>`
}).join('\n')
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:xhtml="http://www.w3.org/1999/xhtml">
${sitemapEntries}
</urlset>
`

if (count(sitemap, /<loc>/g) !== prerenderPaths.length) {
  throw new Error('sitemap URL count does not match the prerendered route count')
}
for (const pathname of prerenderPaths) {
  if (!sitemap.includes(`<loc>${absolute(pathname)}</loc>`)) {
    throw new Error(`sitemap is missing ${absolute(pathname)}`)
  }
}
writeFileSync(path.join(root, 'dist/sitemap.xml'), sitemap)

rmSync(path.join(root, 'dist-ssr'), { recursive: true, force: true })

const kb = (totalBytes / 1024).toFixed(1)
console.log(`prerendered ${prerenderPaths.length} routes (${kb} kB of markup)`)
