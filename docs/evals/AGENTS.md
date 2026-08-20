# docs/evals — privacy boundary

This directory may record evaluation method, synthetic fixtures, and aggregate non-identifying results. It must never contain a local vault's input or output, including screenshots, OCR, Accessibility trees, transcripts, prompts, model cards, tool logs, app/window titles, timestamps, local paths, user identifiers, or derived activity summaries.

Run a private-vault evaluation only outside the repository. Turn its finding into a synthetic regression test, then keep only that fixture and the method needed to reproduce it. Before committing an evaluation change, run `make docs-sync` and inspect the diff for captured content.
