import Foundation

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
                "state": diskState(fraction, warning: warning, critical: critical) ?? "",
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

private func diskPercent(_ fraction: Double) -> String { String(Int((fraction * 100).rounded())) }

/// Strictly above a threshold, like `SystemWarnings`; a threshold above 1 never triggers.
private func diskState(_ fraction: Double, warning: Double, critical: Double) -> String? {
    if fraction > critical { return "critical" }
    return fraction > warning ? "warning" : nil
}
