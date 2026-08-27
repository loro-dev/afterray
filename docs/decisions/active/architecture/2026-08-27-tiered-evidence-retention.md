# Decision: Raw evidence has an optional age horizon and archived images age in quality

Status: active
Area: store
Anchors:
- crates/afterray-store/src/lib.rs @dec:tiered-evidence-retention
- crates/afterray-store/src/gop.rs @dec:tiered-evidence-retention
- crates/afterrayd/src/gop_packer.rs @dec:tiered-evidence-retention
Supersedes: ../../superseded/architecture/2026-08-20-size-driven-retention.md
Superseded-by: —

## Problem

Screen history is useful at two different resolutions. Its timeline shape and
derived descriptions stay useful for recall over a long period, while old raw
screens, audio, and accessibility trees account for nearly all storage and
become less valuable with age. A byte limit alone cannot express that split: it
either grows for an unpredictable duration or removes the timeline row together
with its evidence.

Archived images also need a middle ground. Keeping every GOP at capture quality
for as long as raw evidence exists spends disk on old pixels; deleting them all
at one threshold gives the user no gradual trade-off.

## Decision

The size limit remains an emergency ceiling. A second, optional setting,
`retention_days`, is the ordinary raw-evidence horizon. `nil` keeps the historical
size-only behavior. A positive value from 1 through 3650 strips evidence strictly
older than K wall-clock days while retaining each `moments` row, its application
and window metadata, OCR-derived text, and already-built slot summaries. The
timeline therefore still scrubs through the interval, but its expired moments
have no picture or recording.

Expiry removes stills, thumbnails, accessibility artifacts, complete GOPs,
audio segments, transcript rows and cues attached to those segments, and R3 edge
snapshots. A GOP or audio segment crossing the cutoff stays until its entire
segment is older, so one encrypted object is never partly deleted. Favorites do
not override this privacy/storage horizon. If the byte ceiling also fires while
an age horizon is enabled, it may strip more raw evidence but may not delete the
timeline rows.

Archived AV1 GOPs use constant-quantizer quality tiers when quality aging is
enabled. It is off by default, including for settings files written before the
option existed, because re-encoding cannot restore discarded detail. Q100 applies
before seven days, followed by one interpolated step after seven days, a second
after fourteen days, and the user-selected worst quantizer after twenty-eight
days. The worst value is bounded to Q120...Q240; a higher value means stronger
compression, not a promised bitrate. Existing GOPs are decoded and rewritten in
the same archive workload as new packing, under the same compute gate. The new
encrypted artifact and frame table replace the old one atomically only after a
complete re-encode. Every newly encoded sequence declares the smallest defined
AV1 level that contains its dimensions; rav1e's unconstrained level sentinel is
not persisted because VideoToolbox rejects it in the sequence configuration.
The K-day deletion horizon always wins over a quality tier.

New GOP packing waits for 30 compatible cold frames; smaller keyint overrides
fall back to 30. Archive compact also repairs legacy underfilled GOPs before
quality aging. It merges consecutive AV1 segments when resolution matches, the
next segment begins within the 30-second capture continuity window, and the
merged result has at most 30 frames. Sources may have different quality tiers;
the one output is never better than any source and also applies the tier required
by its current age, avoiding a second quality-aging transcode. Interleaved display
resolutions keep independent candidate runs. The new encrypted GOP,
frame rows, moment indexes, and historical pack-job references replace all
source segments in one transaction; a race leaves every old GOP untouched.

The settings preview prefers the best-quality representative ready GOP, performs
a real worst-tier encode when that sample can still be degraded, and returns its
poster plus the source and resulting quantizers. Its measured ratio applies only
to archive bytes that are still better than the selected worst tier; GOPs already
at that tier or worse keep their measured bytes. The projection is an estimate,
not a quota: content compressibility differs between screens.

Raw input events keep their independent 48-hour privacy deadline from
[Raw input events expire](../product/2026-08-20-raw-input-events-expire.md).

## Alternatives considered

**Keep only the byte ceiling.** Rejected because the user cannot ask for a
predictable seven- or thirty-day raw-evidence window, and freeing evidence also
destroys old timeline shape.

**Delete old timeline rows with their evidence.** Rejected because metadata is
small and preserves navigation, summaries, and the fact that activity occurred.

**One hard image-quality step.** Rejected because a visible cliff at day seven
spends too much quality at once. Three fixed ages make the policy explainable;
one worst-quality control keeps the settings surface bounded.

**Expose a bitrate control.** Rejected because rav1e is configured with a
constant quantizer and screen content has no stable bytes-per-second mapping.
Labelling that control as bitrate would promise precision the encoder does not
provide.

**Keep legacy short GOPs forever.** Rejected because each one repeats a
keyframe, IVF header, encrypted artifact header, and database rows. Repacking
compatible neighbours removes that fixed overhead without changing timeline
coverage or the selected quality tier.

## Consequences

Storage becomes predictable without erasing the long timeline. K=7 skips every
quality-aging tier because evidence is deleted at the same boundary; K=30 uses
all three tiers before deletion. Re-encoding consumes CPU and temporarily holds
decoded pixels, so it stays in the archive background lane, has a bounded helper
deadline and decoded-byte budget, and zeroes those buffers after use.

The final short or incompatible GOP in a stream may remain under 30 frames;
compact never crosses an idle boundary or quality tier merely to fill a batch.

Audio transcripts and alignment cues disappear with the expired audio segment;
OCR and higher-level summaries remain. Estimates shown in Settings can be wrong
for a different screen mix, so they are explicitly sample-based. Existing
databases do not shrink their main SQLCipher file merely because rows are
deleted; artifact files, which dominate storage, are reclaimed immediately.
