/// <reference types="@cloudflare/workers-types" />

/**
 * The Sparkle feed every installed copy of AfterRay polls.
 *
 * It is generated from an index in R2 rather than served as a static file so
 * that publishing a release is an upload, not a site deploy — the two have
 * very different failure modes, and a release should not be able to break the
 * marketing page.
 */

interface Env {
  RELEASES: R2Bucket
}

interface ReleaseRecord {
  /** Marketing version, e.g. "0.0.2". */
  version: string
  /** CFBundleVersion. Sparkle compares this, and only this. */
  build: string
  minimumSystemVersion: string
  /** File name under the artifacts/ prefix in R2. */
  archive: string
  length: number
  edSignature: string
  publishedAt: string
  criticalUpdate?: boolean
  releaseNotesUrl?: string
}

interface ReleaseIndex {
  releases: ReleaseRecord[]
}

const INDEX_KEY = 'releases.json'

export const onRequestGet: PagesFunction<Env> = async (context) => {
  const object = await context.env.RELEASES.get(INDEX_KEY)
  if (object === null) {
    return new Response('No releases have been published yet.', {
      status: 404,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    })
  }

  const index = await object.json<ReleaseIndex>()
  const origin = new URL(context.request.url).origin
  const items = [...index.releases]
    .sort((a, b) => Number(b.build) - Number(a.build))
    .map((release) => renderItem(release, origin))
    .join('\n')

  const feed = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AfterRay</title>
    <link>${origin}/appcast.xml</link>
    <description>Updates for AfterRay.</description>
    <language>en</language>
${items}
  </channel>
</rss>
`

  return new Response(feed, {
    headers: {
      'Content-Type': 'application/xml; charset=utf-8',
      // Short enough that a release reaches people the same day, long enough
      // that the feed is not re-rendered for every launch of every install.
      'Cache-Control': 'public, max-age=300',
      'X-Content-Type-Options': 'nosniff',
    },
  })
}

function renderItem(release: ReleaseRecord, origin: string): string {
  const url = `${origin}/download/${encodeURIComponent(release.archive)}`
  const lines = [
    '    <item>',
    `      <title>${escapeXml(release.version)}</title>`,
    `      <pubDate>${escapeXml(toRfc822(release.publishedAt))}</pubDate>`,
    `      <sparkle:version>${escapeXml(release.build)}</sparkle:version>`,
    `      <sparkle:shortVersionString>${escapeXml(release.version)}</sparkle:shortVersionString>`,
    `      <sparkle:minimumSystemVersion>${escapeXml(release.minimumSystemVersion)}</sparkle:minimumSystemVersion>`,
  ]
  if (release.criticalUpdate === true) {
    lines.push('      <sparkle:criticalUpdate/>')
  }
  if (release.releaseNotesUrl !== undefined) {
    lines.push(`      <sparkle:releaseNotesLink>${escapeXml(release.releaseNotesUrl)}</sparkle:releaseNotesLink>`)
  }
  lines.push(
    `      <enclosure url="${escapeXml(url)}" length="${release.length}" ` +
      `type="application/octet-stream" sparkle:edSignature="${escapeXml(release.edSignature)}"/>`,
    '    </item>',
  )
  return lines.join('\n')
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

function toRfc822(iso: string): string {
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toUTCString()
}
