# Event capture v2 — tree text, diff chains, and the input vocabulary

Verified against code 2026-08-18 (WS1–WS3 shim half).

What the shim emits after [docs/event-capture-v2-plan.md](../docs/event-capture-v2-plan.md). Owners: `apps/AfterRayCaptureShim` (`Sources/AfterRayCapturePolicy` for everything pure, `Sources/AfterRayCaptureShim/main.swift` for the live-AX wiring), `crates/afterray-platform-macos` (parsing). The daemon and vault consume the new fields in a later workstream; until then serde defaults let them ride along ignored.

## 1. `tree_text` — the AX tree as readable text

Every accessibility snapshot (heartbeat `accessibility` and attached `accessibility_edge` alike) carries a `tree_text` object **beside** the unchanged `root` and `digest`:

```json
"tree_text": {"mode": "fullTree", "text": "0 standard window Mail\n\t1 button Send", "chain": "a1b2c3d4-3", "seq": 0}
```

- `mode` — `fullTree` (a keyframe, and the base of a chain), `diffFromPrevious` (a `TreeDiff` against the previous emission of the same chain), or `unchanged` (the fingerprint says nothing moved; no `text`). `unchanged` is spelled out rather than omitted so a reader can tell a static screen from a shim too old to encode trees.
- `text` — the numbered indented render (`CaptureTreeText`) or the diff render (`TreeDiff`). Measured: a JSON tree runs ~200 KB per frame, these diffs have a 913 B median.
- `chain` + `seq` — beyond the plan's `{mode, text}`, and load-bearing. Chains are **per window**, so a `diffFromPrevious` is taken against the previous emission *of its own chain*, which is not in general the previous artifact in time. A diff whose base cannot be named is not decodable; these name it (`seq` n decodes against n-1 of the same `chain`).

### Chains (`CaptureTreeChains`)

- Key: `(pid, window title, walk root)`. The walk root — `.application` for the heartbeat, `.window` for an attached walk — is part of the identity because the two produce different roots for the same window, and diffing across them aligns `AXApplication` with `AXWindow`: "delete everything, add everything", bigger than the keyframe it replaced.
- `KeyframePolicy.decide` picks: a scope with no chain is a keyframe (this is what "window changed" means once chains are per window), an unchanged fingerprint is a skip, the 30th diff forces a re-base. A forced keyframe keeps the chain id and keeps counting `seq`.
- Bounded to `maxChains = 6`, LRU. Each chain holds a whole rendered tree (up to the encoder's 20k nodes), so this is a memory bound on an all-day helper; an evicted window costs one keyframe when it comes back.
- **Stage, then commit.** `stage` decides and mutates nothing; `commit` runs only once the artifact is actually sent. The foreground can move between the walk and the write, and `captureScreen` deletes an accessibility artifact whose frame it could not pair — a chain that advanced past an artifact nobody received would hand the consumer a diff against a tree it never saw, silently, for the rest of the chain.
- Fingerprint is FNV-1a over the rendered text (`CaptureTreeFingerprint`). A collision costs one skipped snapshot, which is why it is not a cryptographic digest.
- Edge case: text can differ while the diff is empty (two identical siblings swapped, so only numbering moved). The base stays — the base is defined as *what the consumer can reconstruct* — and the emission degrades to `unchanged`.

## 2. The input vocabulary

`input_events` batches keep their shape; the kinds are additive and **never renamed**, because `afterray-store`'s act join matches these strings (`acts.rs parse_event`).

| kind | plan name | payload |
|---|---|---|
| `burst` | `text_input` | `count`, `end_ms`, `ended_with`, `text` (the typed run), `target.value` |
| `command` | `submit` / `shortcut` | `command`; `return` / `cmd-return` are submit, and their target carries `value` |
| `click` | `mouse.click` | `target` |
| `scroll` | `scroll` | `count`, `target` |
| `drag` | `mouse.drag` | `source` + `destination`, both resolved like any target |
| `window_changed` | `window.changed` | `bundle_identifier`, `application_name`, `window_title` |

- **The value is the primary content channel**, not the keystream: measured, 1,796 `text_input` events carried no Chinese at all (a CJK keystream is pinyin fragments — `wsm tongyini`) while 451 target values did. `text` is the secondary, Latin-and-timing channel.
- Runs are cut by a 2s pause (`TypedTextRun.pauseMs`), the measured word-level chunk. The value is read at the **end** of a run and at the submit instant — at the start it is the field before the user typed, and an IME has not committed yet.
- `ComposedFieldValue.windowed` clips to 500 characters around the caret (`kAXSelectedTextRange`), announced inline with `[truncated to visible range]`. AX reports UTF-16 offsets while the clip counts characters, so the window can sit a few characters off; it is a window, not an index.
- `TypedTextRun.append` applies backspace and forward delete to the run and drops control characters and the private-use scalars macOS uses for arrows and function keys — what is stored is what the user left standing.
- `drag`: the source is resolved at mouse-down (it is the same resolution the `click` record already made), the destination at mouse-up. `DragGesturePolicy.isDrag` (12 points) separates a drag from a click that wobbled, and it runs **on the tap thread** — dragged events arrive at pointer rate, the callback answers each with one comparison, and only a `Bool` is forwarded. The coordinates die there, as they always have.
- `window_changed` comes from the 1s frontmost poll (`NSWorkspace` notifications never arrive: the main thread blocks in `readLine`). A window *title* change inside one app is not yet detected — only the bundle is polled.

## 3. The secure guard

CAP-005's ban on keystroke content lapsed with the local trust model (plan §信任模型变更). What replaced it is one guard, and it is absolute: `SecureInputGuard.isSecure` answers from the element's subrole (`AXSecureTextField`), its ancestors' subroles (apps put it on the wrapper), and a secret-looking label (`password`, `passphrase`, `密码`, … — Electron and web apps render password boxes as plain text fields). When it says yes, no keystream is accumulated and no value is read; the burst keeps its `count` and sets `target.secure`.

- **An unresolvable focus counts as secure.** Not knowing what the field is, is not evidence that it is safe.
- The guard runs in the shim, at the source. Nothing downstream re-checks and nothing downstream *can*: by the time a record reaches a parser the password is already absent, and a parser judging a field it never saw would be guessing.
- A false positive costs one field's text and nothing else. That is the direction this is allowed to be wrong in.

## 4. Attachment tiers

`requestTreeWalk` (main.swift) is the single door to a walk, and it only ever *asks* — `EdgeSnapshotPacing` still decides, and spend still goes through `fire(nowMs:walk:)`, so a declined walk cannot burn the minute's allowance.

- `click`, `drag`, `window_changed`, submit → ask every time (measured: submit 31/31, click 149/157, window.changed 130/135).
- `burst`, `scroll` → never. The record already holds the content; walking a window to re-read it spends the app's main thread for nothing.
- Shortcuts → every 6th (~17%, counted rather than sampled, so short sessions stay honest).

The R3 invariants are unchanged: one window, `accessibility_edge`, **never a screenshot**, browsers and excluded apps skipped. See [acts-join](acts-join.md).

## Watch out

- The shim's `main.swift` needs live AX and TCC, so nothing in it is covered by `swift test`. Anything that can be a pure decision belongs in `AfterRayCapturePolicy` — that is why the chain, the guard, the chunking and the tiers all live there.
- The daemon currently stores only `at_ms/kind/end_ms/count/ended_with/command/bundle_identifier/target_json`; `text`, `source`, `destination`, `application_name` and `window_title` are parsed and dropped until WS4.
