import Foundation

@MainActor
public final class AfterRayControlModel: ObservableObject {
    @Published public private(set) var status: DaemonStatus?
    @Published public private(set) var isChangingRecording = false
    @Published public var searchQuery = ""
    @Published public private(set) var searchSession: RecallSearchSession?
    @Published public private(set) var isSearching = false
    @Published public var askQuestion = ""
    @Published public private(set) var askAnswer: AskAnswer?
    @Published public private(set) var isAsking = false
    @Published public private(set) var askMessage: String?
    @Published public private(set) var message: String?

    private let daemon: any AfterRayDaemonServing
    private var sensitiveGeneration: UInt64 = 0

    public init(daemon: any AfterRayDaemonServing) {
        self.daemon = daemon
    }

    public var isRecording: Bool { status?.recordingState == .recording }
    public var isWaitingToRecord: Bool { status?.recordingState == .waiting }
    public var isCaptureSessionActive: Bool {
        switch status?.recordingState {
        case .waiting, .recording, .stopping: return true
        default: return false
        }
    }
    public var canToggleRecording: Bool {
        !isChangingRecording && status?.recordingState != .stopping
    }

    public func refreshStatus() async {
        do {
            status = try await daemon.status()
            message = nil
        } catch {
            status = nil
            message = error.localizedDescription
        }
    }

    /// Starts capture when the daemon is idle. Calling this repeatedly is safe.
    @discardableResult
    public func ensureRecording() async -> Bool {
        await refreshStatus()
        guard status?.recordingState == .idle || status == nil else {
            return isCaptureSessionActive
        }
        AfterRayLog.info("ensureRecording: starting capture")
        isChangingRecording = true
        markWaitingOptimistically()
        defer { isChangingRecording = false }
        do {
            _ = try await daemon.recordStart()
            status = try await daemon.status()
            message = nil
            AfterRayLog.info(
                "ensureRecording: state=\(status?.recordingState.rawValue ?? "nil")"
            )
            return isCaptureSessionActive
        } catch {
            AfterRayLog.error("ensureRecording: \(error.localizedDescription)")
            message = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func toggleRecording() async -> Bool {
        guard canToggleRecording else { return false }
        isChangingRecording = true
        defer { isChangingRecording = false }
        do {
            if isCaptureSessionActive {
                _ = try await daemon.recordStop(reason: "pause")
            } else {
                markWaitingOptimistically()
                _ = try await daemon.recordStart()
            }
            status = try await daemon.status()
            message = nil
            return true
        } catch {
            AfterRayLog.error("toggleRecording: \(error.localizedDescription)")
            message = error.localizedDescription
            return false
        }
    }

    /// Runs the query and returns the frame to jump to, which is the newest
    /// match. Returns `nil` when nothing matched or the query was empty.
    @discardableResult
    public func search() async -> SearchFrame? {
        let requestGeneration = sensitiveGeneration
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchSession = nil
            message = nil
            return nil
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let hits = try await daemon.search(query: query, limit: 60)
            guard sensitiveGeneration == requestGeneration else { return nil }
            searchSession = RecallSearchSession.make(query: query, hits: hits)
            message = searchSession == nil ? "No moments matched “\(query)”." : nil
            return searchSession?.selectedFrame
        } catch {
            guard sensitiveGeneration == requestGeneration else { return nil }
            searchSession = nil
            message = error.localizedDescription
            return nil
        }
    }

    /// Moves the filmstrip selection and reports the frame now under it.
    @discardableResult
    public func selectFrame(at index: Int) -> SearchFrame? {
        guard var session = searchSession, session.frames.indices.contains(index) else {
            return nil
        }
        guard index != session.selectedIndex else { return session.selectedFrame }
        session.selectedIndex = index
        searchSession = session
        return session.selectedFrame
    }

    @discardableResult
    public func stepFrame(by delta: Int) -> SearchFrame? {
        guard let session = searchSession else { return nil }
        return selectFrame(at: session.steppedIndex(by: delta))
    }

    public func dismissSearch() {
        searchQuery = ""
        searchSession = nil
        message = nil
    }

    public func ask() async {
        let requestGeneration = sensitiveGeneration
        let question = askQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            askAnswer = nil
            askMessage = nil
            return
        }
        isAsking = true
        defer { isAsking = false }
        do {
            let answer = try await daemon.ask(question: question, fromMs: nil, toMs: nil)
            guard sensitiveGeneration == requestGeneration else { return }
            askAnswer = answer
            askMessage = nil
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            askAnswer = nil
            askMessage = error.localizedDescription
        }
    }

    public func dismissAsk() {
        askQuestion = ""
        askAnswer = nil
        askMessage = nil
    }

    public func clearSensitiveState() {
        sensitiveGeneration &+= 1
        status = nil
        searchQuery = ""
        searchSession = nil
        isSearching = false
        askQuestion = ""
        askAnswer = nil
        isAsking = false
        askMessage = nil
        message = nil
    }

    private func markWaitingOptimistically() {
        if let status {
            self.status = DaemonStatus(
                daemonVersion: status.daemonVersion,
                protocolVersion: status.protocolVersion,
                schemaVersion: status.schemaVersion,
                recordingState: .waiting,
                activeSessionId: status.activeSessionId
            )
        }
    }
}
