// The documentation gate. Run it with `make docs-sync`, or directly:
//
//   node scripts/docs-gate/main.ts            check
//   node scripts/docs-gate/main.ts --write    re-record anchor hashes
//
// No dependencies, no package.json, no node_modules — Node runs the TypeScript
// directly. Nothing here is on a product path; this tree exists only to keep
// documentation from drifting away from the code.
//
// What it cannot do is judge whether a decision is still *right*. It proves a
// record was looked at when its code changed. The rest stays with review.

import { checkAnchors } from './anchors.ts'
import { checkLinks } from './links.ts'
import { checkRecords } from './records.ts'
import { formatFinding, type Finding } from './util.ts'

const write = process.argv.includes('--write')

const checks: { name: string; run: () => Finding[] }[] = [
  { name: 'markdown links', run: checkLinks },
  { name: 'decision records', run: checkRecords },
  { name: 'code anchors', run: () => checkAnchors(write) },
]

let failed = 0
for (const { name, run } of checks) {
  const findings = run()
  if (findings.length === 0) {
    console.log(`ok    ${name}`)
    continue
  }
  failed += findings.length
  console.log(`FAIL  ${name} (${findings.length})`)
  for (const f of findings) console.log(formatFinding(f))
}

if (write) {
  console.log('\nanchor hashes re-recorded; review the sidecar diff before committing.')
}
if (failed > 0) {
  console.log(`\n${failed} problem${failed === 1 ? '' : 's'}.`)
  process.exit(1)
}
console.log('\nall documentation checks passed.')
