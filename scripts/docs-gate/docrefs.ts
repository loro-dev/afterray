// Documentation paths cited from source comments.
//
// A comment that points at `context/acts-join.md` is a real reference — often
// the only pointer from the code to the reasoning behind it — and nothing
// renders it, so nothing catches it rotting. This audit found comments citing a
// constant that had been deleted and articles under their old paths; both read
// as authoritative until someone goes looking.

import { readFileSync } from 'node:fs'
import { existsSync } from 'node:fs'
import { join, relative } from 'node:path'
import { repoRoot, listFiles, type Finding } from './util.ts'

/** Repo-relative Markdown paths, which is how comments here cite documents. */
const DOC_REF = /\b(?:docs|context)\/[A-Za-z0-9._/-]+\.md/g

const SOURCE_DIRS = ['crates', 'apps', 'swift', 'scripts']
const SOURCE_EXTS = ['.rs', '.swift', '.ts', '.py', '.sh']

export function checkDocRefs(): Finding[] {
  const findings: Finding[] = []
  for (const dir of SOURCE_DIRS) {
    for (const file of listFiles(join(repoRoot, dir), SOURCE_EXTS)) {
      const rel = relative(repoRoot, file)
      readFileSync(file, 'utf8')
        .split('\n')
        .forEach((line, index) => {
          for (const match of line.matchAll(DOC_REF)) {
            const target = match[0]
            if (existsSync(join(repoRoot, target))) continue
            findings.push({
              file: rel,
              line: index + 1,
              message: `cites ${target}, which does not exist.`,
            })
          }
        })
    }
  }
  return findings
}
