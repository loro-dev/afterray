// Shape checks for decision records. These decide nothing about whether a
// record is *right* — only that it is findable, classified, and honest about
// its own status. The standard is docs/decisions/README.md.

import { existsSync, readFileSync } from 'node:fs'
import { basename, dirname, join, normalize, relative } from 'node:path'
import { repoRoot, listFiles, type Finding } from './util.ts'

const LIFECYCLES = ['proposed', 'active', 'superseded', 'rejected'] as const
const CLASSES = ['architecture', 'product', 'process', 'bug-fix'] as const
const AREAS = ['capture', 'store', 'models', 'recall-ui', 'agent', 'release', 'privacy'] as const

/** Sections each lifecycle must carry. `rejected/` keeps whatever it had. */
const REQUIRED: Record<string, string[]> = {
  active: ['## Problem', '## Decision', '## Alternatives considered', '## Consequences'],
  superseded: ['## Problem', '## Decision', '## Alternatives considered', '## Consequences'],
  proposed: ['## Problem', '## Proposal', '## Alternatives considered', '## Acceptance criteria', '## Risks'],
  rejected: ['## Problem', '## Alternatives considered'],
}

/** Proposal-era headings are spec-speak once a decision has shipped. */
const FORBIDDEN_WHEN_ACTIVE = ['## Proposal', '## Plan', '## Migration plan', '## Acceptance criteria']

export function checkRecords(): Finding[] {
  const findings: Finding[] = []
  const root = join(repoRoot, 'docs/decisions')
  if (!existsSync(root)) return findings

  const records = listFiles(root, ['.md']).filter((f) => {
    const name = basename(f)
    return name !== 'README.md' && name !== 'AGENTS.md' && !name.startsWith('_')
  })

  const supersedes = new Map<string, string>()
  const lifecycleOf = new Map<string, string>()

  for (const file of records) {
    const rel = relative(repoRoot, file)
    const parts = rel.split('/')
    const lifecycle = parts[2]
    const cls = parts[3]
    const text = readFileSync(file, 'utf8')
    const push = (message: string) => findings.push({ file: rel, message })

    if (lifecycle === undefined || !(LIFECYCLES as readonly string[]).includes(lifecycle)) {
      push(`lifecycle directory must be one of ${LIFECYCLES.join(', ')}.`)
      continue
    }
    lifecycleOf.set(rel, lifecycle)
    if (cls === undefined || !(CLASSES as readonly string[]).includes(cls)) {
      push(`class directory must be one of ${CLASSES.join(', ')}.`)
    }
    if (!/^\d{4}-\d{2}-\d{2}-[a-z0-9-]+\.md$/.test(basename(file))) {
      push('filename must be YYYY-MM-DD-slug.md.')
    }

    if (!/^# Decision: \S/m.test(text)) push('must open with `# Decision: <title>`.')

    const status = /^Status:\s*(\S+)/m.exec(text)
    if (status === null) {
      push('missing a `Status:` line.')
    } else if (status[1] !== lifecycle) {
      push(`Status: says "${status[1]}" but the file sits in ${lifecycle}/.`)
    }

    const area = /^Area:\s*(\S+)/m.exec(text)
    if (area === null) {
      push('missing an `Area:` line.')
    } else if (!(AREAS as readonly string[]).includes(area[1]!)) {
      push(`Area: "${area[1]}" is not one of ${AREAS.join(', ')}.`)
    }

    for (const section of REQUIRED[lifecycle] ?? []) {
      if (!text.includes(`\n${section}`)) push(`missing required section ${section}.`)
    }
    if (lifecycle === 'active') {
      for (const section of FORBIDDEN_WHEN_ACTIVE) {
        if (text.includes(`\n${section}`)) {
          push(`${section} is proposal-era spec-speak; an active record states what is.`)
        }
      }
    }

    const sup = /^Supersedes:\s*(\S+)/m.exec(text)
    if (sup !== null && sup[1] !== '—') {
      const target = normalize(join(dirname(file), sup[1]!))
      if (!existsSync(target)) push(`Supersedes: points at ${sup[1]}, which does not exist.`)
      else supersedes.set(rel, relative(repoRoot, target))
    }
  }

  // Superseding is a two-way link, and the superseded file has to have moved.
  for (const [newer, older] of supersedes) {
    const olderText = readFileSync(join(repoRoot, older), 'utf8')
    const back = /^Superseded-by:\s*(\S+)/m.exec(olderText)
    if (back === null || back[1] === '—') {
      findings.push({ file: older, message: `is superseded by ${newer} but has no Superseded-by: link back.` })
    } else {
      const resolved = relative(repoRoot, normalize(join(dirname(join(repoRoot, older)), back[1]!)))
      if (resolved !== newer) {
        findings.push({ file: older, message: `Superseded-by: points at ${resolved}, but ${newer} claims to supersede it.` })
      }
    }
    if (lifecycleOf.get(older) !== 'superseded') {
      findings.push({
        file: older,
        message: `is superseded by ${newer}, so it belongs in superseded/, not ${lifecycleOf.get(older)}/.`,
      })
    }
  }

  return findings
}
