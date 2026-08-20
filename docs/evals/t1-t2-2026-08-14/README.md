# T1 → T2 private-vault evaluation · 2026-08-14

Status: the raw inputs, model outputs, prompts, and tool transcripts from this run were removed because they contained personal computer-history data. They must not be restored from Git history or copied into a new fixture.

## Method retained

The evaluation used three private vault windows to compare T1 evidence presentation with the resulting T2 summaries. Review focused on whether a summary was grounded in supplied evidence, whether it named uncertainty instead of inventing details, and whether the T1 card made useful evidence discoverable within the tool-call budget.

## Findings retained

- Stable window grouping, opaque-identifier filtering, and explicit entry-point context made T1 cards easier to inspect.
- The evaluator found that useful summaries need a legitimate way to state missing evidence rather than fill it with inference.
- T1 improvements were turned into deterministic tests in the store and daemon; source and test names are the authoritative record of the implementation.

## Future evaluations

Use synthetic fixtures committed beside the test that consumes them. A real vault may be used locally to investigate quality, but its inputs, outputs, OCR, Accessibility trees, transcripts, screenshots, paths, identifiers, and derived summaries stay outside the repository.
