/// Which of the two questions the single overlay input is asking. Search reads
/// the index; ask hands the text to the chat agent. One field serves both so
/// the overlay opens with one line rather than a choice.
public enum ImmersiveQueryMode: String, CaseIterable, Equatable, Sendable {
    case search
    case ask

    public var title: String {
        switch self {
        case .search: "Search"
        case .ask: "Ask"
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
    public var placeholder: String {
        switch self {
        case .search: "Search your day — Tab to ask"
        case .ask: "Ask about your day — Tab to search"
        }
    }

    public var toggleHelp: String {
        switch self {
        case .search: "Switch to asking"
        case .ask: "Switch to search"
        }
    }

    public mutating func toggle() {
        self = self == .search ? .ask : .search
    }
}
