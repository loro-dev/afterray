import AVFoundation
import Foundation

/// Prepared off the main actor, then transferred once to `ArtifactAudioPlayer`.
/// AVFoundation does not declare `AVAudioPlayer` Sendable, but this wrapper has
/// a strict ownership handoff: the repository creates it, and the MainActor is
/// its sole owner after the async call returns.
final class PreparedArtifactAudio: @unchecked Sendable {
    let player: AVAudioPlayer
    let sensitiveData: SensitiveAudioData

    init(player: AVAudioPlayer, sensitiveData: SensitiveAudioData) {
        self.player = player
        self.sensitiveData = sensitiveData
    }
}

/// Explicit-playback artifact path. Audio bytes never enter the screenshot /
/// GOP cache, so a long recording cannot evict the frames needed by a scrub.
public actor RecallAudioRepository {
    private let daemon: any RecallDaemonServing

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
    }

    public func data(artifactID: String) async throws -> Data {
        try Task.checkCancellation()
        let bytes = try await daemon.artifact(id: artifactID).bytes
        try Task.checkCancellation()
        return bytes
    }

    // @dec:settled-search-evidence-and-off-main-audio-prepare — docs/decisions/active/architecture/2026-08-25-settled-search-evidence-and-off-main-audio-prepare.md
    /// Copies decrypted bytes and asks AVFoundation to parse/prepare them on
    /// this audio actor. The MainActor receives only the ready player and the
    /// one sensitive buffer it must retain for pause/resume.
    func preparedAudio(artifactID: String) async throws -> PreparedArtifactAudio {
        var bytes = try await data(artifactID: artifactID)
        defer {
            bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
        }
        try Task.checkCancellation()

        let sensitiveData = SensitiveAudioData(copying: bytes)
        do {
            let player = try AVAudioPlayer(data: sensitiveData.playerData)
            player.prepareToPlay()
            try Task.checkCancellation()
            return PreparedArtifactAudio(
                player: player,
                sensitiveData: sensitiveData
            )
        } catch {
            sensitiveData.clear()
            throw error
        }
    }

    /// A cancelled generation never hands its decrypted buffer back to the UI
    /// actor merely to erase it there.
    func discard(_ prepared: PreparedArtifactAudio) {
        prepared.player.stop()
        prepared.sensitiveData.clear()
    }

    func clear(_ sensitiveData: SensitiveAudioData) {
        sensitiveData.clear()
    }
}
