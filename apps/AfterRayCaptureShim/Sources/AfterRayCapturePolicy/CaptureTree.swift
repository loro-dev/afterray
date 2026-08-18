/// The shape of an accessibility tree, with everything the shim knows about how
/// it was obtained left behind (docs/event-capture-v2-plan.md §4).
///
/// The shim walks live `AXUIElement`s and encodes them into its own
/// `AccessibilityNode`; that walk needs the Accessibility APIs and cannot run in
/// a test. `CaptureTreeNode` is the same information as a value type, so the
/// text encoding and the diff — the parts that decide what a model ever gets to
/// read — are pure and exhaustively testable. The shim maps its node into this
/// one; nothing here imports AppKit or ApplicationServices.
package struct CaptureTreeNode: Equatable, Sendable {
    /// The raw AX role (`AXWindow`, `AXGroup`, …). Kept raw: the humanized
    /// vocabulary is a rendering concern, and the raw role is what the diff
    /// aligns on.
    package var role: String?
    /// The raw AX subrole (`AXStandardWindow`, `AXTabButton`, …). Refines the
    /// role word when it is one the vocabulary knows.
    package var subrole: String?
    package var title: String?
    /// `AXDescription` — spelled out to avoid shadowing `CustomStringConvertible`.
    package var nodeDescription: String?
    package var value: String?
    package var url: String?
    package var document: String?
    /// Screen rectangle, if the walk resolved one. Not rendered: the text
    /// encoding is for reading, and coordinates are how the *renderer* of an
    /// `afterray://moment/<id>#el<N>` citation crops a screenshot later
    /// (plan §6), not something a model should be asked to interpret.
    package var frame: CaptureTreeFrame?
    package var children: [CaptureTreeNode]

    package init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        nodeDescription: String? = nil,
        value: String? = nil,
        url: String? = nil,
        document: String? = nil,
        frame: CaptureTreeFrame? = nil,
        children: [CaptureTreeNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.nodeDescription = nodeDescription
        self.value = value
        self.url = url
        self.document = document
        self.frame = frame
        self.children = children
    }
}

/// An element rectangle in screen points, rounded to integers — the precision a
/// crop needs and no more.
package struct CaptureTreeFrame: Equatable, Sendable {
    package var x: Int
    package var y: Int
    package var width: Int
    package var height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
