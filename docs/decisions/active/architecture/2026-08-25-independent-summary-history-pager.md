# Decision: Summary history owns an independent cursor chain

Status: active
Area: recall-ui
Anchors:
- swift/AfterRayRecall/Sources/SummaryHistoryStore.swift @dec:independent-summary-history-pager
Supersedes: —
Superseded-by: —

## Problem

The history panel used the timeline's selected-day summary as both visible
content and the seed for older-page pagination. Before the first real playhead
arrived, the selection sentinel was epoch zero. Its local day could therefore
be inserted as a real heading and used as the older-than cursor. The resulting
document simultaneously showed a date with no history, claimed there was no
older page, and still had newer vault data outside that cursor.

Separate booleans for `hasMore` and `isLoading` also admitted a static bottom
that did not say whether loading had failed, had ended, or had never started.

## Decision

`SummaryHistoryStore` owns one newest-first day array and one tail boundary:
loadable cursor, loading cursor plus request identity, failed cursor, or end.
The initial cursor is a distinct `newest` value and maps to
`summary_history(before: nil)`. Only the daemon response may provide the next
cursor or history days. Timeline playhead and selected-day reads cannot insert
days or change the cursor.

One `loadNext` transition changes a loadable or failed cursor to loading before
I/O. A response commits only while both cursor and request identity still
match. Success either exposes the daemon's next cursor or reaches end; failure
keeps the same cursor retryable. A page with no panel-visible rows continues
through its next cursor in the same loading operation, so it cannot leave an
invisible page as a static bottom. A successful page that claims more data
without a progressing cursor is a failure, not a false end.

The bottom row follows that boundary directly: loading shows progress, failed
shows Retry, loadable requests the next page near the viewport end, and only
end removes the row. The previous wall-clock throttle is unnecessary because
the loading boundary deduplicates requests.

The overlay and standalone History window share this store. A newest-page
refresh may replace recent day values but preserves the tail cursor and older
loaded pages. Lock or sleep invalidates request identities and prevents the
still-mounted overlay from repopulating cleared history until resume reloads
from newest.

## Alternatives considered

**Reject epoch-like selected days in `RecallStore`.** This removes the reported
date but keeps two producers and independent booleans capable of constructing
the same contradiction with a different sentinel or request ordering.

**Keep selected-day summary as the first page and repair the cursor.** The
panel would still combine a navigation read model with a pagination read model,
so every future selection feature would remain able to reorder history.

**Introduce a reusable generic pager or reducer framework.** No other module
needs this state shape. Generalising it adds vocabulary and dependencies
without making the four history boundary cases clearer.

## Consequences

The panel cannot render a cursor as a date, cannot report end after a failed
request, and cannot accept a stale response after reset or suspend. History
pagination is testable through the narrow `SummaryHistoryPageLoading` protocol
without constructing a timeline store.

The history module owns a small amount of explicit state and one head-refresh
path. Refresh failures intentionally preserve the already truthful document;
tail failures remain visible and retryable.
