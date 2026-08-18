/// The AX role vocabulary, in words a person (and a language model) reads
/// without a manual.
///
/// `AXWebArea` and `AXGroup` mean nothing outside the Accessibility API; "HTML
/// content" and "container" mean the same thing to every reader. The mapping is
/// one-way and lossy on purpose — the raw role stays on `CaptureTreeNode` for
/// alignment, only the rendered line is humanized.
package enum CaptureRoleVocabulary {
    /// Subroles that say more than their role does. Checked first: an
    /// `AXRadioButton`/`AXTabButton` is a tab, not a radio button, and reading
    /// it as a radio button is how a tab strip gets described as a form.
    static let subroleWords: [String: String] = [
        "AXStandardWindow": "standard window",
        "AXDialog": "dialog",
        "AXSystemDialog": "dialog",
        "AXFloatingWindow": "floating window",
        "AXSystemFloatingWindow": "floating window",
        "AXTabButton": "tab",
        "AXSearchField": "search field",
        "AXSecureTextField": "secure text field",
        "AXCloseButton": "close button",
        "AXMinimizeButton": "minimize button",
        "AXZoomButton": "zoom button",
        "AXFullScreenButton": "full screen button",
        "AXToolbarButton": "toolbar button",
        "AXSortButton": "sort button",
        "AXCollapseButton": "collapse button",
        "AXToggle": "toggle",
        "AXSwitch": "switch",
        "AXContentList": "content list",
        "AXDefinitionList": "definition list",
        "AXDescriptionList": "description list",
        "AXSectionList": "section list",
        "AXTimeline": "timeline",
        "AXRatingIndicator": "rating indicator",
        "AXIncrementArrow": "increment arrow",
        "AXDecrementArrow": "decrement arrow",
    ]

    /// Roles, humanized. Covers what the shim's walks actually meet: native
    /// AppKit chrome, the web roles Electron and browsers report, and the text
    /// roles the capture exists for.
    static let roleWords: [String: String] = [
        "AXApplication": "application",
        "AXWindow": "standard window",
        "AXSheet": "sheet",
        "AXDrawer": "drawer",
        "AXPopover": "popover",
        "AXGroup": "container",
        "AXSplitGroup": "split group",
        "AXSplitter": "splitter",
        "AXScrollArea": "scroll area",
        "AXScrollBar": "scroll bar",
        "AXLayoutArea": "layout area",
        "AXLayoutItem": "layout item",
        "AXWebArea": "HTML content",
        "AXStaticText": "text",
        "AXTextArea": "text input",
        "AXTextField": "text field",
        "AXHeading": "heading",
        "AXButton": "button",
        "AXPopUpButton": "pop-up button",
        "AXMenuButton": "menu button",
        "AXCheckBox": "checkbox",
        "AXRadioButton": "radio button",
        "AXRadioGroup": "radio group",
        "AXDisclosureTriangle": "disclosure triangle",
        "AXComboBox": "combo box",
        "AXIncrementor": "stepper",
        "AXSlider": "slider",
        "AXProgressIndicator": "progress indicator",
        "AXBusyIndicator": "busy indicator",
        "AXValueIndicator": "value indicator",
        "AXLevelIndicator": "level indicator",
        "AXTabGroup": "tab group",
        "AXToolbar": "toolbar",
        "AXLink": "link",
        "AXImage": "image",
        "AXList": "list",
        "AXOutline": "outline",
        "AXTable": "table",
        "AXRow": "row",
        "AXColumn": "column",
        "AXCell": "cell",
        "AXGrid": "grid",
        "AXMenu": "menu",
        "AXMenuItem": "menu item",
        "AXMenuBar": "menu bar",
        "AXMenuBarItem": "menu bar item",
        "AXToolbarItem": "toolbar item",
        "AXRuler": "ruler",
        "AXRelevanceIndicator": "relevance indicator",
        "AXGenericElement": "element",
        "AXUnknown": "unknown element",
    ]

    /// The word for a node. Unknown roles are not dropped — they pass through
    /// without their `AX` prefix, lowercased, because an app inventing a role is
    /// still telling us something and a blank line tells us nothing.
    package static func word(role: String?, subrole: String?) -> String {
        if let subrole, let mapped = subroleWords[subrole] { return mapped }
        if let role, let mapped = roleWords[role] { return mapped }
        guard let role else { return "element" }
        var stripped = Substring(role)
        if stripped.hasPrefix("AX") { stripped = stripped.dropFirst(2) }
        let lowered = stripped.lowercased()
        return lowered.isEmpty ? "element" : lowered
    }
}

/// One rendered line of a tree, and everything the diff needs to align it.
package struct RenderedLine: Equatable, Sendable {
    /// DFS position among the *emitted* lines, starting at 0. A number that
    /// names no line could never be cited, so collapsed-away nodes take no
    /// numbers. Measured: numbering drifts between frames (966/2,073 labels
    /// moved), so a citation is only ever valid against its own frame.
    package let number: Int
    /// Tab depth.
    package let depth: Int
    /// Raw AX role, for alignment.
    package let role: String?
    /// The label the line carries, for alignment.
    package let label: String
    /// Everything after the number: role word, `(collapsed)`, label, attributes.
    package let body: String
    package let collapsed: Bool
    /// Index into `RenderedTree.lines` of the parent line, if any.
    package let parent: Int?
    /// This line plus its emitted descendants. Since numbering is DFS, a
    /// subtree owns the contiguous range `number ..< number + subtreeLineCount`
    /// — which is why a removed subtree coalesces into one ID range.
    package fileprivate(set) var subtreeLineCount: Int

    /// The line as it appears in a full tree, without indentation.
    package var text: String { "\(number) \(body)" }
}

/// A tree rendered to numbered, indented text.
package struct RenderedTree: Equatable, Sendable {
    /// Lines in DFS order; `lines[i].number == i`.
    package let lines: [RenderedLine]

    package init(lines: [RenderedLine]) {
        self.lines = lines
    }

    /// The full-tree text — what a keyframe emits.
    package var text: String {
        lines.map { String(repeating: "\t", count: $0.depth) + $0.text }
            .joined(separator: "\n")
    }

    package var isEmpty: Bool { lines.isEmpty }
}

/// Renders a `CaptureTreeNode` into numbered indented text
/// (docs/event-capture-v2-plan.md §4).
///
/// ```
/// 0 standard window Feishu
/// 	1 container ContentsView
/// 		33 button (collapsed) 更多操作, Description: 归档会话
/// 		34 HTML content messenger, URL: file:///Applications/Lark.app/…/en-US.html
/// ```
///
/// Why text and not the JSON the shim already emits: measured, the JSON tree
/// runs ~200 KB per frame while this encoding's diffs have a 913 B median. The
/// win is both storage and prompt budget, and it is only available because the
/// text is line-oriented and stable enough to diff.
package enum CaptureTreeText {
    /// Longest attribute or label text kept on one line. A document body can be
    /// megabytes; past a few hundred characters a single node has stopped being
    /// context and started being the whole prompt. The clip is announced rather
    /// than silent — a model must never read a cut-off value as the full one.
    package static let maxTextChars = 300
    /// Appended to anything `maxTextChars` cut.
    package static let truncationMarker = " [truncated]"

    /// Roles that are layout, not content. Their own title and description are
    /// chrome labels ("Sidebar", "ContentsView"), so they do not by themselves
    /// keep a subtree from collapsing — otherwise an Electron app's container
    /// soup, where every third `AXGroup` is named, never collapses at all.
    static let chromeRoles: Set<String> = [
        "AXGroup",
        "AXScrollArea",
        "AXSplitGroup",
        "AXSplitter",
        "AXScrollBar",
        "AXLayoutArea",
        "AXLayoutItem",
        "AXGenericElement",
        "AXUnknown",
    ]

    package static func render(_ root: CaptureTreeNode) -> RenderedTree {
        var lines: [RenderedLine] = []
        appendLines(for: root, depth: 0, parent: nil, into: &lines)
        return RenderedTree(lines: lines)
    }

    @discardableResult
    private static func appendLines(
        for node: CaptureTreeNode,
        depth: Int,
        parent: Int?,
        into lines: inout [RenderedLine]
    ) -> Int {
        let index = lines.count
        let collapsed = isCollapsible(node)
        let label = label(for: node, collapsed: collapsed)
        lines.append(
            RenderedLine(
                number: index,
                depth: depth,
                role: node.role,
                label: label,
                body: body(for: node, label: label, collapsed: collapsed),
                collapsed: collapsed,
                parent: parent,
                subtreeLineCount: 1
            )
        )
        if !collapsed {
            for child in node.children {
                appendLines(for: child, depth: depth + 1, parent: index, into: &lines)
            }
        }
        lines[index].subtreeLineCount = lines.count - index
        return index
    }

    // MARK: - Line text

    private static func body(for node: CaptureTreeNode, label: String, collapsed: Bool) -> String {
        var body = CaptureRoleVocabulary.word(role: node.role, subrole: node.subrole)
        if collapsed { body += " (collapsed)" }
        if !label.isEmpty { body += " " + label }
        if let url = clean(node.url) { body += ", URL: " + url }
        if let document = clean(node.document), document != clean(node.url) {
            body += ", Document: " + document
        }
        // The description is an attribute unless it is already carrying the
        // line as its label; repeating it would only cost prompt budget.
        if let description = clean(node.nodeDescription), description != label {
            body += ", Description: " + description
        }
        if let value = clean(node.value) { body += ", Value: " + value }
        return body
    }

    /// title → description → (for a collapsed chain) the first labelled node
    /// underneath. The last rung is what keeps an anonymous wrapper around a
    /// named container from collapsing into an unreadable `container (collapsed)`.
    static func label(for node: CaptureTreeNode, collapsed: Bool) -> String {
        if let title = clean(node.title) { return title }
        if let description = clean(node.nodeDescription) { return description }
        guard collapsed else { return "" }
        for child in node.children {
            let inherited = descendantLabel(child)
            if !inherited.isEmpty { return inherited }
        }
        return ""
    }

    private static func descendantLabel(_ node: CaptureTreeNode) -> String {
        if let title = clean(node.title) { return title }
        if let description = clean(node.nodeDescription) { return description }
        for child in node.children {
            let inherited = descendantLabel(child)
            if !inherited.isEmpty { return inherited }
        }
        return ""
    }

    /// Whitespace-collapsed and length-clipped, or nil when there is nothing
    /// left. Collapsing is not cosmetic: the encoding is line-oriented, and one
    /// newline inside a title would silently forge a tree line.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.isEmpty { return nil }
        guard collapsed.count > maxTextChars else { return collapsed }
        return String(collapsed.prefix(maxTextChars)) + truncationMarker
    }

    // MARK: - Collapsing

    /// Whether a node's whole subtree may be replaced by one `(collapsed)` line:
    /// it has children, and not one of them carries text.
    static func isCollapsible(_ node: CaptureTreeNode) -> Bool {
        guard !node.children.isEmpty else { return false }
        return !node.children.contains { carriesTextAnywhere($0) }
    }

    private static func carriesTextAnywhere(_ node: CaptureTreeNode) -> Bool {
        if carriesText(node) { return true }
        return node.children.contains { carriesTextAnywhere($0) }
    }

    /// A node carries text when it holds content: a value, a URL, a document —
    /// or, unless it is pure layout, a title or a description.
    static func carriesText(_ node: CaptureTreeNode) -> Bool {
        if clean(node.value) != nil || clean(node.url) != nil || clean(node.document) != nil {
            return true
        }
        if let role = node.role, chromeRoles.contains(role) { return false }
        return clean(node.title) != nil || clean(node.nodeDescription) != nil
    }
}
