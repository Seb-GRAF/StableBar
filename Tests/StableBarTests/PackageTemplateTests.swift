import Foundation
import Testing
@testable import StableBar

@Test func packagesThatShareATemplateNameKeepTheirOwnTemplates() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    for (id, text) in [("player", "Player"), ("other", "Other")] {
        let source = directory.appending(path: "sources/\(id)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(id)","name":"\#(id)","version":"1","kind":"widgets","entry":"config.json"}"#.utf8)
            .write(to: source.appending(path: "package.json"))
        try Data(#"""
        {"templates":{"Player":{"type":"text","position":"right","text":"x","tooltip":"\#(text)","style":{"paddingHorizontal":4}},
                      "Chained":{"template":"Player"}},
         "widgets":[{"id":"\#(id)","template":"Chained"}]}
        """#.utf8).write(to: source.appending(path: "config.json"))
        _ = try store.install(source)
    }
    let root = directory.appending(path: "config.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: Data(#"""
    {"packages":[{"id":"player","version":"1"},{"id":"other","version":"1"}],
     "templates":{"Player":{"style":{"fontSize":15}},"Chained":{"template":"Player"}},
     "widgets":[{"id":"mine","template":"Player","text":"Mine","tooltip":"Mine","position":"left"},
                {"id":"chained","template":"Chained"}]}
    """#.utf8))
    func widget(_ id: String) throws -> WidgetConfiguration {
        try #require(configuration.widgets.first { $0.id == id })
    }
    #expect(try widget("player").tooltip == "Player")
    #expect(try widget("other").tooltip == "Other")
    #expect(try widget("player").style.fontSize == 15)
    #expect(try widget("player").style.paddingHorizontal == 4)
    #expect(try widget("mine").style.fontSize == 15)
    // Your own widgets still get every package's template of a name, the later package winning.
    #expect(try widget("chained").tooltip == "Other")
    #expect(loader.origins["widgets.player.tooltip"]?.file.hasSuffix("packages/player/1/config.json") == true)
    #expect(loader.origins["widgets.player.style.fontSize"]?.file == root.path)
}

@Test func aPackageWithoutItsOwnTemplateFallsBackToYoursNotAnotherPackages() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try installPackages([
        ("variants", #"{"profiles":[{"name":"variant","configuration":{"templates":{"Base":{"type":"text","position":"right","text":"v"}}}}],"widgets":[{"id":"variants","template":"Base"}]}"#),
        ("other", #"{"templates":{"Base":{"type":"text","position":"right","text":"o","tooltip":"Other"}},"widgets":[{"id":"other","template":"Base"}]}"#),
    ], in: directory)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(directory.appending(path: "config.json"), data: Data(#"""
    {"packages":[{"id":"variants","version":"1"},{"id":"other","version":"1"}],
     "profiles":[{"name":"variant","enabled":false}],
     "templates":{"Base":{"type":"text","position":"left","text":"mine"}}}
    """#.utf8))
    let widget = try #require(configuration.widgets.first { $0.id == "variants" })
    #expect(widget.position == .left)
    #expect(widget.tooltip == nil)
}

@Test func aTokenNamesAPackageWidgetsTemplateInItsPackageAndReplacesAWholeValue() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (id, text) in [("player", "Player"), ("other", "Other")] {
        try installPackages([(id, #"""
        {"tokens":{"look":"Player"},
         "templates":{"Player":{"type":"text","position":"right","text":"x","tooltip":"\#(text)","style":{"paddingHorizontal":4}},
                      "Card":{"type":"text","position":"right","text":"c","style":{"paddingHorizontal":4}}},
         "widgets":[{"id":"\#(id)","template":"@token.look"},{"id":"\#(id)-card","template":"Card"}]}
        """#)], in: directory)
    }
    var loader = ConfigurationLoader()
    let configuration = try loader.load(directory.appending(path: "config.json"), data: Data(#"""
    {"packages":[{"id":"player","version":"1"},{"id":"other","version":"1"}],
     "tokens":{"compact":{"fontSize":15},"card":{"type":"text","position":"left","text":"mine"}},
     "templates":{"Player":{"style":"@token.compact"},"Card":"@token.card"}}
    """#.utf8))
    let widget = try #require(configuration.widgets.first { $0.id == "player" })
    #expect(widget.tooltip == "Player")
    #expect(widget.style.fontSize == 15)
    #expect(widget.style.paddingHorizontal == nil)
    let card = try #require(configuration.widgets.first { $0.id == "player-card" })
    #expect(card.position == .left)
    #expect(card.style.paddingHorizontal == nil)
}

private func installPackages(_ packages: [(id: String, configuration: String)], in directory: URL) throws {
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    for (id, configuration) in packages {
        let source = directory.appending(path: "sources/\(id)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(id)","name":"\#(id)","version":"1","kind":"widgets","entry":"config.json"}"#.utf8)
            .write(to: source.appending(path: "package.json"))
        try Data(configuration.utf8).write(to: source.appending(path: "config.json"))
        _ = try store.install(source)
    }
}
