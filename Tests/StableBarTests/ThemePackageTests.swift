import CryptoKit
import Foundation
import Testing
@testable import StableBar

private func writePackageFile(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

@Test func tokensAndProfilesPreserveTypesAndApplyInDeclaredOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try writePackageFile(##"""
    {"tokens":{"size":11,"foreground":"#111111","alias":"@token.size"},
     "templates":{"base":{"type":"text","position":"left","text":"Ready","style":{"fontSize":"@token.alias"}}},
     "widgets":[{"id":"status.main","template":"base"}]}
    """##, to: directory.appending(path: "module.json"))
    try writePackageFile(##"""
    {"includes":["module.json"],"tokens":{"size":12},"defaults":{"foreground":"@token.foreground"},
     "profiles":[
       {"name":"dark","when":{"appearance":"dark"},"configuration":{"tokens":{"foreground":"#eeeeee","size":14}}},
       {"name":"portable","when":{"onBattery":true,"displayCount":1,"externalDisplay":false,"app":"com.test.Editor"},
        "configuration":{"tokens":{"size":16},"bar":{"height":32}}}],
     "widgetOverrides":{"status.main":{"style":{"background":"@token.foreground"}}}}
    """##, to: root)
    var loader = ConfigurationLoader()
    let normal = try loader.load(root)
    #expect(normal.widgets[0].style.fontSize == 12)
    #expect(loader.activeProfiles.isEmpty)
    let dark = try loader.load(root, context: ConfigurationContext(appearance: "dark", onBattery: true,
                                                                  displayCount: 1, externalDisplay: false, app: "com.test.Editor"))
    #expect(loader.activeProfiles == ["dark", "portable"])
    #expect(dark.widgets[0].style.fontSize == 16)
    #expect(dark.defaults.foreground == HexColor(0xeeeeeeff))
    #expect(dark.widgets[0].style.background == .color(HexColor(0xeeeeeeff)))
    #expect(dark.bar.height == 32)
    #expect(loader.origins["widgets.status.main.style.fontSize"]?.description.contains("template base") == true)
    #expect(loader.origins["widgets.status.main.style.background"]?.description.contains("widget override") == true)
    #expect(loader.origins["widgets.status.main.style.background"]?.description.contains("token foreground") == true)
    #expect(loader.document["templates"] == nil)
    #expect(loader.document["widgetOverrides"] == nil)
}

@Test func profilesMergeByNameAndCanBeDisabledAcrossLayers() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try writePackageFile(#"""
    {"profiles":[
      {"name":"dark","when":{"appearance":"dark"},"configuration":{"bar":{"height":30,"spacing":8}}},
      {"name":"portable","when":{"onBattery":true},"configuration":{"bar":{"height":32}}}]}
    """#, to: directory.appending(path: "base.json"))
    try writePackageFile(#"""
    {"includes":["base.json"],"profiles":[
      {"name":"portable","enabled":false},
      {"name":"dark","configuration":{"bar":{"height":34}}},
      {"name":"work","when":{"app":"com.test.Editor"},"configuration":{"bar":{"height":36}}}]}
    """#, to: directory.appending(path: "module.json"))
    let json = #"""
    {"includes":["module.json"],"profiles":[
      {"name":"dark","when":{"appearance":null,"onBattery":true}},
      {"name":"work","enabled":false},
      {"name":"external","when":{"externalDisplay":true},"configuration":{"bar":{"spacing":12}}}]}
    """#
    var loader = ConfigurationLoader()
    #expect(try loader.load(root, data: Data(json.utf8)).bar.height == 40)
    #expect(loader.profiles.map(\.name) == ["dark", "portable", "work", "external"])
    #expect(!loader.matchesApps)
    let battery = try loader.load(root, data: Data(json.utf8), context: ConfigurationContext(onBattery: true))
    #expect(loader.activeProfiles == ["dark"])
    #expect(battery.bar.height == 34)
    #expect(battery.bar.spacing == 8)
    #expect(loader.origins["bar.height"]?.file == directory.appending(path: "module.json").path)
    #expect(loader.origins["bar.spacing"]?.file == directory.appending(path: "base.json").path)
    let external = try loader.load(root, data: Data(json.utf8), context: ConfigurationContext(onBattery: true, externalDisplay: true))
    #expect(loader.activeProfiles == ["dark", "external"])
    #expect(external.bar.spacing == 12)
    let disabled = #"{"includes":["module.json"],"profile":"portable"}"#
    #expect(try loader.load(root, data: Data(disabled.utf8)).bar.height == 40)
    #expect(loader.activeProfiles.isEmpty)
    let enabled = #"{"includes":["module.json"],"profile":"portable","profiles":[{"name":"portable","enabled":true}]}"#
    #expect(try loader.load(root, data: Data(enabled.utf8)).bar.height == 32)
    #expect(loader.activeProfiles == ["portable"])
    #expect(throws: ThemeConfigurationError.self) {
        try loader.load(root, data: Data(#"{"profiles":[{"name":"same"},{"name":"same"}]}"#.utf8))
    }
}

@Test func manualProfilesOverrideConditionsAndUnknownProfilesFail() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "profiles.json")
    let json = #"""
    {"profile":"desktop","widgets":[],"profiles":[
      {"name":"mobile","when":{"displayCount":1},"configuration":{"bar":{"height":30}}},
      {"name":"desktop","when":{"displayCount":2},"configuration":{"bar":{"height":50}}}]}
    """#
    var loader = ConfigurationLoader()
    #expect(try loader.load(url, data: Data(json.utf8)).bar.height == 50)
    #expect(loader.activeProfiles == ["desktop"])
    #expect(throws: ThemeConfigurationError.self) {
        try loader.load(url, data: Data(json.replacingOccurrences(of: "\"profile\":\"desktop\"", with: "\"profile\":\"missing\"").utf8))
    }
}

@Test func explicitAutomaticProfileOverridesAnIncludedManualSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePackageFile(#"""
    {"profile":"desktop","widgets":[],"profiles":[
      {"name":"laptop","when":{"displayCount":1},"configuration":{"bar":{"height":30}}},
      {"name":"desktop","when":{"displayCount":2},"configuration":{"bar":{"height":50}}}]}
    """#, to: directory.appending(path: "module.json"))
    let root = directory.appending(path: "config.json")
    var loader = ConfigurationLoader()
    #expect(try loader.load(root, data: Data(#"{"includes":["module.json"]}"#.utf8)).bar.height == 50)
    #expect(try loader.load(root, data: Data(#"{"includes":["module.json"],"profile":null}"#.utf8)).bar.height == 30)
    #expect(loader.activeProfiles == ["laptop"])
}

@Test func customizationAndRemovedWidgetsMigrateIntoNormalKeys() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePackageFile(#"""
    {"widgets":[{"id":"imported","type":"text","position":"right","text":"Imported"},
                {"id":"gone","type":"text","position":"right","text":"Gone"}]}
    """#, to: directory.appending(path: "module.json"))
    let root = directory.appending(path: "config.json")
    try writePackageFile(#"""
    {"includes":["module.json"],"bar":{"height":40},
     "widgets":[{"id":"clock","type":"clock","position":"left"},{"id":"old","type":"text","position":"left","text":"Old"}],
     "removedWidgets":["old","gone"],
     "customization":{"bar":{"height":48},"defaults":{"fontSize":16},
       "widgetOverrides":{"clock":{"position":"center"},"imported":{"text":"Changed"}},"widgetOrder":["clock","imported"]}}
    """#, to: root)
    try migrateConfigurationFile(root)
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
    #expect(saved["customization"] == nil)
    #expect(saved["removedWidgets"] == nil)
    #expect(saved["bar"] == .object(["height": .number(48)]))
    #expect(saved["defaults"] == .object(["fontSize": .number(16)]))
    #expect(saved["widgets"] == .array([.object(["id": .string("clock"), "type": .string("clock"), "position": .string("center")])]))
    #expect(saved["widgetOverrides"] == .object(["imported": .object(["text": .string("Changed")]),
                                                 "gone": .object(["enabled": .bool(false)])]))
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.widgets.map(\.id) == ["clock", "imported", "gone"])
    #expect(configuration.widgets[1].content == .text("Changed"))
    #expect(!configuration.widgets[2].enabled)
}

@Test func customizationInAnIncludeOrAPackageLoadsMovedAndStaysInTheFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    try writePackageFile(#"{"id":"meter","name":"Meter","version":"1","entry":"config.json"}"#, to: source.appending(path: "package.json"))
    try writePackageFile(#"""
    {"widgets":[{"id":"meter","type":"text","position":"right","text":"Meter"}],
     "customization":{"widgetOverrides":{"meter":{"text":"Moved"}}}}
    """#, to: source.appending(path: "config.json"))
    let packages = WidgetPackageStore(directory: directory.appending(path: "bar/packages"))
    _ = try packages.install(source)
    let module = directory.appending(path: "bar/module.json")
    try writePackageFile(#"""
    {"widgets":[{"id":"module","type":"text","position":"left","text":"Module"},{"id":"gone","type":"text","position":"left","text":"Gone"}],
     "removedWidgets":["gone"],"customization":{"bar":{"height":44}}}
    """#, to: module)
    let root = directory.appending(path: "bar/config.json")
    try writePackageFile(#"{"includes":["module.json"],"packages":[{"id":"meter","version":"1"}],"widgets":[]}"#, to: root)
    let files = [module, try packages.directory(id: "meter", version: "1").appending(path: "config.json")]
    let written = try files.map { try Data(contentsOf: $0) }
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.bar.height == 44)
    #expect(configuration.widgets.map(\.id) == ["meter", "module"])
    #expect(configuration.widgets[0].content == .text("Moved"))
    let document = loader.document
    _ = try loader.load(root)
    #expect(loader.document == document)
    #expect(try files.map { try Data(contentsOf: $0) } == written)
}

@Test func tokenCyclesUnknownNamesAndWrongTypesFailWithoutShellInterpolation() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "tokens.json")
    var loader = ConfigurationLoader()
    for tokens in [#"{"a":"@token.b","b":"@token.a"}"#, #"{"a":"@token.missing"}"#] {
        #expect(throws: ThemeConfigurationError.self) {
            try loader.load(url, data: Data("{\"widgets\":[],\"tokens\":\(tokens)}".utf8))
        }
    }
    #expect(throws: DecodingError.self) {
        try loader.load(url, data: Data(#"{"widgets":[],"tokens":{"size":"large"},"bar":{"height":"@token.size"}}"#.utf8))
    }
    let configuration = try loader.load(url, data: Data(#"""
    {"tokens":{"word":"replacement","style":{"fontSize":17}},"widgets":[
      {"id":"script","type":"script","position":"left","style":"@token.style","command":"printf '@token.word'"}]}
    """#.utf8))
    #expect(configuration.widgets[0].content == .script(command: "printf '@token.word'", interval: 30))
    #expect(configuration.widgets[0].style.fontSize == 17)
    #expect(loader.origins["widgets.script.style.fontSize"]?.description.contains("token style") == true)
}

@Test func referenceExpansionStopsJustAboveTheLimit() throws {
    let fits = ConfigurationValue.array(Array(repeating: .number(1), count: 99_999))
    let tooBig = ConfigurationValue.array(Array(repeating: .number(1), count: 100_000))
    #expect(try substituteConfigurationReferences(.string("@token.big"), prefix: "@token.", values: ["big": fits]) == fits)
    let error = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(.string("@token.big"), prefix: "@token.", values: ["big": tooBig])
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "big")
}

@Test func fortyWorkspaceWidgetsCanShareAnAppGlyphSizedToken() throws {
    let glyphs = Dictionary(uniqueKeysWithValues: (0..<881).map { ("Application\($0)", ":glyph:") })
    let ids = (0..<40).map { "spaces\($0)" }
    let data = try JSONEncoder().encode(ConfigurationValue.object([
        "tokens": .object(["appGlyphs": .object(glyphs.mapValues(ConfigurationValue.string))]),
        "widgets": .array(ids.map { .object([
            "id": .string($0), "type": .string("workspaces"), "position": .string("left"),
            "workspace": .object(["appGlyphs": .string("@token.appGlyphs")])
        ]) })
    ]))
    let root = FileManager.default.temporaryDirectory.appending(path: "shared-app-glyphs.json")
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let configuration = try loader.load(root, data: data)
    #expect(configuration.widgets.map(\.id) == ids)
    for widget in configuration.widgets {
        #expect(widget.workspace?.appGlyphs == glyphs)
        #expect(loader.origins["widgets.\(widget.id).workspace.appGlyphs.Application880"]?.token == "appGlyphs")
    }
}

@Test func longKeysInDoublingTokensCannotExhaustOriginBookkeeping() throws {
    var tokens: [String: ConfigurationValue] = ["t0": .number(1)]
    for level in 1...12 {
        tokens["t\(level)"] = .object([
            String(repeating: "A", count: 250) + String(level): .string("@token.t\(level - 1)"),
            String(repeating: "B", count: 250) + String(level): .string("@token.t\(level - 1)")
        ])
    }
    let value = ConfigurationValue.object([
        "widgets": .array([]), "tokens": .object(tokens),
        "bar": .object(["style": .object(["background": .string("@token.t12")])])
    ])
    let data = try JSONEncoder().encode(value)
    #expect(data.count <= 32_000)
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let error = #expect(throws: ThemeConfigurationError.self) {
        try loader.load(FileManager.default.temporaryDirectory.appending(path: "long-key-tokens.json"), data: data)
    }
    guard case let .referenceOriginsTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(tokens[name] != nil)
    #expect(error?.errorDescription == "Configuration references at \(name) produce more than StableBar can track. "
        + "Check tokens or settings that refer to each other or are used in many places.")
}

@Test func manyWidgetsWithATokenBackedTemplateCannotExhaustOriginBookkeeping() throws {
    let properties = Dictionary(uniqueKeysWithValues: (0..<500).map { ("p\($0)", ConfigurationValue.number(1)) })
    let widgets = (0..<40).map { index in
        ConfigurationValue.object([
            "id": .string(String(repeating: "w", count: 500) + String(index)), "template": .string("base")
        ])
    }
    let data = try JSONEncoder().encode(ConfigurationValue.object([
        "tokens": .object(["style": .object(properties)]),
        "templates": .object(["base": .object([
            "type": .string("text"), "position": .string("left"), "text": .string("Ready"),
            "style": .string("@token.style")
        ])]),
        "widgets": .array(widgets)
    ]))
    #expect(data.count <= 32_000)
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let error = #expect(throws: ThemeConfigurationError.self) {
        try loader.load(FileManager.default.temporaryDirectory.appending(path: "template-origin-paths.json"), data: data)
    }
    guard case let .referenceOriginsTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "style")
}

@Test func nestedTokensKeepEveryOriginAndItsOriginalSource() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let module = directory.appending(path: "tokens.json")
    let root = directory.appending(path: "config.json")
    try writePackageFile(##"""
    {"tokens":{"color":"#112233","look":{"background":{"gradient":{"colors":["@token.color","#445566"],"angle":45}},"fontSize":17},
               "alias":"@token.look"}}
    """##, to: module)
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    _ = try loader.load(root, data: Data(#"""
    {"includes":["tokens.json"],"widgets":[{"id":"status.main","type":"text","position":"left","text":"Ready","style":"@token.alias"}]}
    """#.utf8))
    let tokenSource = ConfigurationOrigin(file: module.path).description
    let widgetSource = ConfigurationOrigin(file: root.path, token: "alias", tokenSource: tokenSource)
    let lookSource = ConfigurationOrigin(file: module.path, token: "look", tokenSource: tokenSource)
    let colorSource = ConfigurationOrigin(file: module.path, token: "color", tokenSource: tokenSource)
    let suffixes = ["", ".fontSize", ".background", ".background.gradient", ".background.gradient.colors",
                    ".background.gradient.colors.0", ".background.gradient.colors.1", ".background.gradient.angle"]
    func isChecked(_ path: String) -> Bool {
        if path == "tokens.look.background.gradient.colors.0" { return true }
        return ["widgets.status.main.style", "tokens.alias"].contains { path == $0 || path.hasPrefix($0 + ".") }
    }
    let actual = loader.origins.filter { path, _ in isChecked(path) }
    var expected = Dictionary(uniqueKeysWithValues: suffixes.map { ("widgets.status.main.style" + $0, widgetSource) })
    for suffix in suffixes { expected["tokens.alias" + suffix] = lookSource }
    expected["tokens.look.background.gradient.colors.0"] = colorSource
    #expect(actual == expected)
}

@Test func dottedWidgetIDsKeepOriginsAndContributionOrderThroughTemplateCopies() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dotted-widget-origins.json")
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    _ = try loader.load(root, data: Data(#"""
    {"templates":{
       "type.base":{"type":"text","position":"left","text":"Ready","style":{"fontSize":11}},
       "metric.large":{"template":"type.base","style":{"fontSize":12}}},
     "widgets":[{"id":"status.main","template":"metric.large","style":{"fontSize":13}},
                {"id":"status","type":"text","position":"left","text":"Parent"}],
     "widgetOverrides":{"status.main":{"style":{"fontSize":18}}}}
    """#.utf8))
    let path = "widgets.status.main.style.fontSize"
    let source = ConfigurationOrigin(file: root.path)
    #expect(loader.origins[path] == source.appending("(widget override)"))
    let history = try #require(loader.contributions[path])
    // Both dotted widget prefixes match this override path, so it's recorded twice.
    #expect(history.map(\.value) == [.number(11), .number(12), .number(13), .number(18), .number(18)])
    #expect(history.map(\.origin) == [source.appending("(template type.base)"),
                                    source.appending("(template metric.large)"), source,
                                    source.appending("(widget override)"),
                                    source.appending("(widget override)")])
    #expect(loader.origins["widgets.status.main.text"] == source.appending("(template type.base)"))
}

@Test(arguments: [40, 560])
func widgetSourceIndexesExamineEachPathOnceDespiteExpandedTokens(widgetCount: Int) throws {
    var tokens: [String: ConfigurationValue] = ["t0": .number(1)]
    for level in 1...13 {
        tokens["t\(level)"] = .array(Array(repeating: .string("@token.t\(level - 1)"), count: 2))
    }
    let ids = (0..<widgetCount).map { "w\($0)" }
    let value = ConfigurationValue.object([
        "tokens": .object(tokens), "bar": .object(["style": .object(["background": .string("@token.t13")])]),
        "widgets": .array(ids.map { .object([
            "id": .string($0), "type": .string("text"), "position": .string("left"), "text": .string("x")
        ]) })
    ])
    let resolved = try substituteConfigurationReferences(value, prefix: "@token.", values: tokens)
    let origins = configurationOrigins(resolved, source: ConfigurationOrigin(file: "theme.json"))
    let layer = ConfigurationLayer(values: try resolved.decoded([String: ConfigurationValue].self), origins: origins)
    #expect(origins.count == 49_139 + 5 * widgetCount)
    let prefixes = Set(ids.map { "widgets.\($0)" })
    var examinedOrigins = 0
    var examinedContributions = 0
    var originIndex = ConfigurationPathIndex(origins.lazy.map { entry in
        examinedOrigins += 1
        return entry
    }, prefixes: prefixes)
    var contributionIndex = ConfigurationPathIndex(layer.contributions.lazy.map { entry in
        examinedContributions += 1
        return entry
    }, prefixes: prefixes)
    for id in ids {
        let prefix = "widgets.\(id)"
        let propertyOrigins = originIndex[prefix]
        let propertyContributions = contributionIndex[prefix]
        #expect(propertyOrigins.count == 4)
        #expect(propertyContributions.count == 4)
        for (path, source) in propertyOrigins { originIndex.insert(source, at: "\(prefix).\(path)") }
        for (path, entries) in propertyContributions { contributionIndex.insert(entries, at: "\(prefix).\(path)") }
    }
    #expect(examinedOrigins == origins.count)
    #expect(examinedContributions == layer.contributions.count)
}

@Test func overlappingWidgetIDsStoreEachSourcePathOnce() throws {
    var ids: [String] = []
    var id = "w"
    for _ in 0..<128 {
        ids.append(id)
        id += ".w"
    }
    let values: [String: ConfigurationValue] = ["widgets": .array(ids.map { .object([
        "id": .string($0), "type": .string("text"), "position": .string("left"), "text": .string("x")
    ]) })]
    let origins = configurationOrigins(.object(values), source: ConfigurationOrigin(file: "config.json"))
    let layer = ConfigurationLayer(values: values, origins: origins)
    let prefixes = Set(ids.map { "widgets.\($0)" })
    var originIndex = ConfigurationPathIndex(origins, prefixes: prefixes)
    var contributionIndex = ConfigurationPathIndex(layer.contributions, prefixes: prefixes)
    let storedPaths = origins.keys.filter { $0.hasPrefix("widgets.w.") }.count
    #expect(originIndex.storedPathCount == storedPaths)
    #expect(contributionIndex.storedPathCount == storedPaths)
    for prefix in prefixes {
        var expectedOrigins: [String: ConfigurationOrigin] = [:]
        var expectedContributions: [String: [ConfigurationContribution]] = [:]
        for (path, source) in origins where path.hasPrefix(prefix + ".") {
            let suffix = String(path.dropFirst(prefix.count + 1))
            expectedOrigins[suffix] = source
            expectedContributions[suffix] = layer.contributions[path]
        }
        #expect(originIndex[prefix] == expectedOrigins)
        #expect(contributionIndex[prefix] == expectedContributions)
    }
    let lastID = try #require(ids.last)
    let path = "widgets.\(lastID).text"
    let copiedSource = ConfigurationOrigin(file: "template.json")
    let copiedEntries = [ConfigurationContribution(value: .string("copy"), origin: copiedSource)]
    originIndex.insert(copiedSource, at: path)
    contributionIndex.insert(copiedEntries, at: path)
    #expect(originIndex.storedPathCount == storedPaths)
    #expect(contributionIndex.storedPathCount == storedPaths)
    let newPath = "widgets.\(lastID).style.fontSize"
    originIndex.insert(copiedSource, at: newPath)
    contributionIndex.insert(copiedEntries, at: newPath)
    #expect(originIndex.storedPathCount == storedPaths + 1)
    #expect(contributionIndex.storedPathCount == storedPaths + 1)
    for prefix in prefixes {
        #expect(originIndex[prefix][String(path.dropFirst(prefix.count + 1))] == copiedSource)
        #expect(contributionIndex[prefix][String(path.dropFirst(prefix.count + 1))] == copiedEntries)
        #expect(originIndex[prefix][String(newPath.dropFirst(prefix.count + 1))] == copiedSource)
        #expect(contributionIndex[prefix][String(newPath.dropFirst(prefix.count + 1))] == copiedEntries)
    }
}

@Test func widgetIDsInheritedFromTemplatesKeepTheirSources() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "inherited-widget-id.json")
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    _ = try loader.load(root, data: Data(#"""
    {"templates":{"label":{"id":"status.main","type":"text","position":"left","text":"Ready"}},
     "widgets":[{"template":"label"}],"widgetOverrides":{"status.main":{"text":"Changed"}}}
    """#.utf8))
    let source = ConfigurationOrigin(file: root.path)
    #expect(loader.origins["widgets.status.main.id"] == source.appending("(template label)"))
    #expect(loader.origins["widgets.status.main.text"] == source.appending("(widget override)"))
    let history = try #require(loader.contributions["widgets.status.main.text"])
    #expect(history.map(\.value) == [.string("Ready"), .string("Changed")])
    #expect(history.map(\.origin) == [source.appending("(template label)"), source.appending("(widget override)")])
}

@Test func sourceIndexesMatchDottedPrefixesAndKeepLaterCopies() {
    let prefixes: Set<String> = ["widgets.status", "widgets.status.main", "templates.type", "templates.type.base",
                                 "widgetOverrides.status", "widgetOverrides.status.main", "popups.details",
                                 "widgets.status.", "popups.详情"]
    var sources = ["widgets.status.main.text": "widget", "widgets.status.mainly.text": "other widget",
                   "widgets.status.main": "root", "templates.type.base.text": "template",
                   "widgetOverrides.status.main.style.fontSize": "override", "popups.details.layout.text": "popup",
                   "tokens.unrelated": "token", "widgets.status..text": "empty segment",
                   "widgets.status.": "empty suffix", "popups.详情.text": "unicode"]
    var index = ConfigurationPathIndex(sources, prefixes: prefixes)
    let beforeCopies = index
    index.insert("template copy", at: "widgets.status.main.style.fontSize")
    sources["widgets.status.main.style.fontSize"] = "template copy"
    index.insert("updated widget", at: "widgets.status.main.text")
    sources["widgets.status.main.text"] = "updated widget"
    for prefix in prefixes {
        var expected: [String: String] = [:]
        for (path, source) in sources where path.hasPrefix(prefix + ".") {
            expected[String(path.dropFirst(prefix.count + 1))] = source
        }
        #expect(index[prefix] == expected)
    }
    #expect(beforeCopies["widgets.status.main"]["text"] == "widget")
    #expect(beforeCopies["widgets.status.main"]["style.fontSize"] == nil)
    #expect(index["widgets.status.main.style"].isEmpty)
    #expect(index["widgets.missing"].isEmpty)
}

@Test(arguments: ["@token.", "@setting."])
func referenceExpansionCountsVisitedValuesAcrossTheWholeCall(prefix: String) throws {
    let literal = ConfigurationValue.array(Array(repeating: .number(1), count: 100_000))
    #expect(try substituteConfigurationReferences(literal, prefix: prefix, values: [:]) == literal)
    let replacement = ConfigurationValue.array(Array(repeating: .number(1), count: 49_998))
    let reference = ConfigurationValue.string(prefix + "alias")
    let values: [String: ConfigurationValue] = [
        "alias": .string(prefix + "big"), "big": replacement,
        "last": .string(prefix + "leaf"), "leaf": .number(1)
    ]
    #expect(try substituteConfigurationReferences(.array([reference, reference]), prefix: prefix, values: values)
        == .array([replacement, replacement]))
    let error = #expect(throws: ThemeConfigurationError.self) {
        _ = try substituteConfigurationReferences(.array([.string(prefix + "big"), reference, .string(prefix + "last")]),
                                                prefix: prefix, values: values)
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "leaf")
    #expect(error?.errorDescription == "Configuration references expand past StableBar's limit at leaf. "
        + "Check tokens or settings that refer to each other.")
}

@Test(arguments: ["@token.", "@setting."])
func referenceExpansionChargesRepeatedAliasHops(prefix: String) throws {
    var values: [String: ConfigurationValue] = ["a59": .number(1)]
    for index in 0..<59 {
        values["a\(index)"] = .string(prefix + "a\(index + 1)")
    }
    let shortReferences = ConfigurationValue.array(Array(repeating: .string(prefix + "a57"), count: 200))
    #expect(try substituteConfigurationReferences(shortReferences, prefix: prefix, values: values)
        == .array(Array(repeating: .number(1), count: 200)))
    let longReferences = ConfigurationValue.array(Array(repeating: .string(prefix + "a0"), count: 2_000))
    let error = #expect(throws: ThemeConfigurationError.self) {
        _ = try substituteConfigurationReferences(longReferences, prefix: prefix, values: values)
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "a40")
}

@Test(arguments: ["@token.", "@setting."], [false, true])
func referenceExpansionChargesStringBytesPerVisit(prefix: String, multibyte: Bool) throws {
    for (byteCount, copies) in [(255, 100_000), (256, 50_000), (20_000, 1_265)] {
        let string = multibyte
            ? String(repeating: "é", count: byteCount / 2) + String(repeating: "x", count: byteCount % 2)
            : String(repeating: "x", count: byteCount)
        let reference = ConfigurationValue.string(prefix + "s")
        let values = ["s": ConfigurationValue.string(string)]
        let fits = ConfigurationValue.array(Array(repeating: reference, count: copies))
        #expect(try substituteConfigurationReferences(fits, prefix: prefix, values: values)
            == .array(Array(repeating: .string(string), count: copies)))
        let tooMany = ConfigurationValue.array(Array(repeating: reference, count: copies + 1))
        let error = #expect(throws: ThemeConfigurationError.self) {
            _ = try substituteConfigurationReferences(tooMany, prefix: prefix, values: values)
        }
        guard case let .referenceExpansionTooLarge(name)? = error else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(name == "s")
    }
}

@Test(arguments: ["@token.", "@setting."])
func referenceExpansionRejectsNestedCopiesOfLongStrings(prefix: String) throws {
    let values: [String: ConfigurationValue] = [
        "s": .string(String(repeating: "x", count: 25_000)),
        "t1": .array(Array(repeating: .string(prefix + "s"), count: 100)),
        "t2": .array(Array(repeating: .string(prefix + "t1"), count: 295))
    ]
    let error = #expect(throws: ThemeConfigurationError.self) {
        _ = try substituteConfigurationReferences(.string(prefix + "t2"), prefix: prefix, values: values)
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "s")
}

@Test func tokensThatCopyLongStringsCannotExhaustLoading() throws {
    let tokens: [String: ConfigurationValue] = [
        "s": .string(String(repeating: "x", count: 25_000)),
        "t1": .array(Array(repeating: .string("@token.s"), count: 100)),
        "t2": .array(Array(repeating: .string("@token.t1"), count: 295))
    ]
    let data = try JSONEncoder().encode(ConfigurationValue.object([
        "widgets": .array([]), "tokens": .object(tokens)
    ]))
    #expect(data.count <= 32_000)
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let error = #expect(throws: ThemeConfigurationError.self) {
        _ = try loader.load(FileManager.default.temporaryDirectory.appending(path: "long-string-tokens.json"), data: data)
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "s")
}

@Test func aLongStringTokenCanBeUsedByAFewWidgets() throws {
    let text = String(repeating: "x", count: 20_000)
    let ids = ["first", "second", "third"]
    let data = try JSONEncoder().encode(ConfigurationValue.object([
        "tokens": .object(["text": .string(text)]),
        "widgets": .array(ids.map { .object([
            "id": .string($0), "type": .string("text"), "position": .string("left"), "text": .string("@token.text")
        ]) })
    ]))
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let root = FileManager.default.temporaryDirectory.appending(path: "shared-long-string.json")
    let configuration = try loader.load(root, data: data)
    #expect(configuration.widgets.map(\.id) == ids)
    for widget in configuration.widgets {
        #expect(widget.content == .text(text))
        #expect(loader.origins["widgets.\(widget.id).text"]?.token == "text")
    }
}

@Test(arguments: ["@token.", "@setting."])
func longStringsOutsideReferencesUseNoExpansionBudget(prefix: String) throws {
    let string = ConfigurationValue.string(String(repeating: "x", count: 20_000))
    let literals = ConfigurationValue.array(Array(repeating: string, count: 1_500))
    let value = ConfigurationValue.array([literals, .string(prefix + "number")])
    #expect(try substituteConfigurationReferences(value, prefix: prefix, values: ["number": .number(1)])
        == .array([literals, .number(1)]))
}

@Test(arguments: ["@token.", "@setting."], [false, true])
func referenceExpansionChargesKeyBytesPerVisit(prefix: String, multibyte: Bool) throws {
    for (byteCount, copies) in [(255, 50_000), (256, 33_333), (20_000, 1_250)] {
        let key = multibyte
            ? String(repeating: "é", count: byteCount / 2) + String(repeating: "x", count: byteCount % 2)
            : String(repeating: "x", count: byteCount)
        let object = ConfigurationValue.object([key: .number(1)])
        let reference = ConfigurationValue.string(prefix + "s")
        let fits = ConfigurationValue.array(Array(repeating: reference, count: copies))
        #expect(try substituteConfigurationReferences(fits, prefix: prefix, values: ["s": object])
            == .array(Array(repeating: object, count: copies)))
        let tooMany = ConfigurationValue.array(Array(repeating: reference, count: copies + 1))
        let error = #expect(throws: ThemeConfigurationError.self) {
            _ = try substituteConfigurationReferences(tooMany, prefix: prefix, values: ["s": object])
        }
        guard case let .referenceExpansionTooLarge(name)? = error else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(name == "s")
    }
}

@Test(arguments: ["@token.", "@setting."])
func referenceExpansionRejectsNestedCopiesOfLongKeys(prefix: String) throws {
    let values: [String: ConfigurationValue] = [
        "s": .object([String(repeating: "x", count: 25_000): .number(1)]),
        "t1": .array(Array(repeating: .string(prefix + "s"), count: 100)),
        "t2": .array(Array(repeating: .string(prefix + "t1"), count: 295))
    ]
    let error = #expect(throws: ThemeConfigurationError.self) {
        _ = try substituteConfigurationReferences(.string(prefix + "t2"), prefix: prefix, values: values)
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "s")
}

@Test func tokensThatCopyLongKeysCannotExhaustLoading() throws {
    let tokens: [String: ConfigurationValue] = [
        "s": .object([String(repeating: "x", count: 25_000): .number(1)]),
        "t1": .array(Array(repeating: .string("@token.s"), count: 100)),
        "t2": .array(Array(repeating: .string("@token.t1"), count: 295))
    ]
    let data = try JSONEncoder().encode(ConfigurationValue.object([
        "widgets": .array([]), "tokens": .object(tokens)
    ]))
    #expect(data.count <= 32_000)
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let error = #expect(throws: ThemeConfigurationError.self) {
        _ = try loader.load(FileManager.default.temporaryDirectory.appending(path: "long-key-tokens.json"), data: data)
    }
    guard case let .referenceExpansionTooLarge(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "s")
}

@Test func aTokenWithAFewLongKeysCanBeCopiedAFewTimes() throws {
    let keys = ["x", "y", "z"].map { String(repeating: $0, count: 20_000) }
    let object = ConfigurationValue.object(Dictionary(uniqueKeysWithValues: keys.map { ($0, .number(1)) }))
    let data = try JSONEncoder().encode(ConfigurationValue.object([
        "widgets": .array([]),
        "tokens": .object([
            "s": object, "copies": .array(Array(repeating: .string("@token.s"), count: 3))
        ])
    ]))
    var loader = ConfigurationLoader()
    loader.themesDirectory = nil
    let root = FileManager.default.temporaryDirectory.appending(path: "shared-long-keys.json")
    #expect(try loader.load(root, data: data).widgets.isEmpty)
    let tokens = try #require(try loader.document["tokens"]?.decoded([String: ConfigurationValue].self))
    #expect(tokens["copies"] == .array(Array(repeating: object, count: 3)))
    for key in keys {
        #expect(loader.origins["tokens.copies.0.\(key)"]?.token == "s")
    }
}

@Test(arguments: ["@token.", "@setting."], [false, true])
func referenceExpansionChargesLongNamesPerHop(prefix: String, multibyte: Bool) throws {
    let name = String(repeating: multibyte ? "é" : "a", count: multibyte ? 8_000 : 16_000)
    let reference = ConfigurationValue.string(prefix + name)
    let values = [name: ConfigurationValue.number(1)]
    let fits = ConfigurationValue.array(Array(repeating: reference, count: 1_587))
    #expect(try substituteConfigurationReferences(fits, prefix: prefix, values: values)
        == .array(Array(repeating: .number(1), count: 1_587)))
    let tooMany = ConfigurationValue.array(Array(repeating: reference, count: 1_588))
    let error = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(tooMany, prefix: prefix, values: values)
    }
    guard case let .referenceExpansionTooLarge(failedName)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(failedName == name)
    let largeReplacement = ConfigurationValue.array(Array(repeating: .number(1), count: 99_937))
    #expect(try substituteConfigurationReferences(reference, prefix: prefix, values: [name: largeReplacement])
        == largeReplacement)
}

@Test(arguments: ["@token.", "@setting."], [false, true])
func referenceExpansionChargesNestedLongNamesOnlyPerHop(prefix: String, multibyte: Bool) throws {
    for byteCount in [255, 256] {
        let name = multibyte
            ? String(repeating: "é", count: byteCount / 2) + String(repeating: "x", count: byteCount % 2)
            : String(repeating: "x", count: byteCount)
        let reference = ConfigurationValue.string(prefix + name)
        for nested in [false, true] {
            let leaves = 99_999 - byteCount / 256 - (nested ? 1 : 0)
            let replacement = ConfigurationValue.array(Array(repeating: .number(1), count: leaves))
            let value = nested ? ConfigurationValue.string(prefix + "alias") : reference
            let values: [String: ConfigurationValue] = ["alias": reference, name: replacement]
            #expect(try substituteConfigurationReferences(value, prefix: prefix, values: values) == replacement)
            let tooLarge = ConfigurationValue.array(Array(repeating: .number(1), count: leaves + 1))
            let error = #expect(throws: ThemeConfigurationError.self) {
                _ = try substituteConfigurationReferences(value, prefix: prefix,
                                                          values: ["alias": reference, name: tooLarge])
            }
            guard case let .referenceExpansionTooLarge(failedName)? = error else {
                Issue.record("wrong error: \(String(describing: error))")
                return
            }
            #expect(failedName == name)
        }
    }
}

@Test(arguments: ["@token.", "@setting."])
func referenceNestingTooDeepAlongAliasChainsOnAWorkerThread(prefix: String) throws {
    #expect(!Thread.isMainThread)
    var values: [String: ConfigurationValue] = ["a999": .number(1)]
    for index in 0..<999 {
        values["a\(index)"] = .string(prefix + "a\(index + 1)")
    }
    #expect(try substituteConfigurationReferences(.string(prefix + "a935"), prefix: prefix, values: values) == .number(1))
    let error = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(.string(prefix + "a0"), prefix: prefix, values: values)
    }
    guard case let .referenceNestingTooDeep(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "a64")
    #expect(error?.errorDescription == "Configuration references nest more than 64 levels deep at a64. "
        + "Check tokens or settings that refer to each other.")
}

@Test(arguments: ["@token.", "@setting."], [false, true])
func referencesNestAtMost64ContainerLevels(prefix: String, objects: Bool) throws {
    var fits = ConfigurationValue.number(1)
    for _ in 0..<64 {
        fits = objects ? .object(["child": fits]) : .array([fits])
    }
    let reference = ConfigurationValue.string(prefix + "nested")
    let siblings = ConfigurationValue.array([reference, reference])
    #expect(try substituteConfigurationReferences(siblings, prefix: prefix, values: ["nested": fits]) == .array([fits, fits]))
    let tooDeep = objects ? ConfigurationValue.object(["child": fits]) : .array([fits])
    #expect(try substituteConfigurationReferences(tooDeep, prefix: prefix, values: [:]) == tooDeep)
    let error = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(reference, prefix: prefix, values: ["nested": tooDeep])
    }
    guard case let .referenceNestingTooDeep(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "nested")
}

@Test(arguments: ["@token.", "@setting."])
func referencesNestCountsContainersAndAliasHopsTogether(prefix: String) throws {
    let reference = ConfigurationValue.string(prefix + "nested")
    var nested = ConfigurationValue.string(prefix + "alias")
    for level in 0..<63 {
        nested = level.isMultiple(of: 2) ? .object(["child": nested]) : .array([nested])
    }
    let values: [String: ConfigurationValue] = [
        "nested": nested, "alias": .number(1), "outer": .array([reference])
    ]
    var expected = ConfigurationValue.number(1)
    for level in 0..<63 {
        expected = level.isMultiple(of: 2) ? .object(["child": expected]) : .array([expected])
    }
    #expect(try substituteConfigurationReferences(reference, prefix: prefix, values: values) == expected)
    let error = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(.string(prefix + "outer"), prefix: prefix, values: values)
    }
    guard case let .referenceNestingTooDeep(name)? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
    #expect(name == "nested")
}

@Test(arguments: ["@token.", "@setting."])
func referenceExpansionPreservesCyclePathsAndUnknownNames(prefix: String) throws {
    let cycle = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(.string(prefix + "b"), prefix: prefix,
                                              values: ["b": .string(prefix + "a")], path: ["a"])
    }
    guard case let .referenceCycle(names)? = cycle else {
        Issue.record("wrong error: \(String(describing: cycle))")
        return
    }
    #expect(names == ["a", "b", "a"])
    let unknown = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(.string(prefix + "missing"), prefix: prefix, values: [:])
    }
    guard case let .unknownReference(name)? = unknown else {
        Issue.record("wrong error: \(String(describing: unknown))")
        return
    }
    #expect(name == prefix + "missing")
}

@Test func tokensThatDoubleEachOtherFailToLoadInsteadOfExpanding() throws {
    // t17 expands to 2^18 leaves: small to write, far over the limit.
    var tokens = [#""t0": [1, 1]"#]
    for level in 1...17 { tokens.append(#""t\#(level)": ["@token.t\#(level - 1)", "@token.t\#(level - 1)"]"#) }
    let json = #"{"widgets":[],"tokens":{\#(tokens.joined(separator: ","))},"bar":{"style":{"background":"@token.t17"}}}"#
    var loader = ConfigurationLoader()
    let url = FileManager.default.temporaryDirectory.appending(path: "tokens.json")
    let error = #expect(throws: ThemeConfigurationError.self) { try loader.load(url, data: Data(json.utf8)) }
    guard case .referenceExpansionTooLarge? = error else {
        Issue.record("wrong error: \(String(describing: error))")
        return
    }
}

@Test(arguments: ["@token.", "@setting."])
func aSharedReferenceBudgetRetainsThePerCallLimitAndCountsFailedCalls(prefix: String) throws {
    let budget = ConfigurationReferenceExpansionBudget(limit: 300_000)
    let fits = ConfigurationValue.array(Array(repeating: .number(1), count: 99_999))
    let tooBig = ConfigurationValue.array(Array(repeating: .number(1), count: 100_000))
    let values = ["fits": fits, "big": tooBig]
    let reference = ConfigurationValue.string(prefix + "fits")
    let perCallError = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(.string(prefix + "big"), prefix: prefix, values: values, budget: budget)
    }
    guard case .referenceExpansionTooLarge? = perCallError else {
        Issue.record("Expected the unchanged per-call limit, got \(String(describing: perCallError))")
        return
    }
    #expect(budget.consumed == 100_000)
    for used in [200_000, 300_000] {
        #expect(try substituteConfigurationReferences(reference, prefix: prefix, values: values, budget: budget) == fits)
        #expect(budget.consumed == used)
    }
    let sharedError = #expect(throws: ThemeConfigurationError.self) {
        try substituteConfigurationReferences(reference, prefix: prefix, values: values, budget: budget)
    }
    guard case .referenceExpansionTooLarge? = sharedError else {
        Issue.record("Expected the shared limit, got \(String(describing: sharedError))")
        return
    }
    #expect(budget.consumed == 300_000)
    #expect(try substituteConfigurationReferences(reference, prefix: prefix, values: values) == fits)
}

@Test func aLoadersSharedBudgetIncludesAppearanceOriginsAndLaterFinishes() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let theme = try fixture.theme(#"{"tokens":{"look":"light"},"bar":{"appearance":"@token.look"}}"#, install: false)
    let budget = ConfigurationReferenceExpansionBudget(limit: 3)
    var loader = ConfigurationLoader()
    loader.referenceExpansionBudget = budget
    let layer = try loader.readPackage(at: theme.directory, manifest: theme.manifest, settings: [:])
    #expect(try loader.finish(layer, context: ConfigurationContext())["bar"] == .object(["appearance": .string("light")]))
    #expect(budget.consumed == 3)
    var copy = loader
    let error = #expect(throws: ThemeConfigurationError.self) { try copy.finish(layer, context: ConfigurationContext()) }
    guard case .referenceExpansionTooLarge? = error else {
        Issue.record("Expected the copied loader to share its budget, got \(String(describing: error))")
        return
    }
}

@Suite struct ThemeLinkOriginBudgetTests {
    @Test func copiedLoadersShareUTF8OriginPathBytesAndKeepTheDefaultUnchanged() throws {
        let values: [String: ConfigurationValue] = [
            "widgets": .array([]),
            "tokens": .object(["s": .object(["é": .number(1)]), "t": .string("@token.s")])
        ]
        let layer = ConfigurationLayer(values: values,
                                       origins: configurationOrigins(.object(values), source: ConfigurationOrigin(file: "theme.json")))
        let bytes = "tokens.t".utf8.count + "tokens.t.é".utf8.count
        let budget = ConfigurationReferenceExpansionBudget(limit: 300_000, originPathByteLimit: bytes * 2)
        var loader = ConfigurationLoader()
        loader.referenceExpansionBudget = budget
        let expected = try loader.finish(layer, context: ConfigurationContext())
        #expect(budget.consumedOriginPathBytes == bytes)
        var copy = loader
        #expect(try copy.finish(layer, context: ConfigurationContext()) == expected)
        #expect(budget.consumedOriginPathBytes == bytes * 2)
        let error = #expect(throws: ThemeConfigurationError.self) {
            try loader.finish(layer, context: ConfigurationContext())
        }
        guard case .referenceOriginsTooLarge("s")? = error else {
            Issue.record("Expected the shared origin-path limit, got \(String(describing: error))")
            return
        }
        #expect(budget.consumedOriginPathBytes == bytes * 2)
        var ordinary = ConfigurationLoader()
        #expect(try ordinary.finish(layer, context: ConfigurationContext()) == expected)
    }

    @Test func templateCopiesChargeTheirDestinationPathsToTheSharedAllowance() throws {
        let values: [String: ConfigurationValue] = [
            "tokens": .object(["s": .object(["fontSize": .number(12)])]),
            "templates": .object(["base": .object([
                "type": .string("text"), "position": .string("left"), "text": .string("Ready"),
                "style": .string("@token.s")
            ])]),
            "widgets": .array([.object(["id": .string("x"), "template": .string("base")])])
        ]
        let layer = ConfigurationLayer(values: values,
                                       origins: configurationOrigins(.object(values), source: ConfigurationOrigin(file: "theme.json")))
        let paths = ["templates.base.style", "templates.base.style.fontSize", "widgets.x.style", "widgets.x.style.fontSize"]
        let bytes = paths.reduce(0) { $0 + $1.utf8.count }
        let budget = ConfigurationReferenceExpansionBudget(limit: 300_000, originPathByteLimit: bytes)
        var loader = ConfigurationLoader()
        loader.referenceExpansionBudget = budget
        _ = try loader.finish(layer, context: ConfigurationContext())
        #expect(budget.consumedOriginPathBytes == bytes)
    }
}

@Test func settingContributionsCannotSwallowTheSharedBudgetError() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let source = fixture.directory.appending(path: "source")
    try fixture.write(#"{"id":"settings","name":"Settings","version":"1","kind":"theme","entry":"config.json","settings":{"size":{"type":"number","default":12}}}"#,
                      to: source.appending(path: "package.json"))
    try fixture.write(#"{"defaults":{"fontSize":"@setting.size"}}"#, to: source.appending(path: "config.json"))
    let manifest = try fixture.packages.manifest(at: source)
    var loader = ConfigurationLoader()
    _ = try loader.readPackage(at: source, manifest: manifest, settings: [:])
    let budget = ConfigurationReferenceExpansionBudget(limit: 1)
    loader.referenceExpansionBudget = budget
    let error = #expect(throws: ThemeConfigurationError.self) {
        try loader.readPackage(at: source, manifest: manifest, settings: [:])
    }
    guard case .referenceExpansionTooLarge? = error else {
        Issue.record("Expected setting contributions to propagate the shared limit, got \(String(describing: error))")
        return
    }
    #expect(budget.consumed == 1)
}

@Test func widgetOrderSkipsAbsentWidgetsAndRejectsDuplicates() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "order.json")
    var loader = ConfigurationLoader()
    let json = #"""
    {"widgets":[{"id":"a","type":"clock","position":"left"},{"id":"b","type":"clock","position":"left"}],
     "profiles":[{"name":"desktop","when":{"externalDisplay":true},"configuration":{
       "widgets":[{"id":"extra","type":"text","position":"right","text":"Desktop"}]}}],
     "widgetOrder":["extra","b"]}
    """#
    #expect(try loader.load(url, data: Data(json.utf8)).widgets.map(\.id) == ["b", "a"])
    #expect(loader.document["widgetOrder"] == nil)
    #expect(try loader.load(url, data: Data(json.utf8), context: ConfigurationContext(externalDisplay: true)).widgets.map(\.id) == ["extra", "b", "a"])
    #expect(throws: ConfigurationCompositionError.self) {
        try loader.load(url, data: Data(json.replacingOccurrences(of: #""widgetOrder":["extra","b"]"#, with: #""widgetOrder":["b","b"]"#).utf8))
    }
    #expect(throws: DecodingError.self) {
        try loader.load(url, data: Data(#"""
        {"widgets":[{"id":"a","type":"clock","position":"left"},{"id":"a","type":"clock","position":"left"}],"widgetOrder":["a"]}
        """#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try loader.load(url, data: Data(#"{"widgets":[{"type":"clock","position":"left"}]}"#.utf8))
    }
}

@Test(arguments: [false, true]) func storeEssentialsUpgradeInPlaceAndKeepOverridesAndRollbackFiles(fromFolder: Bool) throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let packages: [(String, String, String, String)] = [
        ("date", #""format":{"type":"string","default":"EEE d MMM"}"#,
         #""format":"yyyy-MM-dd""#, #""type":"clock","format":"@setting.format","open":"com.apple.iCal""#),
        ("battery-status", "", "", #""type":"battery","layout":{"type":"field","field":"text"}"#),
        ("network-speed", #""interval":{"type":"number","default":5}"#,
         #""interval":12"#, #""type":"provider","provider":"network-speed""#),
        ("calendar-agenda", #""lookahead":{"type":"number","default":24},"soon":{"type":"number","default":15},"now":{"type":"number","default":5}"#,
         #""lookahead":48,"soon":30,"now":10"#, #""type":"provider","provider":"calendar-agenda","layout":{"type":"field","field":"text"}"#),
        ("system-monitor", #""interval":{"type":"number","default":2},"processes":{"type":"number","default":5},"sortBy":{"type":"string","default":"memory"},"cpuWarning":{"type":"number","default":0.9},"memoryWarning":{"type":"number","default":0.9}"#,
         #""interval":8,"processes":3,"sortBy":"cpu","cpuWarning":1.01,"memoryWarning":0.75"#, #""type":"system","rules":[{"when":{"value":"cpu","above":"@setting.cpuWarning"},"state":"warning"}]"#)
    ]
    let providers = #""network-speed":{"type":"network","interval":"@setting.interval"}"#
    let calendar = #""calendar-agenda":{"type":"calendar","lookahead":"@setting.lookahead","soon":"@setting.soon","now":"@setting.now"}"#
    let system = #""system":{"type":"system","interval":"@setting.interval","processes":"@setting.processes"}"#
    var selections: [String] = []
    var installedFiles: [URL: Data] = [:]
    for (id, settings, saved, properties) in packages {
        let source = fixture.directory.appending(path: "source/\(id)")
        try fixture.write(#"{"id":"\#(id)","name":"\#(id)","version":"1","kind":"widgets","entry":"config.json","repository":"https://github.com/Seb-GRAF/stablebar-packages","settings":{\#(settings)}}"#, to: source.appending(path: "package.json"))
        let data = ["network-speed": providers, "calendar-agenda": calendar, "system-monitor": system][id] ?? ""
        try fixture.write(#"{"providers":{\#(data)},"popups":{"\#(id)":{"style":{},"layout":{"type":"text","text":"Old details"}}},"widgets":[{"id":"\#(id)","position":"right","popupName":"\#(id)",\#(properties)}]}"#, to: source.appending(path: "config.json"))
        let installed = try fixture.packages.install(source, record: fromFolder ? .local : PackageInstallRecord(PackageSource.store))
        for name in ["package.json", "config.json"] {
            let file = installed.directory.appending(path: name)
            installedFiles[file] = try Data(contentsOf: file)
        }
        selections.append(#"{"id":"\#(id)","version":"1","settings":{\#(saved)}}"#)
    }
    let included = fixture.directory.appending(path: "included.json")
    try fixture.write(#"{"packages":[\#(selections.joined(separator: ","))],"widgetOverrides":{"date":{"position":"left","display":"external","group":"dates"}},"groups":{"dates":{}}}"#, to: included)
    try fixture.write(#"""
    {"includes":["included.json"],"widgetOrder":["system-monitor","date","calendar-agenda","battery-status","network-speed"],
     "profiles":[{"name":"work","when":{"appearance":"dark"},"configuration":{
       "widgetOverrides":{"date":{"format":"dd/MM/yyyy","open":"com.apple.iCal"},"network-speed":{"enabled":false},
                          "battery-status":{"layout":{"type":"field","field":"text"}},
                          "system-monitor":{"rules":[{"when":{"value":"cpu","above":0.4},"state":"custom"}]}},
       "popups":{"calendar-agenda":{"style":{"width":400}}},
       "providers":{"network-speed":{"interval":20}}}}]}
    """#, to: fixture.url)
    let before = try Data(contentsOf: fixture.url)
    let includedBefore = try Data(contentsOf: included)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(fixture.url)
    #expect(loader.builtInWidgetIDs == Set(packages.map(\.0)))
    #expect(configuration.widgets.map(\.id) == ["system-monitor", "date", "calendar-agenda", "battery-status", "network-speed"])
    #expect(configuration.widgets.allSatisfy { $0.details && $0.popupName == nil && $0.layout == nil })
    let date = configuration.widgets[1]
    #expect(date.content == .clock(format: "yyyy-MM-dd"))
    #expect(date.position == .left && date.display == .external && date.group == "dates")
    #expect(date.open == nil)
    #expect(configuration.providers["network-speed"]?.interval == 12)
    #expect(configuration.providers["calendar-agenda"]?.lookahead == 48)
    #expect(configuration.providers["calendar-agenda"]?.soon == 30)
    #expect(configuration.providers["calendar-agenda"]?.now == 10)
    #expect(configuration.providers["system"]?.interval == 8)
    #expect(configuration.providers["system"]?.processes == 3)
    #expect(configuration.providers["system"]?.sortBy == .cpu)
    #expect(configuration.providers["system"]?.cpuWarning == 1.01)
    #expect(configuration.providers["system"]?.memoryWarning == 0.75)
    #expect(configuration.widgets[0].rules.isEmpty)
    let dark = try loader.load(fixture.url, context: ConfigurationContext(appearance: "dark"))
    #expect(dark.widgets[1].content == .clock(format: "dd/MM/yyyy"))
    #expect(dark.widgets[1].open == "com.apple.iCal")
    #expect(dark.widgets[0].rules.first?.state == "custom")
    #expect(dark.widgets[2].popupName == "calendar-agenda")
    #expect(dark.popups["calendar-agenda"]?.style.width == 400)
    #expect(dark.widgets[3].layout != nil)
    #expect(!dark.widgets[4].enabled)
    #expect(dark.providers["network-speed"]?.interval == 20)
    #expect(try Data(contentsOf: fixture.url) == before)
    #expect(try Data(contentsOf: included) == includedBefore)
    for (file, data) in installedFiles { #expect(try Data(contentsOf: file) == data) }
    #expect(try loader.load(fixture.url).widgets.map(\.id) == configuration.widgets.map(\.id))
}

@Test func essentialsUpgradeRecognizesOfficialFoldersAndPreservesPrivateCopies() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let directory = fixture.packages.directory.appending(path: "date/1")
    try fixture.write(#"{"id":"date","name":"Date","version":"1","kind":"widgets","entry":"config.json","repository":"https://github.com/Seb-GRAF/stablebar-packages"}"#, to: directory.appending(path: "package.json"))
    try fixture.write(#"{"widgets":[{"id":"date","type":"clock","position":"right","format":"EEE d MMM","open":"com.apple.iCal"}]}"#, to: directory.appending(path: "config.json"))
    try fixture.write(#"{"packages":[{"id":"date","version":"1"}]}"#, to: fixture.url)
    var loader = ConfigurationLoader()
    #expect(try loader.load(fixture.url).widgets[0].details)
    let official = PackageInstallRecord(source: PackageSource.storeID, name: PackageSource.store.name, url: PackageSource.store.url)
    let privateCopy = PackageInstallRecord(source: "team", name: "Team", url: URL(string: "https://example.com/index.json"))
    for record in [PackageInstallRecord.local, official, official.settingLocal("1", true)] {
        try JSONEncoder().encode(record).write(to: directory.deletingLastPathComponent().appending(path: PackageInstallRecord.fileName))
        #expect(try loader.load(fixture.url).widgets[0].details)
        #expect(loader.builtInWidgetIDs == ["date"])
    }
    for record in [privateCopy, privateCopy.settingLocal("1", true)] {
        try JSONEncoder().encode(record).write(to: directory.deletingLastPathComponent().appending(path: PackageInstallRecord.fileName))
        let configuration = try loader.load(fixture.url)
        #expect(!configuration.widgets[0].details)
        #expect(configuration.widgets[0].open == "com.apple.iCal")
        #expect(loader.builtInWidgetIDs.isEmpty)
    }
    try fixture.write(#"{"id":"date","name":"My date","version":"1","kind":"widgets","entry":"config.json","repository":"https://example.com/my-date"}"#, to: directory.appending(path: "package.json"))
    for record in [PackageInstallRecord.local, official.settingLocal("1", true)] {
        try JSONEncoder().encode(record).write(to: directory.deletingLastPathComponent().appending(path: PackageInstallRecord.fileName))
        #expect(try loader.load(fixture.url).widgets[0].open == "com.apple.iCal")
        #expect(loader.builtInWidgetIDs.isEmpty)
    }
    #expect(try loader.load(fixture.url, data: Data(#"{"packages":[{"id":"date","version":"1","enabled":false}]}"#.utf8)).widgets.isEmpty)
    #expect(loader.builtInWidgetIDs.isEmpty)
}

@Test func packagesInstallWithoutExecutingAndComposePinnedSettingsAndAssets() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "bar/packages"))
    let marker = directory.appending(path: "executed")
    try writePackageFile(#"""
    {"id":"weather","name":"Weather","version":"1.0.0","entry":"config.json",
     "settings":{"label":{"type":"string","default":"Weather"},"size":{"type":"number","default":13}}}
    """#, to: source.appending(path: "package.json"))
    try writePackageFile("touch '\(marker.path)'", to: source.appending(path: "scripts/weather.sh"))
    try writePackageFile("image", to: source.appending(path: "assets/icon.png"))
    try writePackageFile(#"""
    {"tokens":{"image":"assets/icon.png"},"templates":{"exported":{"type":"script","position":"left","command":"echo exported"}},
     "widgets":[{"id":"weather","type":"text","position":"right","text":"@setting.label",
      "style":{"fontSize":"@setting.size"},"onClick":"sh \"$PACKAGE_DIR/scripts/weather.sh\"",
      "popup":{"height":120,"style":{},"layout":{"type":"image","path":"@token.image","onClickField":"joinCommand"}}}],
     "profiles":[{"name":"night","enabled":false,"when":{"appearance":"dark"},"configuration":{
       "widgetOverrides":{"weather":{"onClick":"echo night"}}}}]}
    """#, to: source.appending(path: "config.json"))
    let inspection = try store.inspect(source)
    #expect(inspection.commands == ["Command from field \"joinCommand\"", "echo exported", "echo night", "sh \"$PACKAGE_DIR/scripts/weather.sh\""])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let installed = try store.install(source)
    #expect(installed.directory == directory.appending(path: "bar/packages/weather/1.0.0"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(throws: WidgetPackageError.self) { try store.install(source) }
    var loader = ConfigurationLoader()
    let root = directory.appending(path: "bar/config.json")
    let configuration = try loader.load(root, data: Data(#"""
    {"packages":[{"id":"weather","version":"1.0.0","settings":{"label":"Local","size":19}}],
     "widgetOverrides":{"weather":{"position":"left"}}}
    """#.utf8))
    let widget = configuration.widgets[0]
    #expect(widget.content == .text("Local"))
    #expect(widget.style.fontSize == 19)
    #expect(widget.position == .left)
    #expect(widget.environment["PACKAGE_DIR"] == installed.directory.path)
    guard case let .image(path, _, _) = widget.popup?.layout.content else {
        Issue.record("Expected package image")
        return
    }
    #expect(path == installed.directory.appending(path: "assets/icon.png").path)
    #expect(loader.dependencies.contains(installed.directory.appending(path: "package.json")))
}

@Test func packagePinsAllowRollbackAndDisabledPackagesDoNotLoad() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    for version in ["1", "2"] {
        try writePackageFile("""
        {"id":"clock","name":"Clock","version":"\(version)","entry":"config.json"}
        """, to: source.appending(path: "package.json"))
        try writePackageFile("""
        {"widgets":[{"id":"clock","type":"text","position":"left","text":"Version \(version)"}]}
        """, to: source.appending(path: "config.json"))
        _ = try store.install(source)
    }
    #expect(try store.list().map(\.version) == ["1", "2"])
    var loader = ConfigurationLoader()
    for version in ["2", "1"] {
        let configuration = try loader.load(directory.appending(path: "config.json"), data: Data("""
        {"packages":[{"id":"clock","version":"\(version)"},{"id":"missing","version":"1","enabled":false}]}
        """.utf8))
        #expect(configuration.widgets[0].content == .text("Version \(version)"))
    }
}

@Test @MainActor func uninstallDisablesInheritedSelectionsAndKeepsOtherVersionsAndSettings() throws {
    for kind in ["widgets", "theme"] {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source")
        let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
        for version in ["1", "2"] {
            try writePackageFile(#"""
            {"id":"sample","name":"Sample","version":"\#(version)","kind":"\#(kind)","entry":"config.json",
             "settings":{"size":{"type":"number","default":40}}}
            """#, to: source.appending(path: "package.json"))
            try writePackageFile(#"{"bar":{"height":"@setting.size"}}"#, to: source.appending(path: "config.json"))
            _ = try packages.install(source)
        }
        let selection = #"{"id":"sample","version":"1","settings":{"size":48}}"#
        let imported = kind == "theme" ? #"{"theme":\#(selection)}"# : #"{"packages":[\#(selection)]}"#
        let module = directory.appending(path: "module.json")
        try writePackageFile(imported, to: module)
        let url = directory.appending(path: "config.json")
        try writePackageFile(#"{"includes":["module.json"],"widgets":[]}"#, to: url)
        let store = BarStore(configurationURL: url)
        defer { store.stop() }
        store.reloadConfiguration()
        #expect(store.configuration?.bar.height == 48)
        try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["height": .number(52)])], persist: false)
        try store.uninstallPackage(id: "sample", version: "2")
        #expect(try packages.list().map(\.version) == ["1"])
        #expect(store.sessionEdits.isEmpty)
        let command = try LaunchCommand(arguments: ["--config", url.path, "--uninstall-package", "sample", "1"])
        guard case let .control(target, request) = command else { Issue.record("Expected control command"); return }
        #expect(target == url)
        _ = try store.handle(request)
        #expect(try packages.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: packages.directory.appending(path: "sample/1").path))
        #expect(try String(contentsOf: module, encoding: .utf8) == imported)
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "config.json").path))
        store.reloadConfiguration()
        #expect(store.configurationError == nil)
        #expect(store.configuration?.bar.height == 52)
        let saved = try kind == "theme"
            ? #require(store.effectiveDocument["theme"]).decoded(WidgetPackageSelection.self)
            : #require(store.effectiveDocument["packages"]).decoded([WidgetPackageSelection].self)[0]
        #expect(!saved.enabled)
        #expect(saved.settings == ["size": .number(48)])
    }
}

@Test @MainActor func uninstallSavesSessionPinsBeforeDeletingThePreviouslySelectedVersion() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    for version in ["1", "2"] {
        try writePackageFile(#"{"id":"clock","name":"Clock","version":"\#(version)","entry":"config.json"}"#,
                             to: source.appending(path: "package.json"))
        try writePackageFile(#"{"widgets":[{"id":"clock","type":"text","position":"left","text":"\#(version)"}]}"#,
                             to: source.appending(path: "config.json"))
        _ = try packages.install(source)
    }
    let url = directory.appending(path: "config.json")
    try writePackageFile(#"{"packages":[{"id":"clock","version":"1"}]}"#, to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.applyEdits([ConfigurationEdit(action: .package, properties: ["id": .string("clock"), "version": .string("2")])], persist: false)
    try store.uninstallPackage(id: "clock", version: "1")
    _ = try store.handle(RuntimeRequest(action: .reset))
    #expect(store.configurationError == nil)
    #expect(store.configuration?.widgets[0].content == .text("2"))
    #expect(try packages.list().map(\.version) == ["2"])
}

@Test @MainActor func uninstallKeepsFilesAndConfigurationWhenDisablingBreaksAReference() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    try writePackageFile(#"{"id":"sample","name":"Sample","version":"1","entry":"config.json"}"#,
                         to: source.appending(path: "package.json"))
    try writePackageFile(#"{"tokens":{"sampleHeight":48}}"#, to: source.appending(path: "config.json"))
    _ = try packages.install(source)
    let url = directory.appending(path: "config.json")
    let original = #"{"packages":[{"id":"sample","version":"1"}],"bar":{"height":"@token.sampleHeight"}}"#
    try writePackageFile(original, to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    for (id, version) in [("sample", "1"), ("sample", "missing"), ("../source", "1")] {
        #expect(throws: (any Error).self) { try store.uninstallPackage(id: id, version: version) }
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(try packages.list().map(\.version) == ["1"])
        #expect(store.configuration?.bar.height == 48)
    }
}

@Test @MainActor func uninstallRemovesTheVersionFromOtherBarsAndTheirWidgetOverrides() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    try writePackageFile(#"{"id":"clock","name":"Clock","version":"1","entry":"config.json"}"#, to: source.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[{"id":"clock","type":"text","position":"left","text":"Clock"}]}"#, to: source.appending(path: "config.json"))
    _ = try packages.install(source)
    let url = directory.appending(path: "config.json")
    try writePackageFile(#"{"widgets":[]}"#, to: url)
    let laptopBar = directory.appending(path: "setup-laptop.json")
    try writePackageFile(#"{"packages":[{"id":"clock","version":"1"}],"widgetOverrides":{"clock":{"enabled":false}}}"#, to: laptopBar)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.uninstallPackage(id: "clock", version: "1")
    var loader = ConfigurationLoader()
    let document = try loader.compose(laptopBar)
    #expect(try packages.list().isEmpty)
    #expect(document["widgetOverrides"] == nil)
    #expect(try document["packages"]?.decoded([WidgetPackageSelection].self).map(\.enabled) == [false])
    #expect(try loader.load(laptopBar).widgets.isEmpty)
}

@Test @MainActor func uninstallRemovesScreenThemesThatNameTheVersion() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    for version in ["1", "2"] {
        try writePackageFile(#"{"id":"sample","name":"Sample","version":"\#(version)","kind":"theme","entry":"config.json"}"#,
                             to: source.appending(path: "package.json"))
        try writePackageFile(#"{"bar":{"height":48}}"#, to: source.appending(path: "config.json"))
        _ = try packages.install(source)
    }
    let url = directory.appending(path: "config.json")
    try writePackageFile("""
    {"theme":{"id":"sample","version":"2"},"screens":{"monitor":{"theme":{"id":"sample","version":"1"}},"laptop":{"theme":{"id":"sample","version":"2"}}}}
    """, to: url)
    let verticalBar = directory.appending(path: "setup-vertical.json")
    try writePackageFile(#"{"screens":{"vertical":{"theme":{"id":"sample","version":"1"}}}}"#, to: verticalBar)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.uninstallPackage(id: "sample", version: "1")
    var loader = ConfigurationLoader()
    let screens = try #require(loader.compose(url)["screens"]).decoded([String: [String: ConfigurationValue]].self)
    #expect(screens.keys.sorted() == ["laptop"])
    #expect(try loader.compose(verticalBar)["screens"] == nil)
    _ = try loader.load(url)
    _ = try loader.load(verticalBar)
    #expect(try packages.list().map(\.version) == ["2"])
}

@Test func rootPackagePinsOverrideIncludedSelectionsWithoutDuplicatingProviders() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    for (id, version) in [("alpha", "1"), ("alpha", "2"), ("beta", "1")] {
        try writePackageFile("""
        {"id":"\(id)","name":"\(id)","version":"\(version)","entry":"config.json"}
        """, to: source.appending(path: "package.json"))
        try writePackageFile(#"""
        {"providers":{"\#(id)":{"type":"command","command":"printf '%s' \"$PACKAGE_DIR\"","interval":60}},
         "widgets":[{"id":"\#(id)","type":"provider","provider":"\#(id)","position":"right"}]}
        """#, to: source.appending(path: "config.json"))
        _ = try packages.install(source)
    }
    try writePackageFile(#"{"packages":[{"id":"alpha","version":"1"},{"id":"beta","version":"1"}]}"#,
                         to: directory.appending(path: "module.json"))
    let root = directory.appending(path: "config.json")
    var loader = ConfigurationLoader()
    let upgraded = try loader.load(root, data: Data(#"""
    {"includes":["module.json"],"packages":[{"id":"alpha","version":"2"}]}
    """#.utf8))
    #expect(upgraded.widgets.map(\.id) == ["alpha", "beta"])
    #expect(upgraded.providers["alpha"]?.environment["PACKAGE_DIR"] == directory.appending(path: "packages/alpha/2").path)
    #expect(upgraded.providers["beta"]?.environment["PACKAGE_DIR"] == directory.appending(path: "packages/beta/1").path)
    let disabled = try loader.load(root, data: Data(#"""
    {"includes":["module.json"],"packages":[{"id":"alpha","version":"2","enabled":false}]}
    """#.utf8))
    #expect(disabled.widgets.map(\.id) == ["beta"])
    #expect(disabled.providers["alpha"] == nil)
    #expect(!loader.dependencies.contains(directory.appending(path: "packages/alpha/1/config.json")))
    #expect(!loader.dependencies.contains(directory.appending(path: "packages/alpha/2/config.json")))
    try writePackageFile(#"{"packages":[{"id":"alpha","version":"2","enabled":false},{"id":"beta","version":"1"}]}"#,
                         to: directory.appending(path: "module.json"))
    let rollback = try loader.load(root, data: Data(#"""
    {"includes":["module.json"],"packages":[{"id":"alpha","version":"1","enabled":true}]}
    """#.utf8))
    #expect(rollback.widgets.map(\.id) == ["alpha", "beta"])
    #expect(rollback.providers["alpha"]?.environment["PACKAGE_DIR"] == directory.appending(path: "packages/alpha/1").path)
}

@Test func packageValidationRejectsTraversalEscapingSymlinksAndUnknownSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    let manifest = #"{"id":"clock","name":"Clock","version":"1","entry":"config.json"}"#
    try writePackageFile(manifest, to: source.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[]}"#, to: directory.appending(path: "outside.json"))
    for configuration in [#"{"includes":["../outside.json"]}"#,
                          #"{"widgets":[{"id":"image","type":"text","position":"left","text":"Image","layout":{"type":"image","path":"../outside.json"}}]}"#] {
        try writePackageFile(configuration, to: source.appending(path: "config.json"))
        #expect(throws: WidgetPackageError.self) { try store.install(source) }
    }
    try writePackageFile(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
    try FileManager.default.createSymbolicLink(at: source.appending(path: "escaped.json"), withDestinationURL: directory.appending(path: "outside.json"))
    #expect(throws: WidgetPackageError.self) { try store.inspect(source) }
    try FileManager.default.removeItem(at: source.appending(path: "escaped.json"))
    for id in ["../clock", ".", "", "/clock"] {
        #expect(throws: WidgetPackageError.self) { try store.directory(id: id, version: "1") }
    }
    for entry in ["../outside.json", "/tmp/outside.json", "missing.json"] {
        try writePackageFile(manifest.replacingOccurrences(of: "config.json", with: entry), to: source.appending(path: "package.json"))
        #expect(throws: WidgetPackageError.self) { try store.inspect(source) }
    }
    try writePackageFile(manifest, to: source.appending(path: "package.json"))
    let installed = try store.install(source)
    var loader = ConfigurationLoader()
    #expect(throws: WidgetPackageError.self) {
        try loader.load(directory.appending(path: "config.json"), data: Data(#"{"packages":[{"id":"clock","version":"1","settings":{"unknown":"x"}}]}"#.utf8))
    }
    #expect(FileManager.default.fileExists(atPath: installed.directory.path))
}

@Test func secretSettingsReachOnlyTheirPackageEnvironmentsAndComeFromTheLookup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    let manifest = #"{"id":"github","name":"GitHub","version":"1","entry":"config.json","settings":{"token":{"type":"secret"}}}"#
    try writePackageFile(manifest.replacingOccurrences(of: #""secret""#, with: #""secret","default":"x""#),
                         to: source.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
    #expect(throws: WidgetPackageError.self) { try store.inspect(source) }
    try writePackageFile(manifest, to: source.appending(path: "package.json"))
    for configuration in [#"{"widgets":[{"id":"a","type":"text","position":"left","text":"@setting.token"}]}"#,
                          #"{"tokens":{"token":"@setting.token"}}"#,
                          #"{"environment":{"T":"@setting.token"}}"#,
                          #"{"templates":{"a":{"type":"script","position":"left","command":"true","environment":{"T":"@setting.token"}}}}"#,
                          #"{"widgets":[{"id":"a","type":"script","position":"left","command":"true","environment":{"T":"@secret.other/token"}}]}"#] {
        try writePackageFile(configuration, to: source.appending(path: "config.json"))
        #expect(throws: WidgetPackageError.self) { try store.inspect(source) }
    }
    try writePackageFile(#"""
    {"widgets":[{"id":"github","type":"script","position":"right","command":"true","environment":{"GITHUB_TOKEN":"@setting.token"}}],
     "providers":{"github":{"type":"command","command":"true","environment":{"GITHUB_TOKEN":"@setting.token"}}}}
    """#, to: source.appending(path: "config.json"))
    _ = try store.install(source)
    var loader = ConfigurationLoader()
    let root = directory.appending(path: "config.json")
    #expect(throws: WidgetPackageError.self) {
        try loader.load(root, data: Data(#"{"packages":[{"id":"github","version":"1","settings":{"token":"x"}}]}"#.utf8))
    }
    let widget = try loader.load(root, data: Data(#"{"packages":[{"id":"github","version":"1"}]}"#.utf8)).widgets[0]
    #expect(widget.environment["GITHUB_TOKEN"] == "@secret.github/token")
    let environment = await ScriptEvent(sender: "control.changed", environment: ["VALUE": "@secret.github/token"])
        .commandEnvironment(widget.environment) { $0 == "github/token" ? "abc" : "" }
    #expect(environment["GITHUB_TOKEN"] == "abc")
    #expect(environment["VALUE"] == "@secret.github/token")
}

@Test func themePackagesContainOnlyStylesAndAreSelectedOnlyAsTheTheme() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let theme = directory.appending(path: "theme")
    let widget = directory.appending(path: "widget")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    try writePackageFile(#"{"id":"slate","name":"Slate","version":"1","kind":"theme","entry":"config.json"}"#,
                         to: theme.appending(path: "package.json"))
    for configuration in [#"{"widgets":[{"id":"clock","type":"clock","position":"left"}]}"#,
                          #"{"environment":{"PLAYER":"Music"}}"#,
                          #"{"providers":{"load":{"type":"command","command":"uptime"}}}"#,
                          #"{"templates":{"metric":{"type":"script","position":"left","command":"uptime"}}}"#,
                          #"{"profiles":[{"name":"dark","configuration":{"widgetOverrides":{"clock":{"onClick":"uptime"}}}}]}"#] {
        try writePackageFile(configuration, to: theme.appending(path: "config.json"))
        #expect(throws: WidgetPackageError.self) { try store.inspect(theme) }
    }
    try writePackageFile(##"""
    {"tokens":{"text":"#111111"},"defaults":{"foreground":"@token.text"},"bar":{"height":30},
     "groups":{"session":{"style":{"cornerRadius":4}}},
     "profiles":[{"name":"dark","when":{"appearance":"dark"},"configuration":{"tokens":{"text":"#eeeeee"}}}]}
    """##, to: theme.appending(path: "config.json"))
    #expect(try store.install(theme).commands.isEmpty)
    try writePackageFile(#"{"id":"clock","name":"Clock","version":"1","entry":"config.json"}"#, to: widget.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[{"id":"clock","type":"clock","position":"left"}]}"#, to: widget.appending(path: "config.json"))
    _ = try store.install(widget)
    var loader = ConfigurationLoader()
    for json in [#"{"theme":{"id":"clock","version":"1"}}"#, #"{"packages":[{"id":"slate","version":"1"}]}"#] {
        #expect(throws: WidgetPackageError.self) { try loader.load(directory.appending(path: "config.json"), data: Data(json.utf8)) }
    }
}

@Test func widgetsPackagesRejectCommandsAtAnyDepthAndLoadThroughPackages() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    try writePackageFile(#"{"id":"monitor","name":"Monitor","version":"1","kind":"widgets","entry":"config.json"}"#,
                         to: source.appending(path: "package.json"))
    for (configuration, message) in [
        (#"{"environment":{"PLAYER":"Music"}}"#, "A widgets package can contain only tokens, defaults, bar, groups, profiles, widgets, templates, popups and providers, not environment."),
        (#"{"widgetOverrides":{"cpu":{"text":"CPU"}}}"#, "A widgets package can contain only tokens, defaults, bar, groups, profiles, widgets, templates, popups and providers, not widgetOverrides."),
        (#"{"widgets":[{"id":"load","type":"script","position":"left","command":"uptime"}]}"#, "A widgets package cannot contain command."),
        (#"{"providers":{"load":{"type":"stream","command":"uptime"}}}"#, "A widgets package cannot contain command."),
        (#"{"templates":{"cpu":{"type":"system","position":"left","actions":{"scrollUp":"uptime"}}}}"#, "A widgets package cannot contain scrollUp."),
        (#"{"popups":{"agenda":{"style":{},"layout":{"type":"text","text":"Join","onClickField":"joinCommand"}}}}"#, "A widgets package cannot contain onClickField."),
        (#"{"popups":{"ask":{"style":{},"layout":{"type":"input","title":"Ask","onSubmit":"uptime"}}}}"#, "A widgets package cannot contain onSubmit."),
        (#"{"widgets":[{"id":"cpu","type":"system","position":"left","environment":{"A":"B"}}]}"#, "A widgets package cannot contain environment."),
        (#"{"profiles":[{"name":"dark","configuration":{"workspaceSource":"yabai"}}]}"#, "A widgets package can contain only tokens, defaults, bar, groups, profiles, widgets, templates, popups and providers, not workspaceSource."),
        (#"{"profiles":[{"name":"dark","configuration":{"widgets":[{"id":"cpu","type":"system","position":"left","onClick":"uptime"}]}}]}"#, "A widgets package cannot contain onClick.")
    ] {
        try writePackageFile(configuration, to: source.appending(path: "config.json"))
        let error = #expect(throws: WidgetPackageError.self) { try store.inspect(source) }
        #expect(error?.localizedDescription == message)
    }
    try writePackageFile(#"""
    {"tokens":{"surface":"#222222"},
     "providers":{"system":{"type":"system","interval":2},"power":{"type":"battery"},"status":{"type":"merge","providers":["system","power"]}},
     "popups":{"usage":{"style":{},"layout":{"type":"field","field":"text","open":"com.apple.ActivityMonitor"}},
               "controls":{"style":{},"layout":{"type":"column","children":[
                 {"type":"slider","title":"Volume","source":"volume","set":"volume"},
                 {"type":"toggle","title":"Wi-Fi","source":"power","set":"wifiPower"}]}}},
     "widgets":[{"id":"cpu","type":"system","position":"right","popupName":"usage","style":{"background":"@token.surface"}},
                {"id":"status","type":"provider","provider":"status","position":"right","popupName":"controls"}]}
    """#, to: source.appending(path: "config.json"))
    #expect(try store.install(source).commands.isEmpty)
    var loader = ConfigurationLoader()
    let root = directory.appending(path: "config.json")
    let configuration = try loader.load(root, data: Data(#"{"packages":[{"id":"monitor","version":"1"}]}"#.utf8))
    #expect(configuration.widgets.map(\.id) == ["cpu", "status"])
    #expect(configuration.activeProviders == ["system", "power", "status"])
    #expect(throws: WidgetPackageError.self) { try loader.load(root, data: Data(#"{"theme":{"id":"monitor","version":"1"}}"#.utf8)) }
    guard case let .column(controls) = configuration.popups["controls"]?.layout.content,
          case .slider(_, _, _, _, _, _, .set(.volume)) = controls[0].content, case .toggle(_, _, .set(.wifiPower)) = controls[1].content else {
        Issue.record("Expected a slider that sets the volume and a toggle that turns Wi-Fi on or off")
        return
    }
}

@Test func manifestsDeclareWhatAPackageNeedsAndKeepTheirScreenshotInside() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    let manifest = #"""
    {"id":"weather","name":"Weather","version":"1","entry":"config.json","description":"Current conditions.","author":"StableBar",
     "repository":"https://github.com/Seb-GRAF/stablebar-packages","screenshot":"screenshot.png","minimumVersion":"0.6.0",
     "requires":["jq","gh","brew"],"permissions":["location"],"hosts":["wttr.in"]}
    """#
    try writePackageFile(manifest, to: source.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
    try writePackageFile("image", to: source.appending(path: "screenshot.png"))
    try writePackageFile("image", to: directory.appending(path: "outside.png"))
    let inspection = try store.inspect(source)
    #expect(inspection.manifest.description == "Current conditions.")
    #expect(inspection.manifest.author == "StableBar")
    #expect(inspection.manifest.repository == URL(string: "https://github.com/Seb-GRAF/stablebar-packages"))
    #expect(inspection.manifest.minimumVersion == "0.6.0")
    #expect(inspection.manifest.permissions == [.location])
    #expect(inspection.manifest.hosts == ["wttr.in"])
    #expect(inspection.screenshot?.path == source.appending(path: "screenshot.png").path)
    let tools = directory.appending(path: "bin")
    try writePackageFile("#!/bin/sh\n", to: tools.appending(path: "jq"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: "jq").path)
    try writePackageFile("", to: tools.appending(path: "gh"))
    #expect(inspection.manifest.missingTools(path: "/missing:\(tools.path)") == ["gh", "brew"])
    for (value, replacement) in [("screenshot.png", "../outside.png"), (#"["location"]"#, #"["camera"]"#), ("https://github.com", "http://github.com")] {
        try writePackageFile(manifest.replacingOccurrences(of: value, with: replacement), to: source.appending(path: "package.json"))
        #expect(throws: (any Error).self) { try store.inspect(source) }
    }
}

@Test func packageSettingChoicesValidateDefaultsAndSavedValues() throws {
    let manifest = #"{"id":"weather","name":"Weather","version":"1","entry":"config.json","settings":{"units":{"type":"string","title":"Units","description":"Choose how temperature is shown.","choices":["metric","imperial"],"default":"metric"}}}"#
    let decoder = JSONDecoder()
    let package = try decoder.decode(WidgetPackageManifest.self, from: Data(manifest.utf8))
    #expect(try package.values(["units": .string("imperial")])["units"] == .string("imperial"))
    #expect(throws: WidgetPackageError.self) { try package.values(["units": .string("unknown")]) }
    for invalid in [
        manifest.replacingOccurrences(of: #""default":"metric""#, with: #""default":"unknown""#),
        manifest.replacingOccurrences(of: #"["metric","imperial"]"#, with: "[]"),
        manifest.replacingOccurrences(of: #""type":"string""#, with: #""type":"number""#)
    ] {
        #expect(throws: (any Error).self) { try decoder.decode(WidgetPackageManifest.self, from: Data(invalid.utf8)) }
    }
}

@Test func packageSettingsKeepTheManifestsOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Keys inside a setting, in other objects and in strings are not settings.
    try writePackageFile(#"""
    {"id": "weather", "name": "Weather \"settings\": {", "version": "1", "entry": "config.json", "requires": ["jq"],
     "settings": {
       "zone": {"type": "string", "description": "A \"key\": value [{", "default": "UTC"},
       "units": {"type": "string", "choices": ["metric", "imperial"], "default": "metric"},
       "\u0061rea": {"type": "number", "default": 2}
     },
     "permissions": ["location"]}
    """#, to: directory.appending(path: "package.json"))
    #expect(try WidgetPackageStore(directory: directory).manifest(at: directory).settingNames == ["zone", "units", "area"])
    // A repeated key or settings object keeps its first value, as JSONDecoder does, and names each setting once.
    try writePackageFile(#"""
    {"id":"weather","name":"Weather","version":"1","entry":"config.json",
     "settings":{"zone":{"type":"string","default":"UTC"},"units":{"type":"number","default":1},"zone":{"type":"bool","default":true}},
     "settings":{"extra":{"type":"bool","default":true}}}
    """#, to: directory.appending(path: "package.json"))
    #expect(try WidgetPackageStore(directory: directory).manifest(at: directory).settingNames == ["zone", "units"])
    // A manifest in UTF-16 lists its settings in key order; a 0x22 byte in it, as in Ģ, is no quote.
    let utf16 = #"{"id":"weather","name":"Ģ","version":"1","entry":"config.json","settings":{"zone":{"type":"string","default":"UTC"},"#
        + #""area":{"type":"number","default":2}}}"#
    try utf16.data(using: .utf16LittleEndian)!.write(to: directory.appending(path: "package.json"))
    #expect(try WidgetPackageStore(directory: directory).manifest(at: directory).settingNames == ["area", "zone"])
}

@Test func packagesThatNeedANewerStableBarFailReviewAndInstall() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"), appVersion: "0.9.0")
    try writePackageFile(#"{"id":"clock","name":"Clock","version":"1","entry":"config.json","minimumVersion":"0.10.0"}"#,
                         to: source.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
    let error = #expect(throws: WidgetPackageError.self) { try store.inspect(source) }
    #expect(error?.localizedDescription == "Package clock needs StableBar 0.10.0 or later.")
    #expect(throws: WidgetPackageError.self) { try store.install(source) }
    _ = try WidgetPackageStore(directory: store.directory, appVersion: nil).inspect(source)
    for version in ["0.9.0", "0.8.12"] {
        try writePackageFile(#"{"id":"clock","name":"Clock","version":"1","entry":"config.json","minimumVersion":"\#(version)"}"#,
                             to: source.appending(path: "package.json"))
        _ = try store.inspect(source)
    }
    _ = try store.install(source)
}

@Test func storePackagesInstallFromTheIndexOnlyWhenTheirArchiveMatches() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    try writePackageFile(#"{"id":"clock","name":"Clock","version":"1","kind":"widgets","entry":"config.json"}"#,
                         to: source.appending(path: "package.json"))
    try writePackageFile(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#, to: source.appending(path: "config.json"))
    let archive = directory.appending(path: "store/clock-1.tar.gz")
    try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try await runCommand("/usr/bin/tar", arguments: ["-czf", archive.path, "-C", source.path, "."])
    let sha256 = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
    let index = directory.appending(path: "store/index.json")
    let indexSource = PackageSource(id: PackageSource.storeID, name: "StableBar Store", url: index)
    for (version, checksum, message) in [
        ("1", String(repeating: "0", count: 64), "The archive of package clock does not match the store's checksum."),
        ("2", sha256, "The archive of package clock 2 contains a different id or version.")
    ] {
        try writePackageFile(#"""
        {"packages":[{"id":"clock","name":"Clock","version":"\#(version)","archive":"clock-1.tar.gz","sha256":"\#(checksum)",
          "source":"https://example.com/packages/clock"}]}
        """#, to: index)
        let entry = try await PackageIndex.load(from: index).packages[0]
        let error = await #expect(throws: WidgetPackageError.self) { try await store.download(entry, from: indexSource, token: nil) }
        #expect(error?.localizedDescription == message)
    }
    try writePackageFile(#"""
    {"packages":[{"id":"agent","name":"Agent","version":"1","kind":"plugin","archive":"agent-1.tar.gz","sha256":"\#(sha256)"},
      {"id":"clock","name":"Clock","version":"1","kind":"widgets","archive":"clock-1.tar.gz","sha256":"\#(sha256)",
      "source":"https://example.com/packages/clock","rating":5}],"updated":"2026-10-16"}
    """#, to: index)
    let packages = try await PackageIndex.load(from: index).packages
    #expect(packages.map(\.id) == ["clock"])
    let installed = try store.install(try await store.download(packages[0], from: indexSource, token: nil))
    #expect(installed.directory == directory.appending(path: "packages/clock/1"))
    #expect(installed.manifest.kind == .widgets)
}

@Test func updatesListTheCommandsHostsAndPermissionsTheyAdd() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    var inspections: [WidgetPackageInspection] = []
    for (version, actions, hosts, permissions) in [("1", "{}", #""a.example""#, #""calendars""#),
                                                    ("2", #"{"scrollUp":"echo two"}"#, #""a.example","b.example""#, #""calendars","location""#)] {
        try writePackageFile(#"{"id":"feed","name":"Feed","version":"\#(version)","entry":"config.json","hosts":[\#(hosts)],"permissions":[\#(permissions)]}"#,
                             to: source.appending(path: "package.json"))
        try writePackageFile(#"{"widgets":[{"id":"feed","type":"text","position":"left","text":"Feed","onClick":"echo one","actions":\#(actions)}]}"#,
                             to: source.appending(path: "config.json"))
        inspections.append(try store.install(source))
    }
    #expect(inspections[1].additions(since: inspections[0]) == ["Command: echo two", "Host: b.example", "Permission: Location"])
    #expect(inspections[0].additions(since: inspections[1]).isEmpty)
}

@Test func themeAppliesAfterWidgetPackagesAndBeforeIncludesAndTheRootFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let theme = directory.appending(path: "theme")
    let widget = directory.appending(path: "widget")
    let store = WidgetPackageStore(directory: directory.appending(path: "packages"))
    try writePackageFile(#"{"id":"slate","name":"Slate","version":"1","kind":"theme","entry":"config.json"}"#,
                         to: theme.appending(path: "package.json"))
    try writePackageFile(##"""
    {"tokens":{"text":"#111111","textMuted":"#222222","surface":"#444444"},
     "defaults":{"foreground":"@token.text","background":"@token.surface","fontSize":10},
     "bar":{"height":30},
     "profiles":[{"name":"dark","when":{"appearance":"dark"},"configuration":{"tokens":{"text":"#eeeeee"}}}]}
    """##, to: theme.appending(path: "config.json"))
    _ = try store.install(theme)
    try writePackageFile(#"{"id":"status","name":"Status","version":"1","entry":"config.json"}"#, to: widget.appending(path: "package.json"))
    try writePackageFile(##"""
    {"tokens":{"textMuted":"#555555","badge":"#888888","surface":"#777777"},
     "widgets":[{"id":"status","type":"text","position":"left","text":"Ready",
                 "style":{"foreground":"@token.textMuted","background":"@token.badge"}}],
     "profiles":[{"name":"package","when":{"onBattery":true},"configuration":{"bar":{"height":31}}}]}
    """##, to: widget.appending(path: "config.json"))
    _ = try store.install(widget)
    try writePackageFile(##"{"tokens":{"surface":"#666666"},"profiles":[{"name":"dark","configuration":{"bar":{"spacing":9}}}]}"##, to: directory.appending(path: "module.json"))
    let root = directory.appending(path: "config.json")
    let json = ##"""
    {"includes":["module.json"],"theme":{"id":"slate","version":"1"},"packages":[{"id":"status","version":"1"}],
     "defaults":{"fontSize":13},"profiles":[{"name":"root","when":{"onBattery":true},"configuration":{"bar":{"height":33}}}],
     "widgets":[{"id":"note","type":"text","position":"right","text":"Note","style":{"foreground":"@token.textMuted"}}]}
    """##
    var loader = ConfigurationLoader()
    let light = try loader.load(root, data: Data(json.utf8))
    #expect(light.defaults.foreground == HexColor(0x111111ff))
    #expect(light.widgets[0].style.foreground == HexColor(0x222222ff))
    #expect(light.widgets[0].style.background == .color(HexColor(0x888888ff)))
    #expect(light.defaults.background == .color(HexColor(0x666666ff)))
    #expect(light.defaults.fontSize == 13)
    #expect(light.bar.height == 30)
    #expect(light.widgets.map(\.id) == ["status", "note"])
    #expect(light.widgets[1].style.foreground == HexColor(0x222222ff))
    let dark = try loader.load(root, data: Data(json.utf8), context: ConfigurationContext(appearance: "dark"))
    #expect(dark.defaults.foreground == HexColor(0xeeeeeeff))
    #expect(loader.activeProfiles == ["dark"])
    #expect(loader.profiles.map(\.name) == ["package", "dark", "root"])
    #expect(dark.bar.spacing == 9)
    let battery = try loader.load(root, data: Data(json.utf8), context: ConfigurationContext(onBattery: true))
    #expect(loader.activeProfiles == ["package", "root"])
    #expect(battery.bar.height == 33)
    let builtIn = try loader.load(root, data: Data(#"{"widgets":[]}"#.utf8))
    #expect(builtIn.defaults.foreground == nil)
    #expect(builtIn.bar.height == 40)
}

private let bundledThemes = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Resources/themes")

@Test func colorsTakeOneValueOrALightAndDarkPair() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "colors.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(##"""
    {"tokens":{"text":{"light":"#111111","dark":"#eeeeee"},"line":"#333333"},
     "defaults":{"foreground":"@token.text","background":"#22222280","borderColor":{"light":"@token.line","dark":"#444444"}},
     "widgets":[]}
    """##.utf8))
    #expect(configuration.defaults.foreground == HexColor(light: 0x111111ff, dark: 0xeeeeeeff))
    #expect(configuration.defaults.background == .color(HexColor(0x22222280)))
    #expect(configuration.defaults.borderColor == HexColor(light: 0x333333ff, dark: 0x444444ff))
    for (color, message) in [
        (##"{"light":"#111111"}"##, "defaults.foreground: Missing property dark."),
        (##"{"light":"#111111","dark":"#222222","tint":"#333333"}"##, "defaults.foreground.tint: Unknown property."),
        (##"{"light":"blue","dark":"#222222"}"##, "defaults.foreground: Use #RRGGBB or #RRGGBBAA for colors.")
    ] {
        let error = #expect(throws: (any Error).self) {
            try loader.load(url, data: Data(#"{"widgets":[],"defaults":{"foreground":\#(color)}}"#.utf8))
        }
        #expect(error.map(errorMessage) == message)
    }
}

@Test func backgroundsTakeAGradientOfColors() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "gradients.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(##"""
    {"tokens":{"accent":{"light":"#111111","dark":"#eeeeee"},"line":"#333333","sunset":{"gradient":{"colors":["#ff0000","#0000ff"]}}},
     "defaults":{"background":{"gradient":{"colors":["@token.accent","#eb6f92"],"angle":120,"locations":[0,0.6]}},
                 "hoverBackground":"@token.sunset"},
     "bar":{"background":{"gradient":{"colors":["#000000",{"light":"@token.line","dark":"#222222"},"#ffffff"]}}},
     "widgets":[]}
    """##.utf8))
    #expect(configuration.defaults.background == .gradient(BackgroundGradient(
        colors: [HexColor(light: 0x111111ff, dark: 0xeeeeeeff), HexColor(0xeb6f92ff)], angle: 120, locations: [0, 0.6])))
    #expect(configuration.defaults.hoverBackground == .gradient(BackgroundGradient(colors: [HexColor(0xff0000ff), HexColor(0x0000ffff)])))
    #expect(configuration.bar.background == .gradient(BackgroundGradient(
        colors: [HexColor(0x000000ff), HexColor(light: 0x333333ff, dark: 0x222222ff), HexColor(0xffffffff)])))
    let locations = "defaults.background.gradient.locations: Give one location per color, from 0 to 1 in ascending order."
    for (key, background, message) in [
        ("background", ##"{"gradient":{"colors":["#111111"]}}"##, "defaults.background.gradient.colors: A gradient needs two or more colors."),
        ("background", ##"{"gradient":{"colors":["#111111","blue"]}}"##, "defaults.background.gradient.colors.1: Use #RRGGBB or #RRGGBBAA for colors."),
        ("background", ##"{"gradient":{"colors":["#111111","#222222"],"spread":"pad"}}"##, "defaults.background.gradient.spread: Unknown property."),
        ("background", ##"{"gradient":{"colors":["#111111","#222222"]},"light":"#111111"}"##, "defaults.background.light: Unknown property."),
        ("background", ##"{"gradient":{"colors":["#111111","#222222"],"locations":[0]}}"##, locations),
        ("background", ##"{"gradient":{"colors":["#111111","#222222"],"locations":[0,1.5]}}"##, locations),
        ("background", ##"{"gradient":{"colors":["#111111","#222222"],"locations":[0.6,0.2]}}"##, locations),
        ("foreground", ##"{"gradient":{"colors":["#111111","#222222"]}}"##, "defaults.foreground.gradient: Unknown property.")
    ] {
        let error = #expect(throws: (any Error).self) {
            try loader.load(url, data: Data(#"{"widgets":[],"defaults":{"\#(key)":\#(background)}}"#.utf8))
        }
        #expect(error.map(errorMessage) == message, "\(background)")
    }
    for (angle, normalized) in [(-90.0, 270.0), (450, 90), (720, 0)] {
        let fill = try JSONDecoder().decode(BackgroundFill.self, from: Data(##"{"gradient":{"colors":["#111111","#222222"],"angle":\##(angle)}}"##.utf8))
        #expect(fill == .gradient(BackgroundGradient(colors: [HexColor(0x111111ff), HexColor(0x222222ff)], angle: normalized)))
    }
}

@Test func aGradientReplacesTheBackgroundItOverridesInsteadOfMergingWithIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let two = ##"{"gradient":{"colors":["#111111","#222222"]}}"##
    let three = ##"{"gradient":{"colors":["#111111","#222222","#333333"],"angle":180,"locations":[0,0.2,1]}}"##
    let pair = ##"{"light":"#444444","dark":"#555555"}"##
    let twoColors = BackgroundFill.gradient(BackgroundGradient(colors: [HexColor(0x111111ff), HexColor(0x222222ff)]))
    var loader = ConfigurationLoader()
    for (theme, own, background) in [(pair, two, twoColors), (two, pair, .color(HexColor(light: 0x444444ff, dark: 0x555555ff))),
                                     (three, two, twoColors)] {
        try Data(##"{"tokens":{"surface":"#666666"},"defaults":{"background":\##(theme)}}"##.utf8)
            .write(to: directory.appending(path: "theme.json"))
        let configuration = try loader.load(directory.appending(path: "config.json"), data: Data(##"""
        {"includes":["theme.json"],"tokens":{"gradient":\##(two)},"defaults":{"background":\##(own),"hoverBackground":"@token.gradient"},
         "bar":{"background":"@token.surface"},"widgets":[]}
        """##.utf8))
        #expect(configuration.defaults.background == background, "\(own) over \(theme)")
        #expect(configuration.bar.background == .color(HexColor(0x666666ff)))
    }
}

@Test func builtInThemeLoadsUnderEveryThemeAndReplacesPackageFallbacks() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let widget = directory.appending(path: "widget")
    try writePackageFile(#"{"id":"status","name":"Status","version":"1","entry":"config.json"}"#, to: widget.appending(path: "package.json"))
    try writePackageFile(##"""
    {"tokens":{"textMuted":"#555555","badge":"#888888"},
     "widgets":[{"id":"status","type":"text","position":"left","text":"Ready",
                 "style":{"foreground":"@token.textMuted","background":"@token.badge"}}]}
    """##, to: widget.appending(path: "config.json"))
    _ = try WidgetPackageStore(directory: directory.appending(path: "packages")).install(widget)
    let root = directory.appending(path: "config.json")
    let widgets = #""packages":[{"id":"status","version":"1"}],"widgets":[{"id":"note","type":"text","position":"right","text":"Note","style":{"foreground":"@token.textMuted"}}]"#
    var loader = ConfigurationLoader()
    loader.themesDirectory = bundledThemes
    let builtIn = try loader.load(root, data: Data("{\(widgets)}".utf8))
    let textMuted = HexColor(light: 0x6e6e73ff, dark: 0xa1a1a6ff)
    #expect(builtIn.defaults.foreground == HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
    #expect(builtIn.defaults.background == .color(HexColor(light: 0xf8f8faed, dark: 0x242629ee)))
    #expect(builtIn.widgets[0].style.foreground == textMuted)
    #expect(builtIn.widgets[0].style.background == .color(HexColor(0x888888ff)))
    #expect(builtIn.widgets[1].style.foreground == textMuted)
    let rosePine = try loader.load(root, data: Data(#"{"theme":{"id":"rose-pine"},\#(widgets)}"#.utf8))
    #expect(rosePine.defaults.foreground == HexColor(light: 0x575279ff, dark: 0xe0def4ff))
    #expect(rosePine.defaults.cornerRadius == 13)
    #expect(rosePine.defaults.shadowColor == HexColor(light: 0x5752791f, dark: 0x00000066))
    #expect(rosePine.widgets[1].style.foreground == HexColor(light: 0x716d8cff, dark: 0x908caaff))
    let ownText = Data(##"{"theme":{"id":"rose-pine"},"tokens":{"text":"#c2410c"},"widgets":[]}"##.utf8)
    for appearance in ["light", "dark"] {
        #expect(try loader.load(root, data: ownText, context: ConfigurationContext(appearance: appearance)).defaults.foreground == HexColor(0xc2410cff))
    }
    for json in [#"{"theme":{"id":"missing"},"widgets":[]}"#, #"{"packages":[{"id":"status"}],"widgets":[]}"#] {
        #expect(throws: WidgetPackageError.self) { try loader.load(root, data: Data(json.utf8)) }
    }
    loader.themesDirectory = nil
    #expect(throws: WidgetPackageError.self) { try loader.load(root, data: Data(#"{"theme":{"id":"rose-pine"},"widgets":[]}"#.utf8)) }
}

@Test func bundledThemesDefineEverySharedTokenForLightAndDark() throws {
    let store = WidgetPackageStore(directory: bundledThemes)
    let url = FileManager.default.temporaryDirectory.appending(path: "bundled.json")
    var loader = ConfigurationLoader()
    loader.themesDirectory = bundledThemes
    for directory in try FileManager.default.contentsOfDirectory(at: bundledThemes, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
        let manifest = try store.manifest(at: directory)
        #expect(manifest.kind == .theme)
        #expect(manifest.id == directory.lastPathComponent)
        #expect(try store.inspect(directory).commands.isEmpty)
        _ = try loader.load(url, data: Data(#"{"theme":{"id":"\#(manifest.id)"},"widgets":[]}"#.utf8))
        let tokens = try loader.document["tokens"]!.decoded([String: ConfigurationValue].self)
        for name in ["surface", "surfaceRaised", "text", "textMuted", "accent", "track", "hairline", "warning", "critical"] {
            let color = try #require(try tokens[name]?.decoded(HexColor.self), "\(manifest.id).\(name)")
            #expect((color.light == color.dark) == (manifest.id == "notch"), "\(manifest.id).\(name)")
        }
    }
}

@Test func barAppearanceDecidesWhichAppearanceProfilesApply() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "appearance.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(#"""
    {"bar":{"appearance":"dark"},"widgets":[],
     "profiles":[{"name":"night","when":{"appearance":"dark"},"configuration":{"bar":{"height":30}}}]}
    """#.utf8), context: ConfigurationContext(appearance: "light"))
    #expect(configuration.bar.appearance == .dark)
    #expect(configuration.bar.height == 30)
    #expect(loader.activeProfiles == ["night"])
    _ = try loader.load(url, data: Data(#"""
    {"tokens":{"mode":"dark"},"bar":{"appearance":"@token.mode"},"widgets":[],
     "profiles":[{"name":"night","when":{"appearance":"dark"},"configuration":{"bar":{"height":30}}}]}
    """#.utf8), context: ConfigurationContext(appearance: "light"))
    #expect(loader.activeProfiles == ["night"])
    let error = #expect(throws: (any Error).self) {
        try loader.load(url, data: Data(#"{"bar":{"appearance":"auto"},"widgets":[]}"#.utf8))
    }
    #expect(error.map(errorMessage) == "bar.appearance: Cannot initialize BarAppearance from invalid String value auto")
}

@Test @MainActor func colorsThatSetupAndTheStarterWroteNoLongerHideATheme() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let dark = ##""foreground":"#f5f5f7ff","background":"#242629ee","hoverBackground":"#36383cff","borderColor":"#ffffff1f","shadowColor":"#00000040""##
    let light = ##""foreground":"#1d1d1fff","background":"#f8f8faed","hoverBackground":"#ffffffff","borderColor":"#ffffffb3","shadowColor":"#00000014""##
    let automatic = #""foreground":null,"background":null,"hoverBackground":null,"borderColor":null,"shadowColor":null"#
    let changedAfterAutomatic = ##""foreground":"#ff8800ff","background":null,"hoverBackground":null,"borderColor":null,"shadowColor":null"##
    for (defaults, bar, migrated) in [
        ("{\(dark),\"accent\":\"#007aff\",\"fontSize\":13}", ConfigurationValue.object(["height": .number(40), "appearance": .string("dark")]),
         ConfigurationValue.object(["fontSize": .number(13)])),
        ("{\(light)}", .object(["height": .number(40), "appearance": .string("light")]), nil),
        ("{\(automatic),\"accent\":\"#007aff\"}", .object(["height": .number(40)]), nil),
        ("{\(changedAfterAutomatic)}", .object(["height": .number(40)]), .object(["foreground": .string("#ff8800ff")]))
    ] {
        try writePackageFile(#"{"theme":{"id":"rose-pine"},"bar":{"height":40},"defaults":\#(defaults),"widgets":[]}"#, to: root)
        try migrateEarlierColors(root)
        let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
        #expect(saved["bar"] == bar)
        #expect(saved["defaults"] == migrated)
        var loader = ConfigurationLoader()
        loader.themesDirectory = bundledThemes
        let configuration = try loader.load(root)
        #expect(configuration.defaults.background == .color(HexColor(light: 0xfaf4edee, dark: 0x191724ee)))
        #expect(configuration.defaults.accent == HexColor(light: 0x8a72a4ff, dark: 0xc4a7e7ff))
    }
    let handSet = ##"{"bar":{"height":40},"defaults":{"foreground":"#abcdefff","background":"#242629ee","hoverBackground":"#36383cff","borderColor":"#ffffff1f","shadowColor":"#00000040","accent":"#ff8800"},"widgets":[]}"##
    try writePackageFile(handSet, to: root)
    try migrateEarlierColors(root)
    #expect(try String(contentsOf: root, encoding: .utf8) == handSet)
    let pinned = "{\"$schema\":\"\(ConfigurationSchema.url(release: "0.9.0"))\",\"defaults\":{\(automatic),\"accent\":\"#007aff\"},\"widgets\":[]}"
    try writePackageFile(pinned, to: root)
    try migrateEarlierColors(root)
    #expect(try String(contentsOf: root, encoding: .utf8) == pinned)
    try writePackageFile(##"{"customization":{"defaults":{\##(dark),"accent":"#007aff"}},"widgets":[]}"##, to: root)
    let store = BarStore(configurationURL: root, release: "0.10.0")
    defer { store.stop() }
    store.start()
    #expect(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
        == ["$schema": .string(ConfigurationSchema.url(release: "0.10.0")), "bar": .object(["appearance": .string("dark")]), "widgets": .array([])])
}

@Test func statesMergeThroughModulesTemplatesTokensProfilesOverridesAndPackages() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    try writePackageFile(#"{"id":"meter","name":"Meter","version":"1","entry":"config.json"}"#, to: source.appending(path: "package.json"))
    try writePackageFile(##"""
    {"widgets":[{"id":"meter","type":"text","text":"Meter","position":"right","style":{"states":{"warning":{"foreground":"#111111"}}}}]}
    """##, to: source.appending(path: "config.json"))
    _ = try WidgetPackageStore(directory: directory.appending(path: "bar/packages")).install(source)
    try writePackageFile(##"""
    {"tokens":{"alert":"#222222"},
     "defaults":{"states":{"warning":{"foreground":"@token.alert"},"hover":{"background":"#444444"}}},
     "templates":{"label":{"type":"text","position":"left","style":{"states":{"hover":{"foreground":"#555555"}}}}}}
    """##, to: directory.appending(path: "bar/theme.json"))
    var loader = ConfigurationLoader()
    let configuration = try loader.load(directory.appending(path: "bar/config.json"), data: Data(##"""
    {"includes":["theme.json"],"packages":[{"id":"meter","version":"1"}],
     "widgets":[{"id":"label","template":"label","text":"Label"}],
     "profiles":[{"name":"dark","when":{"appearance":"dark"},"configuration":{"defaults":{"states":{"warning":{"background":"#666666"}}}}}],
     "widgetOverrides":{"label":{"style":{"states":{"hover":{"background":"#777777"}}}},
                        "meter":{"style":{"states":{"warning":{"background":"#888888"}}}}}}
    """##.utf8), context: ConfigurationContext(appearance: "dark"))
    #expect(configuration.defaults.states?["warning"] == WidgetStyle(foreground: HexColor(0x222222ff), background: .color(HexColor(0x666666ff))))
    #expect(configuration.defaults.states?["hover"]?.background == .color(HexColor(0x444444ff)))
    let label = try #require(configuration.widgets.first { $0.id == "label" })
    #expect(label.style.states?["hover"] == WidgetStyle(foreground: HexColor(0x555555ff), background: .color(HexColor(0x777777ff))))
    let meter = try #require(configuration.widgets.first { $0.id == "meter" })
    #expect(meter.style.states?["warning"] == WidgetStyle(foreground: HexColor(0x111111ff), background: .color(HexColor(0x888888ff))))
}

@Test func aLaterLayerRemovesAnInheritedStateWithNull() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source")
    try writePackageFile(#"{"id":"meter","name":"Meter","version":"1","entry":"config.json"}"#, to: source.appending(path: "package.json"))
    try writePackageFile(##"""
    {"defaults":{"states":{"empty":{"foreground":"#555555"}}},
     "widgets":[{"id":"meter","type":"text","text":"M","position":"right",
                 "style":{"states":{"warning":{"foreground":"#666666"},"hover":{"foreground":"#777777"}}}}]}
    """##, to: source.appending(path: "config.json"))
    _ = try WidgetPackageStore(directory: directory.appending(path: "packages")).install(source)
    try writePackageFile(##"{"defaults":{"states":{"focused":{"foreground":"#999999"}}}}"##, to: directory.appending(path: "theme.json"))
    var loader = ConfigurationLoader()
    let configuration = try loader.load(directory.appending(path: "config.json"), data: Data(##"""
    {"includes":["theme.json"],"packages":[{"id":"meter","version":"1"}],
     "defaults":{"states":{"hover":{"background":"#111111"},"warning":{"foreground":"#222222"},"focused":null,"empty":null}},
     "templates":{"label":{"type":"text","position":"left","style":{"states":{"hover":{"foreground":"#333333"},"warning":{"foreground":"#444444"}}}}},
     "widgets":[{"id":"a","template":"label","text":"A"},
                {"id":"b","template":"label","text":"B","style":{"states":{"warning":null}}}],
     "profiles":[{"name":"plain","configuration":{"defaults":{"states":{"hover":null}}}}],
     "widgetOverrides":{"a":{"style":{"states":{"hover":null}}},"meter":{"style":{"states":{"warning":null}}}}}
    """##.utf8))
    #expect(configuration.defaults.states == ["warning": WidgetStyle(foreground: HexColor(0x222222ff))])
    func states(_ id: String) throws -> [String: WidgetStyle]? {
        try #require(configuration.widgets.first { $0.id == id }).style.states
    }
    #expect(try states("a") == ["warning": WidgetStyle(foreground: HexColor(0x444444ff))])
    #expect(try states("b") == ["hover": WidgetStyle(foreground: HexColor(0x333333ff))])
    #expect(try states("meter") == ["hover": WidgetStyle(foreground: HexColor(0x777777ff))])
}

@Test func themeStatesTakeLightAndDarkColorsAndMergeUnderLaterLayers() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let theme = directory.appending(path: "theme")
    try writePackageFile(#"{"id":"night","name":"Night","version":"1","kind":"theme","entry":"config.json"}"#,
                         to: theme.appending(path: "package.json"))
    try writePackageFile(##"""
    {"tokens":{"warning":{"light":"#aa0000","dark":"#ff4444"}},
     "defaults":{"states":{"warning":{"foreground":"@token.warning","background":{"light":"#111111","dark":"#222222"}},
                           "muted":{"opacity":0.5},"hover":{"background":{"light":"#333333","dark":"#444444"}}}}}
    """##, to: theme.appending(path: "config.json"))
    _ = try WidgetPackageStore(directory: directory.appending(path: "packages")).install(theme)
    let root = directory.appending(path: "config.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: Data(##"""
    {"theme":{"id":"night","version":"1"},
     "defaults":{"states":{"warning":{"background":"#555555"},"muted":null}},
     "widgets":[{"id":"spaces","type":"workspaces","position":"left",
                 "workspace":{"style":{"states":{"focused":{"foreground":{"light":"#666666","dark":"#777777"}}}}}}],
     "profiles":[{"name":"p","configuration":{"defaults":{"states":{"hover":{"foreground":"#888888"}}}}}]}
    """##.utf8))
    #expect(configuration.defaults.states?["warning"] == WidgetStyle(foreground: HexColor(light: 0xaa0000ff, dark: 0xff4444ff),
                                                                      background: .color(HexColor(0x555555ff))))
    #expect(configuration.defaults.states?["muted"] == nil)
    #expect(configuration.defaults.states?["hover"] == WidgetStyle(foreground: HexColor(0x888888ff),
                                                                    background: .color(HexColor(light: 0x333333ff, dark: 0x444444ff))))
    let cell = try #require(configuration.widgets[0].workspace).cellStyle(.focused)
    #expect(cell.resting.foreground == HexColor(light: 0x666666ff, dark: 0x777777ff))
    let error = #expect(throws: (any Error).self) {
        try loader.load(root, data: Data(##"{"widgets":[],"defaults":{"states":{"warning":{"background":{"light":"#111111"}}}}}"##.utf8))
    }
    #expect(error.map(errorMessage) == "defaults.states.warning.background: Missing property dark.")
}
