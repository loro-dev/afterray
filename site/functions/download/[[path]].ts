/// <reference types="@cloudflare/workers-types" />

/**
 * Serves release artifacts out of R2: the zip Sparkle downloads to update an
 * installed copy, and the DMG a new user gets from the site.
 */

interface Env {
  RELEASES: R2Bucket
}

/** Only ever the artifacts, never the release index that sits beside them. */
const ARTIFACT_PREFIX = 'artifacts/'
const ARTIFACT_PATTERN = /^AfterRay-[0-9A-Za-z._-]+\.(zip|dmg)$/
const INDEX_KEY = 'releases.json'

interface ReleaseIndex {
  releases: { build: string; installer?: string }[]
}

const handler: PagesFunction<Env> = async (context) => {
  const { path } = context.params
  const name = Array.isArray(path) ? path.join('/') : (path ?? '')

  // @dec:indexable-locale-urls — docs/decisions/active/product/2026-08-20-indexable-locale-urls.md
  if (name === '') {
    return context.next()
  }

  // The site links here so its download button never names a version, and a
  // release becomes downloadable by being uploaded rather than deployed.
  if (name === 'latest' || name === 'latest.dmg') {
    return redirectToLatestInstaller(context)
  }

  if (!ARTIFACT_PATTERN.test(name)) {
    return new Response('Not found', { status: 404 })
  }

  const isProbe = context.request.method === 'HEAD'
  const object = isProbe
    ? await context.env.RELEASES.head(ARTIFACT_PREFIX + name)
    : await context.env.RELEASES.get(ARTIFACT_PREFIX + name)
  if (object === null) {
    return new Response('Not found', { status: 404 })
  }

  const headers = new Headers({
    'Content-Type': name.endsWith('.dmg')
      ? 'application/x-apple-diskimage'
      : 'application/zip',
    'Content-Length': String(object.size),
    // Artifact names carry their version, so a given name never changes
    // content and can be cached indefinitely.
    'Cache-Control': 'public, max-age=31536000, immutable',
    'Content-Disposition': `attachment; filename="${name}"`,
    'X-Content-Type-Options': 'nosniff',
  })
  if (object.httpEtag) {
    headers.set('ETag', object.httpEtag)
  }

  if (isProbe) {
    return new Response(null, { headers })
  }
  return new Response((object as R2ObjectBody).body, { headers })
}

async function redirectToLatestInstaller(
  context: Parameters<PagesFunction<Env>>[0],
): Promise<Response> {
  const object = await context.env.RELEASES.get(INDEX_KEY)
  if (object === null) {
    return new Response('No releases have been published yet.', {
      status: 404,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    })
  }

  const { releases } = await object.json<ReleaseIndex>()
  const newest = releases
    .filter((release) => release.installer !== undefined)
    .sort((a, b) => Number(b.build) - Number(a.build))[0]
  if (newest?.installer === undefined) {
    return new Response('No installer has been published yet.', {
      status: 404,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    })
  }

  const origin = new URL(context.request.url).origin
  return new Response(null, {
    status: 302,
    headers: {
      Location: `${origin}/download/${encodeURIComponent(newest.installer)}`,
      // The target moves with every release, so this must not be cached.
      'Cache-Control': 'no-cache',
    },
  })
}

export const onRequestGet = handler
// Download clients commonly probe with HEAD first. Without this the probe
// falls through to the static 404 page and reports the wrong size and type.
export const onRequestHead = handler
