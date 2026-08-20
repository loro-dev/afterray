# Usage numbers without telemetry

How we answer "how many people use AfterRay?" without the app sending anything.

## The constraint comes first

AfterRay ships **no telemetry**, and that is a product promise, not an
oversight. `site/src/i18n.tsx` sells "no account, no telemetry, no cloud sync —
nothing leaves unless you point it at a remote model" in both locales, and
README promises captures stay on the Mac.

So: **do not add a device id, an install id, or a stats ping** without changing
that copy first. A persistent client-side identifier is telemetry however
anonymous it is, and for a screen-recording product the trust cost of being
caught claiming otherwise dwarfs the value of an exact user count. A persistent
id plus the IP it arrives from is also a record of where a user's machine has
been — real data we would then have to hold, secure, and be subpoenaed for.

Server-side alternatives exist if a real unique count is ever needed: hash
`(IP, User-Agent)` with a salt that rotates daily and keep only a HyperLogLog
sketch. No identifier is stored on the user's device, so it does not trigger
ePrivacy consent, and cross-day correlation is impossible by construction. It
would still need no client change. We have not needed it.

## What we read instead

Cloudflare's edge log, which exists whether or not we look at it.

Every install polls `/appcast.xml` once a day — `SUScheduledCheckInterval` is
86400 in `apps/AfterRay/Resources/Info.plist` — so its daily request count is a
proxy for daily actives. Sparkle's User-Agent carries the app version
(`AfterRay/0.0.5 Sparkle/2.9.5`), giving the version spread for free.

`site/scripts/usage.mjs` queries the `httpRequestsAdaptiveGroups` dataset over
the GraphQL Analytics API. Run it with `npm run usage`; the token comes from
`AFTERRAY_USAGE_ANALYTICS_KEY` or `CLOUDFLARE_API_TOKEN`, in the environment or
in gitignored `site/.env`.

It is **not** a unique-device count. NAT, several Macs per person, and machines
that reboot repeatedly all blur it. Read the trend, not the level.

## Traps, each of which cost a debugging round

**Filter by User-Agent or the numbers are mostly noise.** Crawlers, uptime
probes and our own `curl` checks all hit `/appcast.xml`, and they can outnumber
the app outright — a raw request count has been several times the real one.
Only `AfterRay/<version>` agents are counted; everything else is reported once,
as excluded noise.

**Cloudflare's Early Hints prefetcher (`nginx-ssl early hints`) is the only
thing that ever gets a 504 from `/download/latest`.** Count it as a user and
you invent a ~50% download failure rate that nobody experiences. It is edge
infrastructure, not traffic.

**One download click is two requests.** `/download/latest` 302s (`no-cache`) to
a versioned name, so the click and the transfer are logged separately. The
script counts them apart, and restricts artifacts to GET 200 — a HEAD probe is
not a download, and a 206 is one download arriving as many range requests.
`.dmg` is a new install; `.zip` is Sparkle updating an existing one.

**The Free plan caps the dataset twice**: no query may span more than 1d, and
nothing older than 1w1d is retained. Hence one request per day (well inside the
300-per-5-minutes quota) and a 7-day default. Asking for 30 days is an error,
not a longer report — to keep real history, save `--json` output periodically,
or upgrade the plan.

**`afteray.com` (one `r`) is a separate zone on the same account.** A token
scoped to it returns an empty zone list rather than an error, which reads as a
broken token. The script lists what the token *can* see for exactly this
reason.

**Dimensions and filters differ by plan** — `botManagementDecision` is paid-only,
for instance. `--introspect` prints the dimensions the current token can see
when a query stops matching the live schema.

## Reading the output

Filter values are inlined into the query text rather than passed as GraphQL
variables: Cloudflare's scalar type names (`Date`, `string`, `uint64`) vary by
plan, and a wrong declaration fails the whole query. Every interpolated value
must therefore be ours — `CLOUDFLARE_ZONE_ID` is regex-checked for this reason.

Pages Function responses are logged as `cacheStatus: dynamic`, i.e. they are
not edge-cached despite `Cache-Control: max-age=300` on the appcast. Every
poll reaches the Function and is counted; there is no cache-hit blind spot.
