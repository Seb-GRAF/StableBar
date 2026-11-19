import Foundation
import Testing
@testable import StableBar

private struct SyncFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "StableBarTests.ICloudSync.\(UUID().uuidString)")
    var sync: ICloudSync { ICloudSync(folder: root.appending(path: "home/.config/stablebar"), drive: root.appending(path: "drive")) }

    init(local: String?, synced: String? = nil, drive: Bool = true) throws {
        if let local { try write(local, in: sync.folder) }
        if let synced { try write(synced, in: sync.synced) }
        else if drive { try FileManager.default.createDirectory(at: sync.drive, withIntermediateDirectories: true) }
    }

    func write(_ text: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "widgets"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: "config.json"))
        try Data("echo \(text)".utf8).write(to: folder.appending(path: "widgets/hello.sh"))
    }

    func read(_ folder: URL) throws -> String { try String(contentsOf: folder.appending(path: "config.json"), encoding: .utf8) }

    var isLink: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: sync.folder.path)) != nil }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func turningICloudSyncOnMovesTheFolderIntoICloudDriveAndLinksItBack() throws {
    let fixture = try SyncFixture(local: "this Mac")
    defer { fixture.remove() }
    #expect(fixture.sync.state == .off)
    try fixture.sync.turnOn()
    #expect(fixture.sync.state == .on)
    #expect(fixture.isLink)
    #expect(try fixture.read(fixture.sync.synced) == "this Mac")
    #expect(try fixture.read(fixture.sync.folder) == "this Mac")
    #expect(FileManager.default.fileExists(atPath: fixture.sync.folder.appending(path: "widgets/hello.sh").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sync.folder.deletingLastPathComponent().path) == ["stablebar"])
}

@Test func turningICloudSyncOffCopiesTheFolderBackAndLeavesICloudDriveForTheOtherMacs() throws {
    let fixture = try SyncFixture(local: "this Mac")
    defer { fixture.remove() }
    try fixture.sync.turnOn()
    try fixture.write("edited on another Mac", in: fixture.sync.synced)
    try fixture.sync.turnOff()
    #expect(fixture.sync.state == .off)
    #expect(!fixture.isLink)
    #expect(try fixture.read(fixture.sync.folder) == "edited on another Mac")
    #expect(try fixture.read(fixture.sync.synced) == "edited on another Mac")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sync.folder.deletingLastPathComponent().path) == ["stablebar"])
}

@Test(arguments: [ICloudSync.Keep.iCloud, .thisMac])
func turningICloudSyncOnKeepsTheChosenConfigurationWhenICloudDriveHasOne(keep: ICloudSync.Keep) throws {
    let fixture = try SyncFixture(local: "this Mac", synced: "other Mac")
    defer { fixture.remove() }
    #expect(fixture.sync.hasSyncedConfiguration)
    try fixture.sync.turnOn(keeping: keep)
    #expect(fixture.sync.state == .on)
    #expect(try fixture.read(fixture.sync.folder) == (keep == .iCloud ? "other Mac" : "this Mac"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sync.drive.path) == ["StableBar"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sync.folder.deletingLastPathComponent().path) == ["stablebar"])
}

@Test func iCloudSyncIsUnavailableWithoutICloudDriveOrWhenTheFolderLinksElsewhere() throws {
    let noDrive = try SyncFixture(local: "this Mac", drive: false)
    defer { noDrive.remove() }
    #expect(noDrive.sync.state == .unavailable("Turn on iCloud Drive in System Settings → Apple Account → iCloud."))

    let linked = try SyncFixture(local: nil)
    defer { linked.remove() }
    let dotfiles = linked.root.appending(path: "dotfiles/stablebar")
    try linked.write("dotfiles", in: dotfiles)
    try FileManager.default.createDirectory(at: linked.sync.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked.sync.folder, withDestinationURL: dotfiles)
    guard case .unavailable = linked.sync.state else { Issue.record("expected unavailable, got \(linked.sync.state)"); return }
}

@Test @MainActor func commandsFindTheBarAfterSyncMovesItsConfigurationFolder() async throws {
    let fixture = try SyncFixture(local: "this Mac")
    defer { fixture.remove() }
    let url = fixture.sync.folder.appending(path: "config.json")
    let control = RuntimeControl { _ in .null }
    try control.start(url: url)
    defer { control.stop() }
    try fixture.sync.turnOn()
    #expect(!RuntimeControl.isRunning(url: url))
    NotificationCenter.default.post(name: RuntimeControl.configurationFolderMoved, object: nil)
    try await awaitCondition { RuntimeControl.isRunning(url: url) }
}

@Test @MainActor func usingICloudsConfigurationShowsItsBarForTheScreenSetup() throws {
    let fixture = try SyncFixture(local: nil)
    defer { fixture.remove() }
    let local = fixture.sync.folder, synced = fixture.sync.synced
    for folder in [local, synced] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data(#"{"bar":{"height":36},"widgets":[]}"#.utf8).write(to: local.appending(path: "config.json"))
    try Data(#"{"bar":{"height":30},"widgets":[]}"#.utf8).write(to: local.appending(path: "setup-laptop+monitor.json"))
    try Data(#"{"bar":{"height":48},"widgets":[]}"#.utf8).write(to: synced.appending(path: "config.json"))
    let docked = ScreenSetup([BarDisplay(id: 1, isBuiltIn: true, isMain: false, notch: nil),
                              BarDisplay(id: 2, isBuiltIn: false, isMain: true, notch: nil)])
    let store = BarStore(configurationURL: local.appending(path: "config.json"))
    defer { store.stop() }
    store.start(on: docked)
    #expect(store.configuration?.bar.height == 30)
    try fixture.sync.turnOn(keeping: .iCloud)
    store.reloadMovedFolder()
    #expect(store.configurationStore.configurationURL.lastPathComponent == "config.json")
    #expect(store.configurationError == nil)
    #expect(store.configuration?.bar.height == 48)
}

@Test func turningICloudSyncOnAgainLeavesASyncedFolderAlone() throws {
    let fixture = try SyncFixture(local: "this Mac")
    defer { fixture.remove() }
    try fixture.sync.turnOn()
    try fixture.sync.turnOn(keeping: .thisMac)
    #expect(fixture.sync.state == .on)
    #expect(try fixture.read(fixture.sync.synced) == "this Mac")
}

@Test func iCloudSyncListsTheConflictCopiesBesideTheirOriginals() throws {
    let fixture = try SyncFixture(local: "this Mac")
    defer { fixture.remove() }
    #expect(fixture.sync.conflicts.isEmpty)
    try fixture.sync.turnOn()
    for name in ["config 2.json", "setup-laptop.json", "notes 2.json", "widgets 3"] {
        try Data().write(to: fixture.sync.synced.appending(path: name))
    }
    #expect(fixture.sync.conflicts == ["config 2.json", "widgets 3"])
}
