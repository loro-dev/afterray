import { readdirSync, lstatSync } from 'node:fs'
import { join, resolve } from 'node:path'

export const repoRoot = resolve(import.meta.dirname, '../..')

/** Directories that hold no repo-authored source or prose. */
const SKIP = new Set([
  '.git',
  'target',
  'node_modules',
  '.build',
  'dist',
  'dist-ssr',
  '.afterray',
  '.afterray-dev',
  '.scratch',
  'vendor',
  '.claude',
  '.delta',
  '.ref-libs',
])

export interface Finding {
  file: string
  line?: number
  message: string
}

/**
 * Every file under `dir` with one of `exts`, depth-first, skipping build output.
 *
 * Symlinks are skipped, not followed. Every `AGENTS.md` in this repo has a
 * `CLAUDE.md` symlink beside it; following those would report every finding
 * twice and would file the copy under a path its own rules reject.
 */
export function listFiles(dir: string, exts: string[]): string[] {
  const out: string[] = []
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return out
  }
  for (const name of entries) {
    if (SKIP.has(name)) continue
    const full = join(dir, name)
    let stat
    try {
      stat = lstatSync(full)
    } catch {
      continue // a broken symlink is not our problem
    }
    if (stat.isSymbolicLink()) continue
    if (stat.isDirectory()) out.push(...listFiles(full, exts))
    else if (exts.some((e) => name.endsWith(e))) out.push(full)
  }
  return out
}

export function formatFinding(f: Finding): string {
  return `  ${f.file}${f.line === undefined ? '' : `:${f.line}`} — ${f.message}`
}
