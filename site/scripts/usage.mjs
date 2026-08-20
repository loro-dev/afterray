// Rough usage numbers from Cloudflare's edge logs — no client-side telemetry.
//
// Every installed copy polls /appcast.xml once a day (SUScheduledCheckInterval
// in apps/AfterRay/Resources/Info.plist is 86400), so the daily request count
// for that path is a usable proxy for daily actives. It is not a unique-device
// count: NAT, multiple Macs, and machines that boot several times a day all
// blur it. Read the trend, not the absolute number.
//
// Sparkle's User-Agent carries the app version, so the same dataset also gives
// the version spread — how many people are stuck on an old build.
//
// Usage:
//   node scripts/usage.mjs [--days 30] [--json]
//   node scripts/usage.mjs --introspect
//
// The token comes from AFTERRAY_USAGE_ANALYTICS_KEY or CLOUDFLARE_API_TOKEN, in
// the environment or in site/.env (gitignored), so it never has to reach a shell
// history. It needs Zone → Analytics → Read on afterray.com — and the Zone
// Resources must name afterray.com, not the similar-looking afteray.com that
// also sits on this account. Set CLOUDFLARE_ZONE_ID to skip the zone lookup,
// which is the only thing that also wants Zone → Zone → Read.

import path from 'node:path'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const API = 'https://api.cloudflare.com/client/v4'
const APPCAST_PATH = '/appcast.xml'
/** Sparkle sends "AfterRay/0.0.5 Sparkle/2.9.5"; nothing else does. */
const APP_AGENT = /AfterRay\/([\w.\-+]+)/i
/** Cloudflare's Early Hints prefetcher: edge infrastructure, not traffic. */
const INTERNAL_PROBE = /nginx-ssl early hints/i

const TOKEN_VARS = ['AFTERRAY_USAGE_ANALYTICS_KEY', 'CLOUDFLARE_API_TOKEN']
const readToken = () => TOKEN_VARS.map((name) => process.env[name]).find(Boolean)

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const envFile = path.join(root, '.env')
// A real environment variable wins: .env is the convenience, not the authority.
if (!readToken() && existsSync(envFile)) {
  process.loadEnvFile(envFile)
}

const ZONE_NAME = process.env.CLOUDFLARE_ZONE_NAME ?? 'afterray.com'
const token = readToken()
if (!token) {
  fail(
    `no token found in ${TOKEN_VARS.join(' or ')}.\n` +
      'Create one with Zone → Analytics → Read on afterray.com, then either export\n' +
      `it or put it in ${envFile} (gitignored).`,
  )
}

const args = process.argv.slice(2)
const asJson = args.includes('--json')
// The Free plan retains adaptive data for 1w1d, so 30 days is not a longer
// report — it is an error. Default to the widest window that actually works.
const DEFAULT_DAYS = 7
const days = readNumberFlag(args, '--days', DEFAULT_DAYS)

if (args.includes('--introspect')) {
  await introspect()
} else {
  await report()
}

async function report() {
  const zoneTag = await resolveZoneTag()
  // One request per day, because httpRequestsAdaptiveGroups on the Free plan
  // rejects any query spanning more than 1d. The whole point of this script is
  // a multi-day trend, so the loop is not an optimisation to remove later.
  // 30 requests sits comfortably under the 300-per-5-minutes quota.
  const dates = Array.from({ length: days }, (_, i) => isoDate(-(days - 1 - i)))

  // `_like` is not offered on every plan and would fail the whole day's query,
  // so its availability is settled once against the oldest day rather than
  // risked 30 times.
  const wantsDownloads = await supportsPathPrefix(zoneTag, dates[0])
  const perDay = await mapWithConcurrency(dates, 6, (date) =>
    fetchDay(zoneTag, date, wantsDownloads),
  )

  if (asJson) {
    console.log(JSON.stringify(perDay, null, 2))
    return
  }

  // Bots, Googlebot and our own curl probes all hit /appcast.xml, and at this
  // traffic level they outnumber the app. Sparkle's User-Agent is the only
  // reliable way to tell an install apart from everything else.
  const daily = perDay.map((day) => ({ date: day.date, count: countApp(day.agents) }))
  const noise = perDay.reduce((sum, day) => sum + day.checks - countApp(day.agents), 0)

  console.log(`\nUpdate checks on ${APPCAST_PATH} — last ${days} days`)
  console.log('(Sparkle User-Agents only — one check per install per day.')
  console.log(' A proxy for daily actives, not a unique-device count.)\n')
  printSeries(daily)
  if (noise > 0) {
    console.log(`\n  excluded ${noise} non-app requests (bots, crawlers, curl probes)`)
  }

  if (daily.length > 1) {
    // Drop the final day: it is still in progress and would drag the mean down.
    const settled = daily.slice(-8, -1).map((row) => row.count)
    const mean = settled.reduce((a, b) => a + b, 0) / settled.length
    console.log(`\n  7-day mean (excluding today): ${Math.round(mean)}`)
  }

  const versions = collapseVersions(perDay.flatMap((day) => day.agents))
  if (versions.length > 0) {
    console.log(`\nVersion spread over the same window\n`)
    const total = versions.reduce((sum, v) => sum + v.count, 0)
    for (const { label, count } of versions.slice(0, 12)) {
      const share = ((count / total) * 100).toFixed(1).padStart(5)
      console.log(`  ${label.padEnd(28)} ${String(count).padStart(8)}  ${share}%`)
    }
  }

  if (wantsDownloads) {
    const { installers, updates, artifacts } = classifyDownloads(
      perDay.flatMap((day) => day.downloads),
    )
    // Cloudflare's own Early Hints prefetcher hammers /download/latest and is
    // the only thing that ever gets a 504 from it. Counting it as a user would
    // both inflate clicks and invent a ~50% failure rate nobody experiences.
    const all = perDay.flatMap((day) => day.clicks)
    const clicks = all.filter((row) => !INTERNAL_PROBE.test(row.dimensions.userAgent ?? ''))
    // Sum the counts, not the rows: a day of probes collapses into one row.
    const probes = all
      .filter((row) => INTERNAL_PROBE.test(row.dimensions.userAgent ?? ''))
      .reduce((sum, row) => sum + row.count, 0)
    const ok = sumWhere(clicks, (status) => status < 400)
    const failed = sumWhere(clicks, (status) => status >= 400)

    console.log('\nDownloads over the same window\n')
    console.log(`  ${'Download button clicks'.padEnd(28)} ${String(ok + failed).padStart(8)}`)
    if (failed > 0) {
      const codes = [...new Set(clicks.filter((r) => r.dimensions.edgeResponseStatus >= 400)
        .map((r) => r.dimensions.edgeResponseStatus))].sort().join(', ')
      console.log(`  ${'  → failed'.padEnd(28)} ${String(failed).padStart(8)}  (${codes})`)
    }
    console.log(`  ${'Installers served (.dmg)'.padEnd(28)} ${String(installers).padStart(8)}`)
    console.log(`  ${'Sparkle updates (.zip)'.padEnd(28)} ${String(updates).padStart(8)}`)
    if (probes > 0) {
      console.log(`\n  excluded ${probes} Cloudflare Early Hints probes (they 504 and are not users)`)
    }
    if (artifacts.length > 0) {
      console.log('\n  by artifact\n')
      for (const { name, count } of artifacts.slice(0, 12)) {
        console.log(`    ${name.padEnd(34)} ${String(count).padStart(6)}`)
      }
    }
  }
  console.log('')
}

/** Appcast hits, their User-Agents, and optionally downloads, for one day. */
async function fetchDay(zoneTag, date, wantsDownloads) {
  const day = `date: "${date}"`
  // Grouped by path so the three very different things under /download/ can be
  // told apart, and restricted to GET 200: a HEAD probe is not a download, and
  // a 206 is one download arriving in many range requests.
  const downloads = wantsDownloads
    ? `downloads: httpRequestsAdaptiveGroups(
         filter: {
           ${day}, clientRequestPath_like: "/download/%"
           clientRequestHTTPMethodName: "GET", edgeResponseStatus: 200
         }
         limit: 100
         orderBy: [count_DESC]
       ) {
         count
         dimensions { clientRequestPath }
       }
       clicks: httpRequestsAdaptiveGroups(
         filter: {
           ${day}, clientRequestPath_like: "/download/latest%"
           clientRequestHTTPMethodName: "GET"
         }
         limit: 50
         orderBy: [count_DESC]
       ) {
         count
         dimensions { edgeResponseStatus userAgent }
       }`
    : ''
  const data = await graphql(`query {
    viewer {
      zones(filter: { zoneTag: "${zoneTag}" }) {
        checks: httpRequestsAdaptiveGroups(
          filter: { ${day}, clientRequestPath: "${APPCAST_PATH}" }
          limit: 1
        ) { count }
        agents: httpRequestsAdaptiveGroups(
          filter: { ${day}, clientRequestPath: "${APPCAST_PATH}" }
          limit: 100
          orderBy: [count_DESC]
        ) {
          count
          dimensions { userAgent }
        }
        ${downloads}
      }
    }
  }`)

  const zone = data.viewer.zones[0] ?? {}
  return {
    date,
    checks: zone.checks?.[0]?.count ?? 0,
    agents: zone.agents ?? [],
    downloads: zone.downloads ?? [],
    // Counted separately because /download/latest answers 302, which the
    // artifact query filters out along with HEAD probes and range requests.
    // Kept per-status: this route times out often enough that the failure rate
    // is the more useful of the two numbers.
    clicks: zone.clicks ?? [],
  }
}

/**
 * `/download/latest` is a 302 to a versioned name, so a single click on the
 * site's button shows up twice: once as the redirect and once as the .dmg it
 * lands on. Counting the two separately keeps "people who clicked download"
 * apart from "installers actually transferred", and .zip apart from both —
 * those are Sparkle updating an existing install, not a new one.
 */
function classifyDownloads(rows) {
  const totals = { installers: 0, updates: 0 }
  const byArtifact = new Map()
  for (const row of rows) {
    const path = row.dimensions.clientRequestPath ?? ''
    if (path.endsWith('.dmg')) totals.installers += row.count
    else if (path.endsWith('.zip')) totals.updates += row.count
    else continue
    const name = path.replace('/download/', '')
    byArtifact.set(name, (byArtifact.get(name) ?? 0) + row.count)
  }
  const artifacts = [...byArtifact]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count)
  return { ...totals, artifacts }
}

async function supportsPathPrefix(zoneTag, date) {
  const data = await graphqlOptional(`query {
    viewer {
      zones(filter: { zoneTag: "${zoneTag}" }) {
        httpRequestsAdaptiveGroups(
          filter: { date: "${date}", clientRequestPath_like: "/download/%" }
          limit: 1
        ) { count }
      }
    }
  }`)
  return data !== null
}

function sumWhere(rows, predicate) {
  return rows
    .filter((row) => predicate(row.dimensions.edgeResponseStatus))
    .reduce((sum, row) => sum + row.count, 0)
}

/** Bounded fan-out: 30 days at once is fine for us, less so for the quota. */
async function mapWithConcurrency(items, limit, work) {
  const results = new Array(items.length)
  let next = 0
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++
      results[index] = await work(items[index])
    }
  })
  await Promise.all(workers)
  return results
}

function printSeries(rows) {
  if (rows.length === 0) {
    console.log('  no data in this window')
    return
  }
  const peak = Math.max(...rows.map((r) => r.count), 1)
  for (const row of rows) {
    // A zero day draws nothing; rounding it up to one block reads as traffic.
    const bar = row.count === 0 ? '' : '█'.repeat(Math.max(1, Math.round((row.count / peak) * 40)))
    console.log(`  ${row.date}  ${String(row.count).padStart(7)}  ${bar}`)
  }
}

function countApp(rows) {
  return rows
    .filter((row) => APP_AGENT.test(row.dimensions.userAgent ?? ''))
    .reduce((sum, row) => sum + row.count, 0)
}

/**
 * Collapse to the app version so the table is a version histogram and not a
 * Sparkle-build one. Non-app agents are dropped rather than bucketed: they are
 * counted once, as noise, next to the series.
 */
function collapseVersions(rows) {
  const byLabel = new Map()
  for (const row of rows) {
    const match = APP_AGENT.exec(row.dimensions.userAgent ?? '')
    if (match === null) continue
    const label = `AfterRay ${match[1]}`
    byLabel.set(label, (byLabel.get(label) ?? 0) + row.count)
  }
  return [...byLabel].map(([label, count]) => ({ label, count })).sort((a, b) => b.count - a.count)
}

async function resolveZoneTag() {
  const configured = process.env.CLOUDFLARE_ZONE_ID
  if (configured) {
    // The tag is interpolated into the query text, so reject anything that is
    // not the hex id Cloudflare issues.
    if (!/^[0-9a-f]{32}$/i.test(configured)) fail('CLOUDFLARE_ZONE_ID is not a 32-character hex id')
    return configured
  }

  // Listed unfiltered rather than with ?name=: filtering server-side returns an
  // empty list for a mis-scoped token, which is indistinguishable from a broken
  // one. Matching locally means the failure can name what the token *can* see.
  const response = await fetch(`${API}/zones?per_page=50`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  const body = await response.json()
  if (!response.ok || body.success !== true) {
    fail(
      `could not look up the zone for ${ZONE_NAME}: ${describeErrors(body.errors)}\n` +
        'Set CLOUDFLARE_ZONE_ID directly if the token lacks Zone → Zone → Read.',
    )
  }
  // A token scoped to the wrong zone gets an empty list, not an error — and
  // "afteray.com" (one r) is a real zone on this account, so the failure looks
  // like a broken token rather than a mis-scoped one. Name what it can see.
  const zone = body.result?.find((candidate) => candidate.name === ZONE_NAME)
  if (!zone) {
    const visible = (body.result ?? []).map((z) => z.name)
    fail(
      `this token cannot see a zone named ${ZONE_NAME}.\n` +
        (visible.length > 0
          ? `It can see: ${visible.join(', ')}\nCheck the token's Zone Resources — it is probably scoped to the wrong zone.`
          : 'It can see no zones at all. Check the token has Zone → Zone → Read, or set CLOUDFLARE_ZONE_ID.'),
    )
  }
  return zone.id
}

async function graphql(query, variables) {
  const response = await fetch(`${API}/graphql`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query, variables }),
  })
  const body = await response.json()
  // GraphQL reports schema mismatches with a 200 and a populated errors array,
  // so status alone never tells you the query was accepted.
  if (!response.ok || (body.errors && body.errors.length > 0)) {
    const detail = describeErrors(body.errors)
    // The plan limits are the two failures worth naming: both come back as
    // ordinary GraphQL errors, and neither is a schema problem to introspect.
    if (/cannot request data older than/.test(detail)) {
      fail(`${detail}\nThis plan's retention is the ceiling — lower --days (default ${DEFAULT_DAYS}).`)
    }
    if (/time range wider than/.test(detail)) {
      fail(`${detail}\nA query must stay inside one day; this is what fetchDay() exists for.`)
    }
    fail(
      `GraphQL request failed (HTTP ${response.status}): ${detail}\n` +
        'Run with --introspect to see the dimensions this account actually exposes.',
    )
  }
  return body.data
}

/** Same request, but a schema mismatch degrades the report instead of ending it. */
async function graphqlOptional(query) {
  try {
    const response = await fetch(`${API}/graphql`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query }),
    })
    const body = await response.json()
    if (!response.ok || (body.errors && body.errors.length > 0)) return null
    return body.data
  } catch {
    return null
  }
}

/**
 * The dimensions and filters on httpRequestsAdaptiveGroups vary by plan, so
 * when a query stops typechecking against the live schema this prints what is
 * available rather than leaving you to guess.
 */
async function introspect() {
  const data = await graphql(
    `query { __type(name: "ZoneHttpRequestsAdaptiveGroupsDimensions") { fields { name } } }`,
    {},
  )
  const fields = data.__type?.fields
  if (!fields) {
    fail('the schema does not expose ZoneHttpRequestsAdaptiveGroupsDimensions on this account')
  }
  console.log('httpRequestsAdaptiveGroups dimensions available to this token:\n')
  for (const field of fields) console.log(`  ${field.name}`)
}

function describeErrors(errors) {
  if (!Array.isArray(errors) || errors.length === 0) return 'no error detail returned'
  return errors.map((e) => e.message ?? JSON.stringify(e)).join('; ')
}

function isoDate(offsetDays) {
  const date = new Date()
  date.setUTCDate(date.getUTCDate() + offsetDays)
  return date.toISOString().slice(0, 10)
}

function readNumberFlag(argv, flag, fallback) {
  const index = argv.indexOf(flag)
  if (index === -1) return fallback
  const value = Number(argv[index + 1])
  if (!Number.isFinite(value) || value <= 0) fail(`${flag} needs a positive number`)
  return Math.floor(value)
}

function fail(message) {
  console.error(`usage.mjs: ${message}`)
  process.exit(1)
}
