import Foundation
import Testing
@testable import StableBar

@Test func unsettingAProfileByNameWithNullRemovesItFromTheMainFile() throws {
    let main: [String: ConfigurationValue] = [
        "widgets": .array([.object(["id": .string("clock")])]),
        "profiles": .array([
            .object(["name": .string("night"), "configuration": .object(["bar": .object(["height": .number(40)])])]),
            .object(["name": .string("work"), "configuration": .object([:])])
        ])
    ]
    var ids = ["clock"]
    let night = try ConfigurationEdit(action: .unset, properties: [
        "profiles": .object(["night": .null]), "widgets": .object(["clock": .null])
    ]).applying(to: main, widgetIDs: &ids)
    #expect(night["profiles"] == .array([.object(["name": .string("work"), "configuration": .object([:])])]))
    #expect(night["widgets"] == main["widgets"])
    let both = try ConfigurationEdit(action: .unset, properties: ["profiles": .object(["work": .null])])
        .applying(to: night, widgetIDs: &ids)
    #expect(both["profiles"] == nil)
}

@MainActor @Test func deletingAProfileRemovesItAndItsPinInOneUndoableChange() throws {
    let fixture = try ProfileFixture(#"""
    {"bar":{"height":40},"widgets":[],"profile":"night","profiles":[
      {"name":"night","when":{"appearance":"dark"},"configuration":{"bar":{"height":30}}},
      {"name":"work","configuration":{}}
    ]}
    """#)
    defer { fixture.close() }
    let editor = ConfigurationEditor(store: fixture.store)
    editor.selectedProfileName = "night"
    #expect(editor.profileRemoval("night") == .delete)
    #expect(fixture.store.configuration?.bar.height == 30)

    editor.deleteProfile("night")
    #expect(editor.error == nil)
    #expect(fixture.store.profiles.map(\.name) == ["work"])
    #expect(fixture.store.pinnedProfile == nil)
    #expect(fixture.store.configuration?.bar.height == 40)
    #expect(editor.selectedProfileName == nil)
    let document = try fixture.document()
    #expect(document["profile"] == nil)
    #expect(try document["profiles"]?.decoded([ConfigurationProfile].self).map(\.name) == ["work"])
    #expect(editor.undoSteps.count == 1)

    editor.undo()
    #expect(fixture.store.profiles.map(\.name) == ["night", "work"])
    #expect(fixture.store.pinnedProfile == "night")
    #expect(try fixture.document()["profile"] == .string("night"))
}

@MainActor @Test func deletingTheProfileBeingEditedEndsEditingFirst() throws {
    let fixture = try ProfileFixture(#"{"bar":{"height":40},"widgets":[],"profiles":[{"name":"work","configuration":{}}]}"#)
    defer { fixture.close() }
    let editor = ConfigurationEditor(store: fixture.store)
    editor.editBar(for: "work")
    #expect(editor.editingProfile == "work")

    editor.deleteProfile("work")
    #expect(editor.error == nil)
    #expect(editor.editingProfile == nil)
    #expect(fixture.store.profiles.isEmpty)
    #expect(try fixture.document()["profiles"] == nil)
}

@MainActor @Test func aProfileFromAnIncludeKeepsItsIncludedValuesWhenYourChangesAreRemoved() throws {
    let fixture = try ProfileFixture(#"""
    {"includes":["shared.json"],"bar":{"height":40},"widgets":[],"profile":"dark","profiles":[
      {"name":"dark","enabled":false,"configuration":{"bar":{"height":36}}}
    ]}
    """#, include: #"{"profiles":[{"name":"dark","configuration":{"bar":{"height":30}}},{"name":"travel","configuration":{}}]}"#)
    defer { fixture.close() }
    let editor = ConfigurationEditor(store: fixture.store)
    #expect(editor.profileRemoval("dark") == .removeChanges)
    #expect(editor.profileRemoval("travel") == .unavailable)

    editor.deleteProfile("dark")
    #expect(editor.error == nil)
    #expect(fixture.store.profiles.map(\.name) == ["dark", "travel"])
    #expect(fixture.store.profiles.first?.enabled == true)
    #expect(fixture.store.pinnedProfile == "dark")
    #expect(fixture.store.configuration?.bar.height == 30)
    #expect(try fixture.document()["profiles"] == nil)
    #expect(try fixture.document()["profile"] == .string("dark"))

    let saved = try Data(contentsOf: fixture.url)
    editor.deleteProfile("travel")
    #expect(editor.error == "This profile comes from your theme, a package or an included file. Turn it off instead.")
    #expect(try Data(contentsOf: fixture.url) == saved)
}

@MainActor @Test func aProfileAddedOnlyFromTheCommandLineIsNotDeletedFromSettings() throws {
    let fixture = try ProfileFixture(#"{"widgets":[]}"#)
    defer { fixture.close() }
    try fixture.store.configurationStore.applyEdits([ConfigurationEdit(action: .profiles, profiles: [
        ["name": .string("temporary"), "configuration": .object([:])]
    ])], persist: false)
    let editor = ConfigurationEditor(store: fixture.store)
    let saved = try Data(contentsOf: fixture.url)
    editor.deleteProfile("temporary")
    #expect(editor.error == "Save command-line changes before editing this profile.")
    #expect(fixture.store.profiles.map(\.name) == ["temporary"])
    #expect(try Data(contentsOf: fixture.url) == saved)
}

@MainActor @Test func profilesGroupByWhereTheyComeFrom() throws {
    let fixture = try ProfileFixture(#"""
    {"includes":["shared.json"],"widgets":[],"profiles":[
      {"name":"night","when":{"appearance":"dark"},"configuration":{}},
      {"name":"Léman edits","when":{"theme":"leman"},"configuration":{"bar":{"height":30}}},
      {"name":"dark","enabled":false,"configuration":{}},
      {"name":"Nord at night","when":{"theme":"nord","appearance":"dark"},"configuration":{}}
    ]}
    """#, include: #"{"profiles":[{"name":"dark","configuration":{}},{"name":"travel","when":{"theme":"nord"},"configuration":{}}]}"#)
    defer { fixture.close() }
    let groups = ProfileGroups(store: fixture.store)
    #expect(groups.yours.map(\.name) == ["night", "Nord at night"])
    #expect(groups.themeEdits.map(\.name) == ["Léman edits"])
    #expect(groups.elsewhere.map(\.profile.name) == ["dark", "travel"])
    #expect(groups.elsewhere.map { URL(filePath: $0.file).lastPathComponent } == ["shared.json", "shared.json"])
}

@MainActor private final class ProfileFixture {
    let url: URL
    let store: BarStore

    init(_ configuration: String, include: String? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "config.json")
        try Data(configuration.utf8).write(to: url)
        if let include { try Data(include.utf8).write(to: directory.appending(path: "shared.json")) }
        store = BarStore(configurationURL: url, themesDirectory: nil, customizationSaveDelay: .zero)
        store.configurationStore.reloadConfiguration()
        #expect(store.configurationError == nil)
    }

    func document() throws -> [String: ConfigurationValue] {
        try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    }

    func close() {
        store.stop()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
