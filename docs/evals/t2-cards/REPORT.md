# T1/T2 card-quality evaluation — sanitized record

Status: raw cards, prompts, and model outputs from this private-vault evaluation are deliberately not kept in the repository.

## Retained conclusion

Evidence grounding and explicit citation validation reduced unsupported summary claims in the evaluated pipeline. The authoritative implementation is `ground_t2_details` in `crates/afterray-store/src/slot.rs`; it supersedes this report wherever they differ.

## What future evaluations may retain

- a synthetic fixture and its expected result, committed with the test that consumes it;
- aggregate, non-identifying outcome measures; and
- the exact code revision and reproducible command, provided neither exposes a local vault path, a user identity, or captured content.

Do not commit a real vault's T1 card, T2 card, prompt, tool transcript, screenshot, OCR, Accessibility tree, audio transcript, app/window title, or derived activity summary. Keep those local to the evaluation environment, then turn the finding into a synthetic regression test.
