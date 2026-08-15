import Foundation

/// Stable, short socket paths for development checkouts.
///
/// macOS limits Unix-domain socket paths to roughly one hundred bytes. Lody
/// worktrees regularly exceed that before `.afterray-dev/afterray.sock` is
/// appended, so the checkout path is used as an identity instead of as the
/// socket's parent directory.
public enum AfterRaySocketPath {
    public static func development(repoRoot: URL) -> String {
        development(
            repoRoot: repoRoot,
            cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        )
    }

    static func development(repoRoot: URL, cacheDirectory: URL) -> String {
        let checkout = repoRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let token = String(format: "%016llx", fnv1a64(checkout.utf8))
        return cacheDirectory
            .appendingPathComponent("AfterRay/DevSockets", isDirectory: true)
            .appendingPathComponent("\(token).sock")
            .path
    }

    static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
