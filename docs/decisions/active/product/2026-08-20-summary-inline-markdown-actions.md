# Decision: Summary actions sit beside the title and share one Markdown rendering

Status: active
Area: recall-ui
Anchors:
- swift/AfterRayRecall/Sources/DaySummaryTitleActions.swift @dec:summary-inline-markdown-actions
- swift/AfterRayRecall/Sources/DaySummaryTitleLayout.swift @dec:summary-inline-markdown-actions
- swift/AfterRayRecall/Sources/SummaryExportFileStore.swift @dec:summary-inline-markdown-actions
Supersedes: —
Superseded-by: —

## Problem

Copying one summary is hidden in a row context menu, and moving the same content into a note requires a manual paste-and-save sequence. Separate formatting paths for the two actions could also make the copied text differ from the file that opens.

## Decision

Generated summary rows place compact Copy and Markdown-file actions immediately after the title's final rendered character. Pointer controls appear only while the entry is hovered and reserve their layout space while hidden, so revealing them never moves the title. VoiceOver keeps the same named actions without requiring hover. Both actions use `DaySummaryClipboard.slotText`; the file action writes that text to the existing private temporary export store with an `.md` extension and opens it through macOS.

The temporary directory and file permissions, expiration, and launch, suspend, and exit cleanup remain the same as JSON summary exports.

## Alternatives considered

**Keep the actions in the context menu.** This preserves a quieter row but leaves common export actions undiscoverable.

**Put the actions at the card's trailing edge.** This gives every row a fixed control column, but visually disconnects the actions from the title and consumes width even for short titles.

**Keep the actions visible on every row.** This maximises pointer discoverability, but repeats secondary chrome throughout a dense reading surface. Hover disclosure keeps the titles primary while accessibility actions remain available independently.

**Create a permanent file through a save panel.** This gives the user an explicit destination, but adds a blocking step when the intent is to open the summary immediately in a Markdown editor.

## Consequences

The actions appear in the title's reading flow without forming a detached trailing column, and their output stays identical. Pointer users discover them on row hover; keyboard and VoiceOver users receive named custom actions without depending on hover. Reserving hidden control space can wrap a title slightly earlier than text alone, but prevents the row and the windowed document from changing height under the pointer. Opening Markdown creates a short-lived decrypted copy in a private temporary directory; the existing cleanup lifecycle bounds that exposure, but an external editor may retain its own copy or recovery state after opening it.
