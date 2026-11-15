import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

struct DiskVolume: Equatable, Sendable {
    var name: String
    var path: String
    var format: String
    /// Bytes; used space is `total - available`.
    var total: Int64
    var available: Int64
    var isLocal: Bool
    var ejectable: Bool
    /// BSD name of the physical drive, such as `disk4`; nil for a network share.
    var drive: String?
    /// A disk image such as an installer reports no free space, which isn't a full disk.
    var isReadOnly = false
}

struct DiskVolumes: Equatable, Sendable {
    var startup: DiskVolume
    var others: [DiskVolume]
}

func diskSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func diskOutput(_ volumes: DiskVolumes, warning: Double, critical: Double) -> ScriptOutput {
    let startup = volumes.startup
    let used = startup.total - startup.available
    let fraction = startup.total > 0 ? Double(used) / Double(startup.total) : 0
    let listed = volumes.others.filter { $0.total > 0 }
    let rows = listed.map { volume -> [String: String] in
        let used = volume.total - volume.available
        let fraction = Double(used) / Double(volume.total)
        let sharing = listed.filter { $0.drive != nil && $0.drive == volume.drive && $0 != volume }
        return ["name": volume.name, "path": volume.path,
                "symbol": volume.isLocal ? "externaldrive" : "externaldrive.connected.to.line.below",
                "percent": diskPercent(fraction), "fraction": String(fraction),
                "used": diskSize(used), "free": diskSize(volume.available), "total": diskSize(volume.total),
                "state": volume.isReadOnly ? "" : diskState(fraction, warning: warning, critical: critical) ?? "",
                "ejectable": volume.ejectable ? "true" : "", "drive": volume.drive ?? "",
                "driveVolumes": sharing.map(\.name).joined(separator: ", ")]
    }
    var output = ScriptOutput(
        text: "\(diskPercent(fraction))%", icon: "internaldrive",
        tooltip: "\(diskSize(startup.available)) available on \(startup.name)",
        fields: ["percent": diskPercent(fraction), "volume": startup.name, "format": startup.format,
                 "used": diskSize(used), "free": diskSize(startup.available), "total": diskSize(startup.total)],
        lists: ["volumes": rows],
        values: ["disk": fraction, "used": Double(used), "free": Double(startup.available),
                 "total": Double(startup.total)])
    if let state = diskState(fraction, warning: warning, critical: critical) { output.state = .string(state) }
    return output
}

/// Important usage adds purgeable space, but volumes other than the startup disk report it as 0, not nil.
func diskAvailable(important: Int64?, plain: Int64?) -> Int64 {
    if let important, important > 0 { return important }
    return plain ?? 0
}

private func diskPercent(_ fraction: Double) -> String { String(Int((fraction * 100).rounded())) }

/// Strictly above a threshold, like `SystemWarnings`; a threshold above 1 never triggers.
private func diskState(_ fraction: Double, warning: Double, critical: Double) -> String? {
    if fraction > critical { return "critical" }
    return fraction > warning ? "warning" : nil
}

/// Reads the mounted volumes. Blocking: a network share can stall, so callers go through `BlockingWork.run`.
protocol VolumeReading: Sendable {
    func read() throws -> DiskVolumes
}

/// The startup disk and the volumes Finder shows, from Foundation's volume resource values.
struct SystemVolumes: VolumeReading {
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey
    ]

    func read() throws -> DiskVolumes {
        let session = DASessionCreate(kCFAllocatorDefault)
        guard let startup = try volume(at: URL(filePath: "/"), session: session) else {
            throw CommandFailure(message: "Couldn't read the startup disk.")
        }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        // On APFS the startup disk also mounts its data, preboot and other volumes under /System/Volumes.
        let others = urls.compactMap { url -> DiskVolume? in
            guard (try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem != true,
                  !Self.path(of: url).hasPrefix("/System/Volumes/") else { return nil }
            return try? volume(at: url, session: session)
        }
        return DiskVolumes(startup: startup, others: others)
    }

    private func volume(at url: URL, session: DASession?) throws -> DiskVolume? {
        let values = try url.resourceValues(forKeys: Set(Self.keys))
        guard let total = values.volumeTotalCapacity.map(Int64.init) else { return nil }
        let available = diskAvailable(important: values.volumeAvailableCapacityForImportantUsage,
                                      plain: values.volumeAvailableCapacity.map(Int64.init))
        let isLocal = values.volumeIsLocal ?? true
        let ejectable = values.volumeIsInternal != true || values.volumeIsEjectable == true
            || values.volumeIsRemovable == true || !isLocal
        return DiskVolume(name: values.volumeLocalizedName ?? url.lastPathComponent, path: Self.path(of: url),
                          format: values.volumeLocalizedFormatDescription ?? "", total: total,
                          available: min(max(available, 0), total), isLocal: isLocal, ejectable: ejectable,
                          drive: session.flatMap { Self.drive(of: url, session: $0) },
                          isReadOnly: values.volumeIsReadOnly == true)
    }

    private static func path(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The BSD name of the topmost whole `IOMedia` above the volume, so an APFS volume maps to its physical disk
    /// rather than to its synthesized container. Nil for volumes without a disk, such as network shares.
    private static func drive(of url: URL, session: DASession) -> String? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        var entry = DADiskCopyIOMedia(disk)
        var whole: String?
        while entry != 0 {
            if IOObjectConformsTo(entry, kIOMediaClass) != 0,
               IORegistryEntryCreateCFProperty(entry, kIOMediaWholeKey as CFString, kCFAllocatorDefault, 0)?
                   .takeRetainedValue() as? Bool == true,
               let name = IORegistryEntryCreateCFProperty(entry, kIOBSDNameKey as CFString, kCFAllocatorDefault, 0)?
                   .takeRetainedValue() as? String {
                whole = name
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = status == KERN_SUCCESS ? parent : 0
        }
        return whole
    }
}
