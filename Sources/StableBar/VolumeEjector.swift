import Foundation

/// What an eject takes: every volume on the drive, or only the one volume.
enum EjectScope: Sendable { case drive, volume }

struct VolumeEjector: Sendable {
    var unmount: @Sendable (URL, FileManager.UnmountOptions) async throws -> Void

    static let live = VolumeEjector { try await FileManager.default.unmountVolume(at: $0, options: $1) }

    /// A network share has no disk to eject, so it only unmounts.
    static func options(_ scope: EjectScope, isLocal: Bool) -> FileManager.UnmountOptions {
        scope == .drive && isLocal ? [.allPartitionsAndEjectDisk, .withoutUI] : [.withoutUI]
    }

    /// Reads `volumeIsLocalKey` for `path`, then unmounts with `options(scope, isLocal:)`.
    func eject(_ path: String, _ scope: EjectScope) async throws {
        let url = URL(fileURLWithPath: path)
        let isLocal = try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal ?? true
        try await unmount(url, Self.options(scope, isLocal: isLocal))
    }
}
