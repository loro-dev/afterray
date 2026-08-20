// Anchor checks: the `@dec:` markers in source, the `Anchors:` lists in
// decision records, and the hash of the code each marker governs.
//
// The hash is the point. A marker alone proves someone once linked this code to
// a decision; it says nothing about whether the code has moved on since. The
// sidecar records what the anchored block looked like when a human last
// confirmed the decision still describes it, so an edit to that block turns the
// gate red and the confirmation has to happen again.

import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname, basename, relative } from 'node:path'
import { repoRoot, listFiles, type Finding } from './util.ts'

/** `// @dec:<slug> — <path to the record>`, in any comment syntax. */
const MARKER = /@dec:([a-z0-9-]+)(?:\s*[—-]+\s*(\S+))?/

/** Source trees a marker may live in. Nothing else is scanned. */
const SOURCE_DIRS = ['crates', 'apps', 'swift']
const SOURCE_EXTS = ['.rs', '.swift']

/** Explains the sidecar to whoever opens it. A valid JSON key, so it survives a round-trip. */
const SIDECAR_NOTE_KEY = '//'
const SIDECAR_NOTE =
  'Hash of the code each anchor governs, as of the last time a human confirmed ' +
  'this decision still describes it. Re-record: node scripts/docs-gate/main.ts --write'

export interface Anchor {
  slug: string
  file: string
  line: number
  recordPath: string | undefined
  signature: string
  body: string
}

export interface DecisionRecord {
  path: string
  slug: string
  anchorFiles: string[]
}

/**
 * The text a marker governs: the item directly below it.
 *
 * Doc comments and attributes between the marker and the item belong to the
 * item, so they are skipped rather than treated as the body — a marker sits
 * above them precisely so it stays out of the generated docs.
 *
 * An item with a brace body ends at its matching close brace. One without
 * (`const X: T = ...;`) ends at the first semicolon. Braces inside strings and
 * line comments do not count; counting them would make the hash depend on
 * punctuation in a comment.
 *
 * @param lines - the whole file, split on newlines.
 * @param markerIndex - zero-based index of the line carrying the marker.
 * @returns the item's first line and its full text, or null if nothing follows.
 */
export function extractBlock(
  lines: string[],
  markerIndex: number,
): { signature: string; body: string } | null {
  const skippable = (t: string) =>
    t === '' ||
    t.startsWith('//') ||
    t.startsWith('#[') ||
    t.startsWith('@')

  let i = markerIndex + 1
  while (i < lines.length && skippable(lines[i]!.trim())) i += 1
  if (i >= lines.length) return null

  const signature = lines[i]!.trim()
  const start = i
  let depth = 0
  let opened = false

  for (; i < lines.length; i += 1) {
    const line = lines[i]!
    let inString: string | null = null
    for (let c = 0; c < line.length; c += 1) {
      const ch = line[c]!
      if (inString !== null) {
        if (ch === '\\') c += 1
        else if (ch === inString) inString = null
        continue
      }
      if (ch === '"' || ch === "'") {
        inString = ch
        continue
      }
      if (ch === '/' && line[c + 1] === '/') break
      if (ch === '{') {
        depth += 1
        opened = true
      } else if (ch === '}') {
        depth -= 1
        if (opened && depth === 0) {
          return { signature, body: lines.slice(start, i + 1).join('\n') }
        }
      } else if (ch === ';' && !opened) {
        return { signature, body: lines.slice(start, i + 1).join('\n') }
      }
    }
  }
  return null
}

/** Trailing whitespace is not a change worth re-confirming a decision over. */
function digest(body: string): string {
  const normalized = body
    .split('\n')
    .map((l) => l.replace(/\s+$/, ''))
    .join('\n')
  return `sha256:${createHash('sha256').update(normalized).digest('hex').slice(0, 16)}`
}

/** Every `@dec:` marker in the source trees, with the block it governs. */
export function collectAnchors(): { anchors: Anchor[]; findings: Finding[] } {
  const anchors: Anchor[] = []
  const findings: Finding[] = []
  for (const dir of SOURCE_DIRS) {
    for (const file of listFiles(join(repoRoot, dir), SOURCE_EXTS)) {
      const rel = relative(repoRoot, file)
      const lines = readFileSync(file, 'utf8').split('\n')
      lines.forEach((line, index) => {
        const m = MARKER.exec(line)
        if (m === null) return
        const block = extractBlock(lines, index)
        if (block === null) {
          findings.push({
            file: rel,
            line: index + 1,
            message: `@dec:${m[1]} marks nothing — no item follows it.`,
          })
          return
        }
        anchors.push({
          slug: m[1]!,
          file: rel,
          line: index + 1,
          recordPath: m[2],
          signature: block.signature,
          body: block.body,
        })
      })
    }
  }
  return { anchors, findings }
}

/** Decision records under `docs/decisions/`, with the files their `Anchors:` list claims. */
export function collectRecords(): DecisionRecord[] {
  const out: DecisionRecord[] = []
  const root = join(repoRoot, 'docs/decisions')
  if (!existsSync(root)) return out
  for (const file of listFiles(root, ['.md'])) {
    const name = basename(file)
    if (name === 'README.md' || name === 'AGENTS.md' || name.startsWith('_')) continue
    const text = readFileSync(file, 'utf8')
    const slug = name.replace(/^\d{4}-\d{2}-\d{2}-/, '').replace(/\.md$/, '')
    const anchorFiles: string[] = []
    let inAnchors = false
    for (const raw of text.split('\n')) {
      if (/^Anchors:/.test(raw)) {
        inAnchors = true
        continue
      }
      if (!inAnchors) continue
      const m = /^-\s*(\S+)\s+@dec:([a-z0-9-]+)/.exec(raw.trim())
      if (m !== null) {
        anchorFiles.push(m[1]!)
        continue
      }
      if (raw.trim() !== '' && !raw.trim().startsWith('-')) inAnchors = false
    }
    out.push({ path: relative(repoRoot, file), slug, anchorFiles })
  }
  return out
}

function sidecarPath(recordPath: string): string {
  return join(repoRoot, dirname(recordPath), `${basename(recordPath, '.md')}.anchors.json`)
}

/**
 * Both directions of the anchor relation, plus the hash of every anchored block.
 *
 * @param write - re-record every hash instead of reporting drift. The sidecar
 *   diff is the reviewable act of confirming the decision still holds.
 * @returns every violation found.
 */
export function checkAnchors(write: boolean): Finding[] {
  const { anchors, findings } = collectAnchors()
  const records = collectRecords()
  const bySlug = new Map(records.map((r) => [r.slug, r]))

  for (const a of anchors) {
    const record = bySlug.get(a.slug)
    if (record === undefined) {
      findings.push({
        file: a.file,
        line: a.line,
        message: `@dec:${a.slug} has no decision record under docs/decisions/.`,
      })
      continue
    }
    if (!record.anchorFiles.includes(a.file)) {
      findings.push({
        file: record.path,
        message: `Anchors: does not list ${a.file}, which carries @dec:${a.slug}.`,
      })
    }
    if (a.recordPath !== undefined && !existsSync(join(repoRoot, a.recordPath))) {
      findings.push({
        file: a.file,
        line: a.line,
        message: `marker points at ${a.recordPath}, which does not exist.`,
      })
    }
  }

  const anchoredSlugs = new Set(anchors.map((a) => a.slug))
  for (const r of records) {
    if (r.anchorFiles.length > 0 && !anchoredSlugs.has(r.slug)) {
      findings.push({
        file: r.path,
        message: `lists anchors, but no @dec:${r.slug} marker exists in any source file.`,
      })
    }
    for (const f of r.anchorFiles) {
      if (!anchors.some((a) => a.slug === r.slug && a.file === f)) {
        findings.push({
          file: r.path,
          message: `Anchors: lists ${f}, which carries no @dec:${r.slug} marker.`,
        })
      }
    }
  }

  findings.push(...checkHashes(anchors, bySlug, write))
  return findings
}

function checkHashes(
  anchors: Anchor[],
  bySlug: Map<string, DecisionRecord>,
  write: boolean,
): Finding[] {
  const findings: Finding[] = []
  const bySidecar = new Map<string, Map<string, string>>()

  for (const a of anchors) {
    const record = bySlug.get(a.slug)
    if (record === undefined) continue
    const entries = bySidecar.get(record.path) ?? new Map<string, string>()
    entries.set(`${a.file}::${a.signature}`, digest(a.body))
    bySidecar.set(record.path, entries)
  }

  for (const [recordPath, entries] of bySidecar) {
    const file = sidecarPath(recordPath)
    const rel = relative(repoRoot, file)
    const current: Record<string, string> = Object.fromEntries([...entries].sort())

    if (write) {
      writeFileSync(
        file,
        `${JSON.stringify({ [SIDECAR_NOTE_KEY]: SIDECAR_NOTE, ...current }, null, 2)}\n`,
      )
      continue
    }
    if (!existsSync(file)) {
      findings.push({
        file: rel,
        message: 'missing — confirm the record still describes its anchored code, then --write.',
      })
      continue
    }

    const parsed = JSON.parse(readFileSync(file, 'utf8')) as Record<string, string>
    const stored = Object.fromEntries(
      Object.entries(parsed).filter(([k]) => k !== SIDECAR_NOTE_KEY),
    )
    for (const [key, hash] of Object.entries(current)) {
      if (!(key in stored)) {
        findings.push({ file: rel, message: `new anchored item, not yet confirmed: ${key}` })
      } else if (stored[key] !== hash) {
        findings.push({
          file: rel,
          message:
            `STALE — the code under ${key} changed since this decision was last confirmed. ` +
            `Re-read ${recordPath}; if it still holds, re-record with --write.`,
        })
      }
    }
    for (const key of Object.keys(stored)) {
      if (!(key in current)) {
        findings.push({ file: rel, message: `records an item that no longer exists: ${key}` })
      }
    }
  }
  return findings
}
