// Bilingual pairs: two texts that must say the same thing.
//
// The gate cannot read either language, so it does not try to. It records a
// hash of each side as of the last time a human confirmed they agreed, and goes
// red when one side moves without the other. Re-reading both and re-recording
// is the confirmation, and the lock diff is what makes it reviewable.
//
// This is worth having because it has already failed once here: the favourites
// promise sat wrong in `i18n.tsx` in both English and Chinese for months, and
// a one-sided edit is exactly how a pair drifts.
//
// A side is either a whole file or a slice of one, because the site keeps both
// languages in a single module. Slices are delimited by literal markers rather
// than line numbers so ordinary edits above them do not move the boundary.

import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { repoRoot, type Finding } from './util.ts'

interface Side {
  file: string
  /** First line of the slice. Omit with `to` to take the whole file. */
  from?: string
  /** The line that ends it, exclusive. */
  to?: string
}

interface Manifest {
  pairs: Record<string, Side[]>
}

const LOCK_NOTE_KEY = '//'
const LOCK_NOTE =
  'Hash of each side of a bilingual pair, as of the last time a human confirmed ' +
  'the two say the same thing. Re-record: node scripts/docs-gate/main.ts --write'

function sliceOf(side: Side): { text: string; error?: string } {
  const path = join(repoRoot, side.file)
  if (!existsSync(path)) return { text: '', error: `${side.file} does not exist` }
  const content = readFileSync(path, 'utf8')
  if (side.from === undefined) return { text: content }

  const lines = content.split('\n')
  const start = lines.findIndex((l) => l.includes(side.from!))
  if (start < 0) return { text: '', error: `${side.file} has no line containing "${side.from}"` }
  const rest = side.to === undefined ? -1 : lines.slice(start + 1).findIndex((l) => l.includes(side.to!))
  const end = rest < 0 ? lines.length : start + 1 + rest
  return { text: lines.slice(start, end).join('\n') }
}

function digest(text: string): string {
  const normalized = text
    .split('\n')
    .map((l) => l.replace(/\s+$/, ''))
    .join('\n')
  return `sha256:${createHash('sha256').update(normalized).digest('hex').slice(0, 16)}`
}

function key(side: Side): string {
  return side.from === undefined ? side.file : `${side.file}#${side.from}`
}

/**
 * @param write - re-record every hash instead of reporting drift.
 */
export function checkBilingual(write: boolean): Finding[] {
  const manifestPath = join(repoRoot, 'scripts/docs-gate/bilingual.json')
  if (!existsSync(manifestPath)) return []
  const manifest: Manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  const lockPath = join(repoRoot, 'scripts/docs-gate/bilingual.lock.json')
  const findings: Finding[] = []

  const current: Record<string, string> = {}
  for (const [pair, sides] of Object.entries(manifest.pairs)) {
    for (const side of sides) {
      const { text, error } = sliceOf(side)
      if (error !== undefined) {
        findings.push({ file: 'scripts/docs-gate/bilingual.json', message: `pair "${pair}": ${error}.` })
        continue
      }
      current[`${pair} :: ${key(side)}`] = digest(text)
    }
  }
  if (findings.length > 0 && !write) return findings

  if (write) {
    writeFileSync(
      lockPath,
      `${JSON.stringify({ [LOCK_NOTE_KEY]: LOCK_NOTE, ...current }, null, 2)}\n`,
    )
    return findings
  }
  if (!existsSync(lockPath)) {
    findings.push({
      file: 'scripts/docs-gate/bilingual.lock.json',
      message: 'missing — confirm each pair says the same thing, then --write.',
    })
    return findings
  }

  const parsed = JSON.parse(readFileSync(lockPath, 'utf8')) as Record<string, string>
  const stored = Object.fromEntries(Object.entries(parsed).filter(([k]) => k !== LOCK_NOTE_KEY))

  // Report per pair, not per side: naming only the side that moved invites
  // re-recording that one and calling it done, which is the failure this
  // exists to prevent.
  const moved = new Map<string, string[]>()
  for (const [id, hash] of Object.entries(current)) {
    if (stored[id] !== undefined && stored[id] !== hash) {
      const [pair, side] = id.split(' :: ')
      moved.set(pair!, [...(moved.get(pair!) ?? []), side!])
    } else if (stored[id] === undefined) {
      findings.push({
        file: 'scripts/docs-gate/bilingual.lock.json',
        message: `new side, not yet confirmed: ${id}`,
      })
    }
  }
  for (const [pair, sides] of moved) {
    findings.push({
      file: 'scripts/docs-gate/bilingual.lock.json',
      message:
        `pair "${pair}" moved on ${sides.length === 1 ? 'one side only' : 'both sides'}: ` +
        `${sides.join(', ')}. Read both, make them agree, then --write.`,
    })
  }
  for (const id of Object.keys(stored)) {
    if (!(id in current)) {
      findings.push({
        file: 'scripts/docs-gate/bilingual.lock.json',
        message: `records a side that is no longer in the manifest: ${id}`,
      })
    }
  }
  return findings
}
