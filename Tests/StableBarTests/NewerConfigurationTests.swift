import Foundation
import Testing
@testable import StableBar

private func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url, options: .atomic)
}

private func schema(_ reference: String) -> String {
    "https://raw.githubusercontent.com/Seb-GRAF/StableBar/\(reference)/stablebar.schema.json"
}

@Test(arguments: [("0.9.0", "0.10.0"), ("0.9.0-beta.20261026143311.421", "0.9.0"),
                  ("0.9.0-beta.20261026143311.421", "0.9.0-beta.20261026150000.425"), ("0.9.0", "0.9.1-beta.20261027100000.430"),
                  ("0.9.0-beta.9", "0.9.0-beta.10"), ("0.9.0-beta", "0.9.0-beta.1"), ("1.0.0-rc10", "1.0.0-rc2"),
                  ("1.0.0-1", "1.0.0-alpha"), ("1.0.0-9", "1.0.0--1"),
                  ("1.0.0-99999999999999999999", "1.0.0-100000000000000000000")])
func releasesOrderAsSemanticVersions(earlier: String, later: String) {
    #expect(compareReleases(earlier, later) == .orderedAscending)
    #expect(compareReleases(later, earlier) == .orderedDescending)
}

@Test func releasesIgnoreBuildMetadataAndMissingZeros() {
    #expect(compareReleases("1.0.0+5", "1.0.0") == .orderedSame)
    #expect(compareReleases("0.9", "0.9.0") == .orderedSame)
}

@Test func aConfigurationWrittenForANewerReleaseSkipsWhatThisReleaseDoesNotKnow() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try write(#"""
    {"$schema":"\#(schema("v0.10.0"))","bar":{"height":30,"futureMotion":"spring"},
     "templates":{"metric":{"type":"text","position":"right","text":"CPU","futureGlow":true}},
     "profiles":[{"name":"office","when":{"futureNetwork":"Office"},"configuration":{"bar":{"height":40}}}],
     "widgets":[{"id":"clock","type":"clock","position":"right","style":{"fontSize":12,"futureShimmer":1}},
                {"id":"cpu","template":"metric"}]}
    """#, to: root)
    var loader = ConfigurationLoader()
    loader.appVersion = "0.9.0"
    let configuration = try loader.load(root)
    #expect(configuration.bar.height == 30)
    #expect(configuration.widgets.first { $0.id == "clock" }?.style.fontSize == 12)
    #expect(loader.newerVersion == "0.10.0")
    #expect(loader.skippedProperties == ["bar.futureMotion", "profiles.0.when.futureNetwork",
                                         "widgets.clock.style.futureShimmer", "widgets.cpu.futureGlow"])
    #expect(loader.activeProfiles.isEmpty, "a condition this release can't check never matches")
    #expect(loader.newerVersionWarning == "This configuration was written for StableBar 0.10.0, so 0.9.0 skips bar.futureMotion, "
        + "profiles.0.when.futureNetwork, widgets.clock.style.futureShimmer, widgets.cpu.futureGlow. Update StableBar to use them.")
    #expect(loader.document["bar"] == .object(["height": .number(30), "futureMotion": .string("spring")]),
            "Settings keeps the properties it skips")

    try write(#"{"profile":"office","includes":["config.json"]}"#, to: directory.appending(path: "pinned.json"))
    _ = try loader.load(directory.appending(path: "pinned.json"))
    #expect(loader.activeProfiles == ["office"], "a pinned profile still applies")
}

@Test func unknownPropertiesStayErrorsUnlessAFileIsWrittenForANewerRelease() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    for (stamp, release) in [(schema("v0.9.0"), "0.9.0"), (schema("v0.9.0-beta.20261026143311.421"), "0.9.0"),
                             (schema("main"), "0.9.0"), ("./stablebar.schema.json", "0.9.0"), (schema("v0.10.0"), nil)] as [(String, String?)] {
        var loader = ConfigurationLoader()
        loader.appVersion = release
        let error = #expect(throws: (any Error).self) {
            try loader.load(url, data: Data(#"{"$schema":"\#(stamp)","bar":{"heigth":30},"widgets":[]}"#.utf8))
        }
        #expect(error.map(errorMessage) == "bar.heigth: Unknown property.", "\(stamp) in \(release ?? "a development build")")
        #expect(loader.newerVersion == nil)
    }
    var loader = ConfigurationLoader()
    loader.appVersion = "0.9.0"
    let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(#"{"bar":{"heigth":30},"widgets":[]}"#.utf8)) }
    #expect(error.map(errorMessage) == "bar.heigth: Unknown property.")
}

@Test func anIncludeOrPackageWrittenForANewerReleaseCoversTheWholeConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try write(#"{"$schema":"\#(schema("v0.10.0"))","defaults":{"fontSize":11}}"#, to: directory.appending(path: "shared.json"))
    try write(#"{"includes":["shared.json"],"bar":{"futureMotion":"spring"},"widgets":[]}"#, to: root)
    var loader = ConfigurationLoader()
    loader.appVersion = "0.9.0"
    #expect(try loader.load(root).defaults.fontSize == 11)
    #expect(loader.skippedProperties == ["bar.futureMotion"])

    let package = directory.appending(path: "packages/futureclock/1")
    try write(#"{"id":"futureclock","name":"Future clock","version":"1","kind":"widgets","entry":"config.json","minimumVersion":"0.10.0"}"#,
              to: package.appending(path: "package.json"))
    try write(#"{"widgets":[{"id":"futureclock","type":"clock","position":"right","futureFace":"analog"}]}"#,
              to: package.appending(path: "config.json"))
    try write(#"{"packages":[{"id":"futureclock","version":"1"}],"widgets":[]}"#, to: root)
    #expect(try loader.load(root).widgets.map(\.id) == ["futureclock"])
    #expect(loader.newerVersion == "0.10.0")
    #expect(loader.skippedProperties == ["widgets.futureclock.futureFace"])
    loader.appVersion = "0.10.0"
    let error = #expect(throws: (any Error).self) { try loader.load(root) }
    #expect(error.map(errorMessage) == "widgets.futureclock: futureFace: Unknown property.")
}

@Test func otherErrorsSayWhichReleaseAConfigurationWasWrittenFor() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    var loader = ConfigurationLoader()
    loader.appVersion = "0.9.0"
    let error = #expect(throws: (any Error).self) {
        try loader.load(url, data: Data(#"{"$schema":"\#(schema("v0.10.0"))","workspaceSource":"future","widgets":[]}"#.utf8))
    }
    let message = try #require(error.map(errorMessage))
    #expect(message.hasPrefix("workspaceSource: "))
    #expect(message.hasSuffix(" This configuration was written for StableBar 0.10.0, and this is 0.9.0. Update StableBar to load it."))
}

@Test func savingPinsTheSchemaToTheReleaseThatSaved() throws {
    func saved(_ original: String, _ document: [String: ConfigurationValue], by release: String? = "0.10.0") throws -> String {
        String(decoding: try configurationData(document, editing: Data(original.utf8), savedBy: release), as: UTF8.self)
    }
    let main = #"{\#n  "$schema": "\#(schema("main"))",\#n  "bar": {"height": 30}\#n}"#
    #expect(try saved(main, ["$schema": .string(schema("main")), "bar": .object(["height": .number(32)])])
        == #"{\#n  "$schema": "\#(schema("v0.10.0"))",\#n  "bar": {"height": 32}\#n}"#)
    #expect(try saved(#"{\#n  "bar": {"height": 30}\#n}"#, ["bar": .object(["height": .number(32)])])
        == #"{\#n  "$schema": "\#(schema("v0.10.0"))",\#n  "bar": {"height": 32}\#n}"#)
    for (kept, release) in [(schema("v0.11.0"), "0.10.0"), (schema("v0.10.0"), "0.10.0-beta.20261020103000.114"),
                            ("./stablebar.schema.json", "0.10.0"), (schema("main"), nil)] as [(String, String?)] {
        let original = #"{"$schema":"\#(kept)","bar":{"height":30}}"#
        #expect(try saved(original, ["$schema": .string(kept), "bar": .object(["height": .number(32)])], by: release)
            == #"{"$schema":"\#(kept)","bar":{"height":32}}"#)
    }
    #expect(try saved(#"{"$schema":"\#(schema("v0.9.0"))","bar":{"height":30}}"#,
                      ["$schema": .string(schema("v0.9.0")), "bar": .object(["height": .number(32)])])
        == #"{"$schema":"\#(schema("v0.10.0"))","bar":{"height":32}}"#)
    #expect(try saved(main, ["$schema": .string(schema("main")), "bar": .object(["height": .number(30)])]) == main,
            "an unchanged file stays as it is")
}

@Test @MainActor func theBarLoadsAConfigurationWrittenForANewerReleaseAndWarns() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try write(#"{"$schema":"\#(schema("v0.10.0"))","bar":{"height":37,"futureMotion":"spring"},"widgets":[]}"#, to: root)
    let store = BarStore(configurationURL: root, release: "0.9.0")
    defer { store.stop() }
    store.start()
    #expect(store.configuration?.bar.height == 37)
    #expect(store.configurationError == nil)
    #expect(store.configurationWarning == "This configuration was written for StableBar 0.10.0, so 0.9.0 skips bar.futureMotion. "
        + "Update StableBar to use them.")
    guard case let .object(state) = try store.snapshot() else { Issue.record("no state"); return }
    #expect(state["warning"] == .string(store.configurationWarning!))

    try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["height": .number(40)])], persist: true)
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
    #expect(saved["bar"] == .object(["height": .number(40), "futureMotion": .string("spring")]), "an older release keeps newer properties")
    #expect(saved["$schema"] == .string(schema("v0.10.0")), "an older release never lowers the stamp")
}

@Test @MainActor func settingsAndCommandLineSavesPinTheSchemaToTheBarsRelease() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try write(#"{"$schema":"\#(schema("main"))","bar":{"height":37},"widgets":[]}"#, to: root)
    let store = BarStore(configurationURL: root, release: "0.10.0")
    defer { store.stop() }
    store.start()
    let original = try Data(contentsOf: root)
    let data = try store.customizationData([ConfigurationEdit(action: .bar, properties: ["height": .number(38)])], editing: original)
    try store.writeCustomization(data, replacing: original)
    #expect(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))["$schema"]
        == .string(schema("v0.10.0")))

    try write(#"{"$schema":"\#(schema("main"))","bar":{"height":37},"widgets":[]}"#, to: root)
    store.reloadConfiguration()
    try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["height": .number(40)])], persist: true)
    #expect(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))["$schema"]
        == .string(schema("v0.10.0")))
    #expect(store.configurationWarning == nil)
}
