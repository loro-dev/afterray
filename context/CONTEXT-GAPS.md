# Context Discoverability Gaps (backlog)

When something important took you too many hops to find, append one line here instead of (or before) fixing the docs. Format:

`YYYY-MM-DD | <question that was hard to answer> | <answer, with file:symbol anchor> | why it was hard | suggested home`

Suggested home = which `AGENTS.md` or `context/` article should carry the shortcut. Periodically promote entries into the suggested home and delete them here.

## Open gaps

2026-08-18 | "how long does the vault keep things?" — i.e. what "the vault's general retention" actually is | there is no time-based retention at all: `afterray-store/src/lib.rs enforce_retention` is a **size**-driven oldest-first eviction loop, and under the storage limit nothing expires ever | every doc said "retention" without saying *by what*, so unifying the input streams onto it needed the whole function read to find out there was no clock to unify with | one sentence in `crates/afterray-store/AGENTS.md` (added: the retention bullet now says oldest-first + horizon); if a time policy is ever added, that bullet is the place it must be stated

2026-08-18 | `crates/afterrayd/AGENTS.md` is ~4.6k chars against the ~4000 budget (was ~4.1k) | WS4 added two facts that have to be findable from the crate index — `fire_capture_tick` is the only door to a screenshot, and the input streams no longer have a retention of their own | both were trimmed to one clause plus a link to `context/event-capture-v2.md`; the file is at the point where the next addition must displace something | the T2/GOP/agent bullets are the extractable ones — `context/agent-tools.md` already carries the agent surface and could take its bullet's detail entirely

2026-08-18 | `crates/afterray-store/AGENTS.md` is now ~7.1k chars against the ~4000 budget (was 6.8k) | WS4's retention model went into the existing retention bullet + `context/event-capture-v2.md` §3b rather than a new bullet, so the growth was ~330 chars | the file still carries one index line per subsystem and there are now twelve | the 2026-08-17 entry below still names the right extraction (schema-1-vs-2, search/mention rules); retention now has a home in `context/event-capture-v2.md` and could be pointed at rather than described

2026-08-18 | `apps/AfterRayCaptureShim/AGENTS.md` is ~6.3k chars against the ~4000 budget | event-capture v2's depth went to `context/event-capture-v2.md`, and the file still came out only slightly smaller than before | the shim is one 2.6k-line file carrying capture, audio exclusion, the input tap and the AX walk, and each has a real invariant that cannot be a half sentence | next shim change should move the audio-gate and display-selection invariants into `context/capture-pipeline.md` (which already covers both) and leave one-line pointers

2026-08-17 | `crates/afterray-store/AGENTS.md` is ~6.1k chars against the ~4000 budget | it was already 5.5k before the acts join; the join's detail went to `context/acts-join.md` rather than into it | the vault has ten subsystems and one index line each already overflows | next few `afterray-store` changes should extract `slot_summaries` schema-1-vs-2 and the search/mention rules into `context/` articles the way `acts-join` was done
