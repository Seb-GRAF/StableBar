import Foundation
import Testing
@testable import StableBar

private func volume(_ name: String, total: Int64, available: Int64, format: String = "APFS",
                    local: Bool = true, ejectable: Bool = true, drive: String? = nil) -> DiskVolume {
    DiskVolume(name: name, path: name == "Macintosh HD" ? "/" : "/Volumes/\(name)", format: format,
               total: total, available: available, isLocal: local, ejectable: ejectable, drive: drive)
}

private let fixture = DiskVolumes(
    startup: volume("Macintosh HD", total: 994_000_000_000, available: 412_000_000_000, ejectable: false, drive: "disk0"),
    others: [
        volume("Backup", total: 2_000_000_000_000, available: 1_180_000_000_000, drive: "disk4"),
        volume("Photos", total: 500_000_000_000, available: 300_000_000_000, drive: "disk4"),
        volume("NAS", total: 4_000_000_000_000, available: 3_900_000_000_000, format: "SMB", local: false, ejectable: true),
        volume("Empty", total: 0, available: 0)
    ])

@Test func diskOutputShowsTheStartupDiskOnTheBar() {
    let output = diskOutput(fixture, warning: 0.85, critical: 0.95)
    #expect(output.text == "59%")
    #expect(output.icon == "internaldrive")
    #expect(output.value == nil)
    #expect(output.tooltip == "412 GB available on Macintosh HD")
    #expect(output.fields == ["percent": "59", "volume": "Macintosh HD", "format": "APFS",
                              "used": "582 GB", "free": "412 GB", "total": "994 GB"])
    #expect(output.values?["disk"] == 582.0 / 994.0)
    #expect(output.values?["used"] == 582e9 && output.values?["free"] == 412e9 && output.values?["total"] == 994e9)
    #expect(output.state == nil)
}

@Test func diskOutputListsOtherVolumesWithTheirDrive() {
    let rows = diskOutput(fixture, warning: 0.85, critical: 0.95).lists?["volumes"] ?? []
    #expect(rows.map { $0["name"] } == ["Backup", "Photos", "NAS"])          // Empty (no capacity) left out
    #expect(rows[0]["driveVolumes"] == "Photos" && rows[1]["driveVolumes"] == "Backup")
    #expect(rows[2]["driveVolumes"] == "" && rows[2]["drive"] == "")
    #expect(rows[0]["free"] == diskSize(1_180_000_000_000) && rows[0]["percent"] == "41" && rows[0]["fraction"] == "0.41")
    #expect(rows[0]["symbol"] == "externaldrive")
    #expect(rows[2]["symbol"] == "externaldrive.connected.to.line.below")
    #expect(rows[0]["ejectable"] == "true")
    #expect(rows[0]["path"] == "/Volumes/Backup" && rows[0]["drive"] == "disk4")
}

@Test func diskRowsLeaveEjectableEmptyWhenTheVolumeStays() {
    let startup = volume("Macintosh HD", total: 1_000, available: 500, ejectable: false)
    let others = DiskVolumes(startup: startup, others: [volume("Fixed", total: 1_000, available: 500, ejectable: false)])
    #expect(diskOutput(others, warning: 0.85, critical: 0.95).lists?["volumes"]?.first?["ejectable"] == "")
}

// Startup total 1_000_000_000_000; exact byte counts so no rounding crosses a threshold.
@Test(arguments: [(150_000_000_000, ""), (149_000_000_000, "warning"), (50_000_000_000, "warning"),
                  (49_000_000_000, "critical")] as [(Int64, String)])
func diskStateIsStrictlyAboveItsThreshold(available: Int64, state: String) {
    let expected: ConfigurationValue? = state.isEmpty ? nil : .string(state)
    let total: Int64 = 1_000_000_000_000
    let volumes = DiskVolumes(startup: volume("Macintosh HD", total: total, available: available),
                              others: [volume("Other", total: total, available: available)])
    let output = diskOutput(volumes, warning: 0.85, critical: 0.95)
    #expect(output.state == expected)
    #expect(output.lists?["volumes"]?.first?["state"] == state)
}

@Test func diskThresholdsAbove100PercentTurnWarningsOff() {
    let startup = volume("Macintosh HD", total: 1_000_000_000_000, available: 10_000_000_000)
    let output = diskOutput(DiskVolumes(startup: startup, others: [startup]), warning: 1.01, critical: 1.01)
    #expect(output.state == nil)
    #expect(output.lists?["volumes"]?.first?["state"] == "")
}
