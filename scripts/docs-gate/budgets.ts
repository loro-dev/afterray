// Size ceilings for the agent-facing documents.
//
// A ceiling is a guardrail, not a reduction target. The job is to make growth a
// decision: past the ceiling you either move detail to the article that owns it,
// cut it, or raise the number and say why in the PR. Without this, an AGENTS.md
// grows one useful paragraph at a time until nobody reads it — which is the
// state `context/CONTEXT-GAPS.md` has been recording, by hand, for weeks.

import { readFileSync, existsSync } from 'node:fs'
import { join, relative, basename } from 'node:path'
import { repoRoot, listFiles, type Finding } from './util.ts'

interface Manifest {
  defaults: { agentsMd: number; contextArticle: number }
  files: Record<string, number>
}

/** Characters, counted the way `wc -m` counts them: one per code point. */
function size(path: string): number {
  return [...readFileSync(path, 'utf8')].length
}

function ceilingFor(rel: string, manifest: Manifest): number | null {
  const explicit = manifest.files[rel]
  if (explicit !== undefined) return explicit
  if (basename(rel) === 'AGENTS.md') return manifest.defaults.agentsMd
  if (rel.startsWith('context/') && rel.endsWith('.md')) return manifest.defaults.contextArticle
  return null
}

export function checkBudgets(): Finding[] {
  const manifestPath = join(repoRoot, 'scripts/docs-gate/budgets.json')
  if (!existsSync(manifestPath)) return []
  const manifest: Manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  const findings: Finding[] = []

  const budgeted = new Set<string>()
  for (const file of listFiles(repoRoot, ['.md'])) {
    const rel = relative(repoRoot, file)
    const ceiling = ceilingFor(rel, manifest)
    if (ceiling === null) continue
    budgeted.add(rel)
    const actual = size(file)
    if (actual > ceiling) {
      findings.push({
        file: rel,
        message:
          `${actual} chars, ceiling ${ceiling}. Move detail to the article that owns it, ` +
          `cut it, or raise the ceiling in budgets.json and justify it in the PR.`,
      })
    }
  }

  // A ceiling for a file that no longer exists is a stale exemption, and the
  // next file to take that path would silently inherit it.
  for (const rel of Object.keys(manifest.files)) {
    if (!budgeted.has(rel) && !existsSync(join(repoRoot, rel))) {
      findings.push({
        file: 'scripts/docs-gate/budgets.json',
        message: `holds a ceiling for ${rel}, which does not exist.`,
      })
    }
  }
  return findings
}
