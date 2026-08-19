/// Which of the two questions the single overlay input is asking. Search reads
/// the index; ask hands the text to the chat agent. One field serves both so
/// the overlay opens with one line rather than a choice.
public enum ImmersiveQueryMode: String, CaseIterable, Equatable, Sendable {
    case search
    case ask

    public var title: String { title(.english) }

    public func title(_ copy: AfterRayCopy) -> String {
        switch self {
        case .search: copy.recall.search
        case .ask: copy.recall.ask
        }
    }

    public var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .ask: "sparkle"
        }
    }

    /// The placeholder carries the Tab affordance — it is the only place the
    /// shortcut is discoverable, since the mode chip shows where you are, not
    /// how to leave.
    public var placeholder: String { placeholder(.english) }

    public func placeholder(_ copy: AfterRayCopy) -> String {
        switch self {
        case .search: copy.recall.searchPlaceholder
        case .ask: copy.recall.askPlaceholder
        }
    }

    public var toggleHelp: String { toggleHelp(.english) }

    public func toggleHelp(_ copy: AfterRayCopy) -> String {
        switch self {
        case .search: copy.recall.switchToAsking
        case .ask: copy.recall.switchToSearch
        }
    }

    public mutating func toggle() {
        self = self == .search ? .ask : .search
    }
}
