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

const handler: PagesFunction<Env> = async (context) => {
  const { path } = context.params
  const name = Array.isArray(path) ? path.join('/') : (path ?? '')

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

export const onRequestGet = handler
// Download clients commonly probe with HEAD first. Without this the probe
// falls through to the static 404 page and reports the wrong size and type.
export const onRequestHead = handler
