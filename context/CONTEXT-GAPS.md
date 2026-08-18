# Context Discoverability Gaps (backlog)

When something important took you too many hops to find, append one line here instead of (or before) fixing the docs. Format:

`YYYY-MM-DD | <question that was hard to answer> | <answer, with file:symbol anchor> | why it was hard | suggested home`

Suggested home = which `AGENTS.md` or `context/` article should carry the shortcut. Periodically promote entries into the suggested home and delete them here.

## Open gaps

2026-08-18 | `apps/AfterRayCaptureShim/AGENTS.md` is ~6.3k chars against the ~4000 budget | event-capture v2's depth went to `context/event-capture-v2.md`, and the file still came out only slightly smaller than before | the shim is one 2.6k-line file carrying capture, audio exclusion, the input tap and the AX walk, and each has a real invariant that cannot be a half sentence | next shim change should move the audio-gate and display-selection invariants into `context/capture-pipeline.md` (which already covers both) and leave one-line pointers

2026-08-17 | `crates/afterray-store/AGENTS.md` is ~6.1k chars against the ~4000 budget | it was already 5.5k before the acts join; the join's detail went to `context/acts-join.md` rather than into it | the vault has ten subsystems and one index line each already overflows | next few `afterray-store` changes should extract `slot_summaries` schema-1-vs-2 and the search/mention rules into `context/` articles the way `acts-join` was done
