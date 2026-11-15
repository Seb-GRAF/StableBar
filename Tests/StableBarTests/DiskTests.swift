import AppKit
import Foundation
import os
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

private final class FakeVolumes: VolumeReading {
    private let result: @Sendable () throws -> DiskVolumes
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(_ result: @escaping @Sendable () throws -> DiskVolumes) { self.result = result }

    var reads: Int { count.withLock { $0 } }

    func read() throws -> DiskVolumes {
        count.withLock { $0 += 1 }
        return try result()
    }
}

private func diskProvider(_ properties: [String: ConfigurationValue] = [:]) throws -> ProviderConfiguration {
    try ConfigurationValue.object(properties.merging(["type": .string("disk")]) { _, type in type })
        .decoded(ProviderConfiguration.self)
}

@Test func diskProvidersDefaultToAMinuteAndTheirThresholds() throws {
    let decoded = try ConfigurationValue.object(["type": .string("disk")]).decoded(ProviderConfiguration.self)
    #expect(decoded.interval == 60 && decoded.diskWarning == 0.85 && decoded.diskCritical == 0.95)
    #expect(ProviderConfiguration(type: "disk").interval == 60)
    #expect(ProviderConfiguration(type: "network").interval == 5)
}

@Test func aDiskWidgetLoadsWithAnImplicitProvider() throws {
    var loader = ConfigurationLoader()
    let configuration = try loader.load(FileManager.default.temporaryDirectory.appending(path: "disk.json"), data: Data(#"""
    {"widgets":[{"id":"disk","type":"disk","position":"right","details":true}]}
    """#.utf8))
    #expect(configuration.widgets.first?.content == .provider("disk"))
    #expect(configuration.providers["disk"]?.interval == 60)
}

@Test @MainActor func theDiskSourceReadsWithItsThresholdsAndRefreshesOnMount() async throws {
    let volumes = FakeVolumes { fixture }
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: try diskProvider(["diskWarning": .number(0.5)]),
                 registry: DataSourceRegistry(types: [.disk(reader: volumes)]))
    try await awaitCondition { script.output.text == "59%" && script.output.state == .string("warning") }
    try await awaitCondition { !script.diagnostics.running }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
    try await awaitCondition { volumes.reads == 2 }
}

@Test @MainActor func aFailedDiskReadShowsTheProviderError() async throws {
    let volumes = FakeVolumes { throw CommandFailure(message: "No startup volume.") }
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: try diskProvider(), registry: DataSourceRegistry(types: [.disk(reader: volumes)]))
    try await awaitCondition { script.error == "No startup volume." }
}

@Test @MainActor func aSlowVolumeReadKeepsTheMainActorFree() async throws {
    let release = DispatchSemaphore(value: 0)
    let volumes = FakeVolumes {
        release.wait()
        return fixture
    }
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: try diskProvider(), registry: DataSourceRegistry(types: [.disk(reader: volumes)]))
    try await awaitCondition { volumes.reads == 1 }
    var ticks = 0
    let ticker = Task { @MainActor in
        while !Task.isCancelled {
            ticks += 1
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    defer { ticker.cancel() }
    try await awaitCondition { ticks >= 3 }
    #expect(script.output.text == "…")
    release.signal()
    try await awaitCondition { script.output.text == "59%" }
}

@Test func theLiveReaderKeepsTheStartupDisksOwnVolumesOutOfTheList() throws {
    let volumes = try SystemVolumes().read()
    #expect(volumes.startup.path == "/" && volumes.startup.total > 0)
    #expect(!volumes.others.contains { $0.path == "/" || $0.path.hasPrefix("/System/Volumes/") })
}

private final class RecordedUnmounts: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [(url: URL, options: FileManager.UnmountOptions)]())
    var all: [(url: URL, options: FileManager.UnmountOptions)] { lock.withLock { $0 } }
    func append(_ url: URL, _ options: FileManager.UnmountOptions) { lock.withLock { $0.append((url, options)) } }
}

@Test func ejectingADriveEjectsEveryPartitionButANetworkShareOnlyUnmounts() {
    #expect(VolumeEjector.options(.drive, isLocal: true) == [.allPartitionsAndEjectDisk, .withoutUI])
    #expect(VolumeEjector.options(.volume, isLocal: true) == [.withoutUI])
    #expect(VolumeEjector.options(.drive, isLocal: false) == [.withoutUI])
}

@Test func ejectUnmountsThePathItWasGiven() async throws {
    let recorded = RecordedUnmounts()
    let ejector = VolumeEjector { recorded.append($0, $1) }
    try await ejector.eject(NSTemporaryDirectory(), .drive)
    let unmounts = recorded.all
    #expect(unmounts.count == 1)
    #expect(unmounts.first?.url.path == URL(fileURLWithPath: NSTemporaryDirectory()).path)
    #expect(unmounts.first?.options == VolumeEjector.options(.drive, isLocal: true))
}

@Test func aRefusedEjectReachesTheCaller() async {
    let ejector = VolumeEjector { _, _ in throw CocoaError(.fileWriteUnknown) }
    await #expect(throws: CocoaError.self) {
        try await ejector.eject(NSTemporaryDirectory(), .volume)
    }
}

@Test func aPopupTakesItsStateAccentsFromTheStatesTheWidgetStyles() throws {
    let style = try JSONDecoder().decode(WidgetStyle.self, from: Data("""
    {"accent": "#112233", "states": {"warning": {"accent": "#aabbcc"}, "critical": {"foreground": "#ffffff"}}}
    """.utf8))
    let accents = popupStateAccents(style, mode: ModePresentation())
    #expect(accents.keys.sorted() == ["warning"])
    #expect(accents["warning"] == HexColor(0xaabbccff).color)
}
