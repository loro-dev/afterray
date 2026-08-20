// Relative Markdown links and their `#fragment` anchors.
//
// This is the highest-yield check in the gate: a link is the one part of a
// document that is both load-bearing and mechanically decidable. A rename that
// leaves the prose true still leaves the reader stranded.

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, normalize, relative } from 'node:path'
import { repoRoot, listFiles, type Finding } from './util.ts'

/** `[label](target)` or `[label](<target>)`, with an optional `#fragment`. */
const LINK = /\[[^\]\n]*\]\(\s*<?([^)>\s#]+)(#[^)>\s]*)?>?\s*\)/g

const EXTERNAL = /^(https?:|mailto:|afterray:|#)/

/**
 * GitHub's heading slug, close enough for our corpus: lowercase, punctuation
 * dropped, spaces to hyphens. CJK characters survive, which matters here — a
 * good part of this repo's prose is Chinese.
 *
 * Each space becomes its own hyphen, never a collapsed run: GitHub drops the
 * em dash in `yet — and` and keeps both surrounding spaces, so the anchor is
 * `yet--and`. Collapsing them silently fails every link written by hand from
 * the rendered page.
 */
function slug(heading: string): string {
  return heading
    .trim()
    .toLowerCase()
    .replace(/[`*_~]/g, '')
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .trim()
    .replace(/\s/g, '-')
}

function headingSlugs(file: string): Set<string> {
  const out = new Set<string>()
  let fenced = false
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    if (/^\s*```/.test(line)) {
      fenced = !fenced
      continue
    }
    if (fenced) continue
    const m = /^(#{1,6})\s+(.*)$/.exec(line)
    if (m !== null) out.add(slug(m[2]!))
    const anchor = /<a\s+(?:id|name)="([^"]+)"/.exec(line)
    if (anchor !== null) out.add(anchor[1]!.toLowerCase())
  }
  return out
}

/**
 * Check every relative link in every tracked Markdown file.
 *
 * Links inside fenced code blocks are skipped — a fence is an example, not a
 * reference, and holding examples to this rule makes the gate a nuisance.
 *
 * @returns every link whose target file, or whose heading anchor, does not exist.
 */
export function checkLinks(): Finding[] {
  const findings: Finding[] = []
  const slugCache = new Map<string, Set<string>>()

  for (const file of listFiles(repoRoot, ['.md'])) {
    const rel = relative(repoRoot, file)
    const base = dirname(file)
    let fenced = false

    readFileSync(file, 'utf8')
      .split('\n')
      .forEach((line, index) => {
        if (/^\s*```/.test(line)) {
          fenced = !fenced
          return
        }
        if (fenced) return

        for (const m of line.matchAll(LINK)) {
          const target = m[1]!
          const fragment = m[2]
          if (EXTERNAL.test(target)) continue

          const resolved = normalize(join(base, target))
          if (!existsSync(resolved)) {
            findings.push({
              file: rel,
              line: index + 1,
              message: `broken link → ${target}`,
            })
            continue
          }
          if (fragment === undefined || !resolved.endsWith('.md')) continue

          let slugs = slugCache.get(resolved)
          if (slugs === undefined) {
            slugs = headingSlugs(resolved)
            slugCache.set(resolved, slugs)
          }
          const wanted = fragment.slice(1).toLowerCase()
          if (wanted !== '' && !slugs.has(wanted)) {
            findings.push({
              file: rel,
              line: index + 1,
              message: `link ${target} has no heading "${fragment}"`,
            })
          }
        }
      })
  }
  return findings
}
