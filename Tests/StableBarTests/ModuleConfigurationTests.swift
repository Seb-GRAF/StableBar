import Foundation
import Testing
@testable import StableBar

private func writeConfiguration(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url, options: .atomic)
}

@Test func modulesComposeRelativeToEachFileWithRootOverrides() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "bar/config.json")
    let module = directory.appending(path: "bar/modules/system.json")
    let theme = directory.appending(path: "bar/themes/dark.json")
    let shared = directory.appending(path: "shared/clock.json")
    try writeConfiguration(##"""
    {"bar":{"height":36,"menuBarRevealDelay":500,"style":{"foreground":"#eeeeee","fontSize":11}},
     "defaults":{"fontSize":12,"background":"#111111"},
     "environment":{"SHARED":"theme","THEME":"dark"},
     "popups":{"details":{"height":180,"style":{"fontSize":12},"layout":{"type":"text","text":"Details"}}}}
    """##, to: theme)
    try writeConfiguration(#"""
    {"includes":["../themes/dark.json"],"bar":{"height":38,"menuBarRevealDelay":1000},
     "widgets":[{"id":"system","type":"text","position":"left","text":"System","popupName":"details"}]}
    """#, to: module)
    try writeConfiguration(#"""
    {"defaults":{"fontSize":13},"widgets":[{"id":"clock","type":"clock","position":"right"}]}
    """#, to: shared)
    try writeConfiguration(##"""
    {"includes":["modules/system.json","../shared/clock.json"],
     "bar":{"height":44,"menuBarRevealDelay":2000,"style":{"fontSize":15}},"defaults":{"foreground":"#abcdef"},
     "environment":{"SHARED":"root"},"popups":{"details":{"openOnHover":true,"style":{"foreground":"#abcdef"}}},
     "widgets":[{"id":"local","type":"text","position":"right","text":"Local"}]}
    """##, to: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.widgets.map(\.id) == ["system", "clock", "local"])
    #expect(configuration.bar.height == 44)
    #expect(configuration.bar.menuBarRevealDelay == 2000)
    #expect(loader.contributions["bar.menuBarRevealDelay"]?.map(\.value) == [.number(500), .number(1000), .number(2000)])
    #expect(configuration.bar.style.fontSize == 15)
    #expect(configuration.bar.style.foreground == HexColor(0xeeeeeeff))
    #expect(configuration.defaults.fontSize == 13)
    #expect(configuration.defaults.background == .color(HexColor(0x111111ff)))
    #expect(configuration.defaults.foreground == HexColor(0xabcdefff))
    #expect(configuration.environment == ["SHARED": "root", "THEME": "dark"])
    #expect(configuration.popups["details"]?.height == 180)
    #expect(configuration.popups["details"]?.openOnHover == true)
    #expect(configuration.popups["details"]?.style.fontSize == 12)
    #expect(configuration.popups["details"]?.style.foreground == HexColor(0xabcdefff))
    #expect(loader.dependencies == [root, module, theme, shared])
}

@Test func contributionHistoryKeepsTemplateWidgetAndProfileOverridesInOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let module = directory.appending(path: "module.json")
    try writeConfiguration(#"""
    {"bar":{"menuBarRevealDelay":1000},"templates":{"base":{"type":"clock","position":"right","style":{"fontSize":11}}},
     "widgetOverrides":{"time":{"style":{"fontSize":15}}},
     "defaults":{"foreground":"@token.missing"}}
    """#, to: module)
    try writeConfiguration(##"""
    {"includes":["module.json"],"widgets":[{"id":"time","template":"base","style":{"fontSize":13}}],
     "profiles":[{"name":"work","configuration":{"bar":{"menuBarRevealDelay":3000},"defaults":{"foreground":"#123456"},
                  "widgetOverrides":{"time":{"style":{"fontSize":18}}}}}]}
    """##, to: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.widgets[0].style.fontSize == 18)
    #expect(configuration.bar.menuBarRevealDelay == 3000)
    #expect(loader.contributions["bar.menuBarRevealDelay"]?.last?.origin.profile == "work")
    let history = try #require(loader.contributions["widgets.time.style.fontSize"])
    #expect(history.map(\.value) == [.number(11), .number(13), .number(15), .number(18)])
    #expect(history.first?.origin.detail == "(template base)")
    #expect(history.last?.origin.profile == "work")
    #expect(history.last?.origin.detail == "(profile work) (widget override)")
    #expect(loader.contributions["defaults.foreground"]?.first?.value == .string("@token.missing"))
}

@Test func packageContributionHistoryRetainsRawSettingsAndTheirSelectedValues() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let package = directory.appending(path: "packages/type-theme/1.0.0")
    try writeConfiguration(#"""
    {"id":"type-theme","name":"Type Theme","version":"1.0.0","kind":"theme","entry":"config.json",
     "settings":{"size":{"type":"number","default":12}}}
    """#, to: package.appending(path: "package.json"))
    try writeConfiguration(#"{"defaults":{"fontSize":"@setting.size"}}"#, to: package.appending(path: "config.json"))
    try writeConfiguration(#"""
    {"theme":{"id":"type-theme","version":"1.0.0","settings":{"size":17}},"widgets":[]}
    """#, to: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.defaults.fontSize == 17)
    let contribution = try #require(loader.contributions["defaults.fontSize"]?.last)
    #expect(contribution.value == .string("@setting.size"))
    #expect(contribution.settingValue == .number(17))
}

@Test func widgetTemplatesInheritRecursivelyAndReplaceArrays() throws {
    let data = Data(##"""
    {"templates":{
       "base":{"type":"script","position":"right","interval":30,"events":["base"],
               "environment":{"BASE":"yes","SHARED":"base"},
               "style":{"foreground":"#eeeeee","fontSize":12},
               "hoverLayout":{"type":"text","text":"Adjust","style":{"width":100}},
               "layout":{"type":"row","style":{"spacing":6},"children":[{"type":"text","text":"base"}]}},
       "metric":{"template":"base","style":{"fontSize":14,"background":"#111111"},
                 "hoverLayout":{"style":{"height":16}},"layout":{"style":{"paddingHorizontal":8}}}
     },"widgets":[{"id":"cpu","template":"metric","command":"echo 10%","interval":null,
                   "events":["refresh"],"environment":{"SHARED":"widget"},
                   "style":{"foreground":"#abcdef"},
                   "hoverLayout":{"style":{"width":120}},"layout":{"children":[{"type":"field","field":"text"}]}}]}
    """##.utf8)
    let configuration = try JSONDecoder().decode(Configuration.self, from: data)
    let widget = configuration.widgets[0]
    #expect(widget.position == .right)
    #expect(widget.content == .script(command: "echo 10%", interval: nil))
    #expect(widget.events == ["refresh"])
    #expect(widget.environment == ["BASE": "yes", "SHARED": "widget"])
    #expect(widget.style.fontSize == 14)
    #expect(widget.style.foreground == HexColor(0xabcdefff))
    #expect(widget.style.background == .color(HexColor(0x111111ff)))
    #expect(widget.hoverLayout?.style.width == 120)
    #expect(widget.hoverLayout?.style.height == 16)
    #expect(widget.layout?.style.spacing == 6)
    #expect(widget.layout?.style.paddingHorizontal == 8)
    guard case let .text(hoverText) = widget.hoverLayout?.content,
          case let .row(children) = widget.layout?.content,
          case let .field(field) = children[0].content else {
        Issue.record("The template layout was not preserved.")
        return
    }
    #expect(hoverText == "Adjust")
    #expect(children.count == 1)
    #expect(field == "text")
}

@Test func moduleTemplatesCanBeOverriddenByTheRootWithoutDefiningRootWidgets() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try writeConfiguration(##"""
    {"templates":{"label":{"type":"text","position":"left","style":{"fontSize":12,"foreground":"#eeeeee"}}},
     "widgets":[{"id":"label","template":"label","text":"Ready"}]}
    """##, to: directory.appending(path: "module.json"))
    try writeConfiguration(#"""
    {"includes":["module.json"],"templates":{"label":{"style":{"fontSize":16}}}}
    """#, to: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.widgets[0].style.fontSize == 16)
    #expect(configuration.widgets[0].style.foreground == HexColor(0xeeeeeeff))
    #expect(configuration.widgets[0].content == .text("Ready"))
}

@Test func moduleCompositionRejectsDuplicateIDsAndIncludeCycles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let module = directory.appending(path: "module.json")
    try writeConfiguration(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#, to: module)
    try writeConfiguration(#"{"includes":["module.json"],"widgets":[{"id":"clock","type":"clock","position":"left"}]}"#, to: root)
    var loader = ConfigurationLoader()
    #expect(throws: DecodingError.self) { try loader.load(root) }
    try writeConfiguration(#"{"includes":["config.json"]}"#, to: module)
    #expect(throws: ConfigurationCompositionError.self) { try loader.load(root) }
    #expect(loader.dependencies == [root, module])
    let alias = directory.appending(path: "alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    try writeConfiguration(#"{"includes":["alias.json"]}"#, to: module)
    #expect(throws: ConfigurationCompositionError.self) { try loader.load(root) }
}

@Test func unknownAndCyclicWidgetTemplatesFailBeforeReplacingWidgets() {
    #expect(throws: ConfigurationCompositionError.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"{"widgets":[{"id":"label","template":"missing"}]}"#.utf8))
    }
    #expect(throws: ConfigurationCompositionError.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"templates":{"a":{"template":"b"},"b":{"template":"a"}},"widgets":[{"id":"label","template":"a"}]}
        """#.utf8))
    }
}

@Test func configurationEditsValidateIncludesUsingTheOriginalDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let module = directory.appending(path: "module.json")
    try writeConfiguration(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#, to: module)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: Data(#"{"includes":["module.json"],"bar":{"height":48}}"#.utf8))
    #expect(configuration.bar.height == 48)
    #expect(configuration.widgets.map(\.id) == ["clock"])
    #expect(loader.dependencies == [root, module])
}

@Test @MainActor func dependencyWatcherDetectsAtomicSavesAndMissingDirectoryRepairs() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "bar/config.json")
    let module = directory.appending(path: "shared/nested/widgets.json")
    try writeConfiguration(#"{"includes":["../shared/nested/widgets.json"]}"#, to: root)
    var loader = ConfigurationLoader()
    #expect(throws: (any Error).self) { try loader.load(root) }
    #expect(loader.dependencies == [root, module])
    let watcher = ConfigurationWatcher()
    defer { watcher.stop() }
    var changed = false
    watcher.onChange = { changed = true }
    watcher.watch(loader.dependencies)
    try writeConfiguration(#"{"widgets":[{"id":"label","type":"text","position":"left","text":"First"}]}"#, to: module)
    for _ in 0..<100 {
        if changed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(changed)
    #expect(try loader.load(root).widgets[0].content == .text("First"))
    watcher.watch(loader.dependencies)
    changed = false
    try writeConfiguration(#"{"widgets":[{"id":"label","type":"text","position":"left","text":"Second"}]}"#, to: module)
    for _ in 0..<100 {
        if changed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(changed)
    #expect(try loader.load(root).widgets[0].content == .text("Second"))
}

@Test func widgetOverridesCustomizeImportedTemplatesWithoutReplacingModules() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try writeConfiguration(##"""
    {"templates":{"metric":{"type":"script","position":"right","interval":15,"enabled":false,"tooltip":"CPU usage",
       "popup":{"openOnHover":false,"style":{},"layout":{"type":"text","text":"Details"}},
       "style":{"fontSize":12,"foreground":"#eeeeee"},"events":["workspace","wake"]}},
     "widgets":[{"id":"cpu","template":"metric","command":"echo 10%"},
                {"id":"clock","type":"clock","position":"right","format":"HH:mm"}],
     "widgetOverrides":{"cpu":{"style":{"background":"#111111"}}}}
    """##, to: directory.appending(path: "module.json"))
    try writeConfiguration(##"""
    {"includes":["module.json"],"widgetOverrides":{
      "cpu":{"enabled":true,"interval":null,"events":["refresh"],"style":{"fontSize":16},
             "tooltip":"System load","popup":{"openOnHover":true}},
      "clock":{"enabled":false,"format":"h:mm a"}}}
    """##, to: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root)
    #expect(configuration.widgets.map(\.id) == ["cpu", "clock"])
    let cpu = configuration.widgets[0]
    #expect(cpu.enabled)
    #expect(cpu.content == .script(command: "echo 10%", interval: nil))
    #expect(cpu.events == ["refresh"])
    #expect(cpu.style.fontSize == 16)
    #expect(cpu.style.foreground == HexColor(0xeeeeeeff))
    #expect(cpu.style.background == .color(HexColor(0x111111ff)))
    #expect(cpu.tooltip == "System load")
    #expect(cpu.popup?.openOnHover == true)
    guard case .text("Details") = cpu.popup?.layout.content else {
        Issue.record("The popup layout from the template was not preserved.")
        return
    }
    #expect(!configuration.widgets[1].enabled)
    #expect(configuration.widgets[1].content == .clock(format: "h:mm a"))
}

@Test func widgetOverridesRejectUnknownTargetsAndIdentityChanges() {
    #expect(throws: ConfigurationCompositionError.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"widgets":[{"id":"clock","type":"clock","position":"right"}],"widgetOverrides":{"missing":{"format":"HH:mm"}}}
        """#.utf8))
    }
    for id in ["changed", "clock"] {
        #expect(throws: ConfigurationCompositionError.self) {
            try JSONDecoder().decode(Configuration.self, from: Data("""
            {"widgets":[{"id":"clock","type":"clock","position":"right"}],"widgetOverrides":{"clock":{"id":"\(id)"}}}
            """.utf8))
        }
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"widgets":[{"id":"clock","type":"clock","position":"left"},{"id":"clock","type":"clock","position":"right"}],
         "widgetOverrides":{"clock":{"enabled":false}}}
        """#.utf8))
    }
}

@Test func modulesRejectExplicitNullWidgetListsInsteadOfClearingInheritedWidgets() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try writeConfiguration(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#,
                           to: directory.appending(path: "module.json"))
    try writeConfiguration(#"{"includes":["module.json"],"widgets":null}"#, to: root)
    var loader = ConfigurationLoader()
    #expect(throws: DecodingError.self) { try loader.load(root) }
}

@Test @MainActor func liveModuleReloadPreservesWorkingScriptsAndRecoversAfterRepair() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "bar/config.json")
    let module = directory.appending(path: "shared/status.json")
    let document = #"""
    {"bar":{"height":37},"widgets":[{"id":"status","type":"script","position":"right",
      "command":"printf '%s' \"$SENDER\"","interval":null}]}
    """#
    try writeConfiguration(document, to: module)
    try writeConfiguration(#"{"includes":["../shared/status.json"]}"#, to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.start()
    let previous = try #require(store.configuration)
    let script = try #require(store.scripts["status"])
    for _ in 0..<100 {
        if script.output.text == "startup" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "startup")
    try writeConfiguration("{", to: module)
    for _ in 0..<100 {
        if store.configurationError != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.configurationError != nil)
    #expect(store.configuration?.bar.height == previous.bar.height)
    #expect(store.configuration?.widgets.map(\.id) == previous.widgets.map(\.id))
    #expect(store.configuration?.widgets[0].content == previous.widgets[0].content)
    #expect(store.scripts["status"] === script)
    #expect(script.output.text == "startup")
    try writeConfiguration(document.replacingOccurrences(of: "37", with: "49"), to: module)
    for _ in 0..<100 {
        if store.configuration?.bar.height == 49 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.configuration?.bar.height == 49)
    #expect(store.configurationError == nil)
    #expect(store.scripts["status"] === script)
    #expect(script.output.text == "startup")
    try writeConfiguration(#"""
    {"includes":["../shared/status.json"],"widgetOverrides":{"status":{"enabled":false}}}
    """#, to: root)
    for _ in 0..<100 {
        if store.scripts["status"] == nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.configuration?.widgets[0].enabled == false)
    #expect(store.scripts["status"] == nil)
    script.refresh(ScriptEvent(sender: "disabled"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(script.output.text == "startup")
    try writeConfiguration(#"""
    {"includes":["../shared/status.json"],"widgetOverrides":{"status":{"enabled":true}}}
    """#, to: root)
    for _ in 0..<100 {
        if store.scripts["status"]?.output.text == "startup" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.configuration?.widgets[0].enabled == true)
    #expect(store.scripts["status"]?.output.text == "startup")
    #expect(store.scripts["status"] !== script)
    #expect(store.configurationError == nil)
}

@Test @MainActor func aJSONErrorAtLaunchReloadsOnceTheFileIsFixed() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try writeConfiguration(#"{"bar":{"height":37},"widgets":["#, to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.start()
    #expect(store.configurationError != nil)
    try writeConfiguration(#"{"bar":{"height":37},"widgets":[]}"#, to: root)
    for _ in 0..<100 {
        if store.configuration != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.configuration?.bar.height == 37)
    #expect(store.configurationError == nil)
}

@Test func unknownPropertiesAndSourceTypesFailWithTheirPath() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "strict.json")
    var loader = ConfigurationLoader()
    for (json, message) in [
        (##"{"widgets":[{"id":"clock","type":"clock","position":"right","style":{"states":{"warning":{"colour":"#ff0000"}}}}]}"##, "widgets.clock: style.states.warning.colour: Unknown property."),
        (#"{"widgets":[{"id":"clock","type":"clock","position":"right","style":{"fontsize":14}}]}"#, "widgets.clock: style.fontsize: Unknown property."),
        (#"{"widgets":[],"bar":{"heigth":30}}"#, "bar.heigth: Unknown property."),
        (#"{"widgets":[],"bar":{"displayScale":{"buildIn":0.8}}}"#, "bar.displayScale: Use builtIn or external with a positive number."),
        (#"{"widgets":[],"bar":{"displayScale":{"external":0}}}"#, "bar.displayScale: Use builtIn or external with a positive number."),
        (#"{"widgets":[],"profiles":[{"name":"dark","when":{"apperance":"dark"},"configuration":{}}]}"#, "profiles.0.when.apperance: Unknown property."),
        (#"{"widgets":[{"id":"date","type":"clock","position":"right","open":"Calendar"}]}"#, "widgets.date: open: Use an http, https, mailto or x-apple.systempreferences URL, or an application bundle identifier such as com.apple.iCal."),
        (#"{"widgets":[{"id":"date","type":"clock","position":"right","open":"file:///Applications/Calendar.app"}]}"#, "widgets.date: open: Use an http, https, mailto or x-apple.systempreferences URL, or an application bundle identifier such as com.apple.iCal."),
        (#"{"widgets":[{"id":"date","type":"clock","position":"right","onClick":"open -a Calendar","open":"com.apple.iCal"}]}"#, "widgets.date: open: A widget cannot set both onClick and open."),
        (#"{"widgets":[],"popups":{"agenda":{"style":{},"layout":{"type":"row","onClickField":"joinCommand","openField":"link","children":[]}}}}"#, "popups.agenda.layout.open: A block cannot combine onClick or onClickField with open or openField."),
        (#"{"widgets":[],"popups":{"apps":{"style":{},"layout":{"type":"row","quitField":"pid","open":"com.apple.ActivityMonitor","children":[]}}}}"#, "popups.apps.layout.quitField: A block cannot combine quitField with onClick, onClickField, open or openField."),
        (#"{"widgets":[],"popups":{"ask":{"style":{},"layout":{"type":"text","text":"Answer","wrap":true}}}}"#, "popups.ask.layout.wrap: wrap and markdown apply to field blocks, and maxHeight to field blocks that wrap."),
        (#"{"widgets":[],"popups":{"ask":{"style":{},"layout":{"type":"symbol","name":"sparkles","shimmer":true}}}}"#, "popups.ask.layout.shimmer: shimmer applies to text and field blocks."),
        (#"{"widgets":[],"popups":{"ask":{"style":{},"layout":{"type":"field","field":"answer","wrap":true,"maxHeight":0}}}}"#, "popups.ask.layout.maxHeight: maxHeight must be greater than zero."),
        (#"{"widgets":[}"#, "The given data was not valid JSON. Unexpected character '}' around line 1, column 13."),
        (#"{"providers":{"machine":{"type":"sytem"}},"widgets":[]}"#, "providers.machine.type: Unknown provider type."),
        (#"{"providers":{"feed":{"type":"stream"}},"widgets":[]}"#, "providers.feed: Missing property command."),
        (#"{"widgets":[{"id":"disk","type":"disk","position":"right"}]}"#, "widgets.disk: type: Unknown widget type."),
        (#"{"widgets":[{"id":"disk","type":"provider","provider":"disk","position":"right"}]}"#, "Unknown provider: disk."),
        (#"{"widgets":[],"profiles":[{"name":"work","configuration":{"providers":{"machine":{"type":"command"}}}}]}"#,
         "providers.machine: Missing property command.")
    ] {
        let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(json.utf8)) }
        #expect(error.map(errorMessage) == message)
    }
    #expect(try loader.load(url, data: Data(#"{"$schema":"stablebar.schema.json","widgets":[]}"#.utf8)).widgets.isEmpty)
    let opening = try loader.load(url, data: Data(#"""
    {"widgets":[{"id":"date","type":"clock","position":"right","open":"com.apple.iCal",
      "popup":{"style":{},"layout":{"type":"row","openField":"link","open":"x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars","children":[]}}}]}
    """#.utf8))
    #expect(opening.widgets[0].open == "com.apple.iCal")
    #expect(opening.widgets[0].popup?.layout.openField == "link")
    #expect(try loader.load(url, data: Data(#"{"widgets":[{"id":"docs","type":"text","position":"right","text":"Docs","open":"HTTPS://example.com"}]}"#.utf8)).widgets[0].open == "HTTPS://example.com")
    let configuration = try loader.load(url, data: Data(#"{"providers":{"machine":{"type":"system","interval":2}},"widgets":[]}"#.utf8))
    #expect(configuration.providers["machine"]?.type == "system")
    #expect(configuration.providers["machine"]?.command == nil)
}

private func schemaProperties(_ definition: ConfigurationValue?) throws -> Set<String> {
    Set(try (definition?.decoded([String: ConfigurationValue].self)["properties"] ?? .object([:])).decoded([String: ConfigurationValue].self).keys)
}

@Test func schemaListsTheSamePropertiesAsTheDecoders() throws {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "stablebar.schema.json")
    let schema = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    let definitions = try schema["definitions"]!.decoded([String: ConfigurationValue].self)
    let decoders: [String: [CodingKey]] = [
        "style": WidgetStyle.CodingKeys.allCases, "widget": WidgetConfiguration.CodingKeys.allCases, "bar": BarSettings.CodingKeys.allCases,
        "block": PopupBlock.CodingKeys.allCases, "popup": PopupConfiguration.CodingKeys.allCases, "option": PopupControlOption.CodingKeys.allCases,
        "animation": WidgetAnimation.CodingKeys.allCases, "workspace": WorkspaceConfiguration.CodingKeys.allCases,
        "actions": WidgetActions.CodingKeys.allCases, "menuItem": WidgetMenuItem.CodingKeys.allCases,
        "provider": ProviderConfiguration.CodingKeys.allCases, "group": WidgetGroupConfiguration.CodingKeys.allCases,
        "profile": ConfigurationProfile.CodingKeys.allCases, "conditions": ProfileConditions.CodingKeys.allCases,
        "packageSelection": WidgetPackageSelection.CodingKeys.allCases, "rule": StyleRule.CodingKeys.allCases,
        "ruleCondition": RuleCondition.CodingKeys.allCases, "workspaceDefaults": WorkspaceDefaults.CodingKeys.allCases,
        "glass": GlassSettings.CodingKeys.allCases, "screen": ScreenConfiguration.CodingKeys.allCases,
        "packageSource": PackageSource.CodingKeys.allCases, "menuBarItem": MenuBarItemReference.CodingKeys.allCases
    ]
    for (name, keys) in decoders {
        #expect(try schemaProperties(definitions[name]) == Set(keys.map(\.stringValue) + (name == "widget" ? ["template"] : [])), "\(name)")
    }
    #expect(try schemaProperties(.object(schema)) == Set(Configuration.CodingKeys.allCases.map(\.stringValue)
        + ["$schema", "tokens", "packages", "packageSources", "theme", "includes", "profiles", "profile", "widgetOrder"]))
}

@Test func packageSchemaListsTheSamePropertiesAsTheManifestDecoder() throws {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "package.schema.json")
    let schema = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    #expect(try schemaProperties(.object(schema)) == Set(WidgetPackageManifest.CodingKeys.allCases.map(\.stringValue)))
    let setting = try schema["definitions"]?.decoded([String: ConfigurationValue].self)["setting"]
    #expect(try schemaProperties(setting) == Set(WidgetPackageSetting.CodingKeys.allCases.map(\.stringValue)))
}

@Test func menuBarItemsOpenOnHoverUnlessSetToOpenOnClick() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"items","type":"menuBarItems","position":"right"},
                {"id":"clicked","type":"menuBarItems","position":"right","openOnHover":false}]}
    """#.utf8))
    #expect(configuration.widgets.map(\.content) == [.menuBarItems(openOnHover: true, shown: [], hidden: []),
                                                     .menuBarItems(openOnHover: false, shown: [], hidden: [])])
}

@Test func menuBarItemsPutTheirSymbolLastUnlessPlacedOrHidden() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"last","type":"menuBarItems","position":"right","shown":[{"app":"Granola"}]},
                {"id":"first","type":"menuBarItems","position":"right","shown":["symbol",{"app":"Granola"}]},
                {"id":"hidden","type":"menuBarItems","position":"right","shown":[{"app":"Granola"}],"hidden":["symbol"]},
                {"id":"plain","type":"menuBarItems","position":"right"}]}
    """#.utf8))
    let granola = MenuBarItemsEntry.item(MenuBarItemReference(app: "Granola", item: nil))
    #expect(configuration.widgets.map(\.shownMenuBarItems) == [[granola, .symbol], [.symbol, granola], [granola], [.symbol]])
    #expect(configuration.widgets.map(\.drawsMenuBarItems) == [true, true, true, false])
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"widgets":[{"id":"items","type":"menuBarItems","position":"right","shown":["grid"]}]}
        """#.utf8))
    }
}

@Test func examplesAndTheStarterConfigurationStayValid() throws {
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var loader = ConfigurationLoader()
    loader.themesDirectory = repository.appending(path: "Resources/themes")
    let modular = try loader.load(repository.appending(path: "examples/modular/config.json"))
    #expect(modular.defaults.hoverBackground == .color(HexColor(0x29384bff)))
    #expect(modular.defaults.states?["warning"]?.foreground == HexColor(0xf5c26bff))
    let cpu = try #require(modular.widgets.first { $0.id == "cpu" })
    #expect(cpu.rules.map(\.state) == ["critical", "warning"])
    #expect(modular.widgets.first { $0.id == "status" }?.transition == .fade)
    #expect(modular.widgets.first { $0.id == "clock" }?.transition == .numeric)
    #expect(modular.widgets.first { $0.id == "volume" }?.content == .script(command: #"/bin/sh "$CONFIG_DIR/volume.sh""#, interval: 30))
    #expect(FileManager.default.fileExists(atPath: repository.appending(path: "examples/modular/volume.sh").path))
    let critical = ResolvedWidgetStyle(base: resolveStyle([modular.defaults, cpu.style]), state: "critical")
    #expect(critical.style(hovered: false).background == .color(HexColor(0xf28b82ff)))
    #expect(critical.style(hovered: true).background == .color(HexColor(0xf5a59eff)))
    #expect(critical.style(hovered: true).foreground == HexColor(0x18212dff))
    for (name, state) in modular.defaults.states ?? [:] where state.background != nil && !StyleStates.reservedNames.contains(name) {
        #expect(state.states?["hover"]?.background != nil, "\(name) needs its own hover background")
    }
    #expect(modular.widgets.first { $0.id == "volume" }?.events == ["volumeChange"])
    #expect(modular.activeProviders == ["system"])
    let interactive = try loader.load(repository.appending(path: "examples/interactive/config.json"))
    #expect(interactive.defaults.states?["open"]?.borderWidth == 1)
    #expect(interactive.widgets.first { $0.id == "application" }?.transition == .roll)
    _ = try loader.load(repository.appending(path: "Resources/config.json"))
}

/// Finds the examples itself, so a new one is checked without an entry here.
@Test func everyExampleLoadsBesideTheExamplePackages() throws {
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let examples = repository.appending(path: "examples")
    let files = FileManager.default
    let scratch = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: scratch) }
    let installed = scratch.appending(path: "packages")
    let packages = WidgetPackageStore(directory: installed)
    for package in try files.contentsOfDirectory(at: examples.appending(path: "packages"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
        #expect(throws: Never.self, "packages/\(package.lastPathComponent)") { try packages.install(package) }
    }
    // Loads a configuration as StableBar --validate does, from a folder holding `sources` and the installed packages.
    func validate(_ name: String, _ sources: [URL], configuration: String = "config.json", contents: String? = nil) {
        let directory = scratch.appending(path: UUID().uuidString)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            try files.copyItem(at: installed, to: directory.appending(path: "packages"))
            for source in sources { try files.copyItem(at: source, to: directory.appending(path: source.lastPathComponent)) }
            if let contents { try Data(contents.utf8).write(to: directory.appending(path: configuration)) }
            var loader = ConfigurationLoader()
            loader.themesDirectory = repository.appending(path: "Resources/themes")
            _ = try loader.load(directory.appending(path: configuration))
        } catch {
            Issue.record("\(name): \(errorMessage(error))")
        }
    }
    for example in try files.contentsOfDirectory(at: examples, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
        let name = example.lastPathComponent
        if name == "packages" { continue }
        if name == "modules" {
            // Saved beside a configuration and included, as the guide shows.
            for module in try files.contentsOfDirectory(at: example, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                validate("modules/\(module.lastPathComponent)", [module], contents: #"{"includes":["\#(module.lastPathComponent)"],"widgets":[]}"#)
            }
        } else if try example.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            validate(name, try files.contentsOfDirectory(at: example, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
        } else if example.pathExtension == "json" {
            validate(name, [example], configuration: name)
        }
    }
}

@Test func schemaListsTheRegisteredSourceTypes() throws {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "stablebar.schema.json")
    let schema = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    func typeNames(_ definition: String) -> Set<String> {
        guard case let .object(definitions)? = schema["definitions"], case let .object(object)? = definitions[definition],
              case let .object(properties)? = object["properties"], case let .object(type)? = properties["type"],
              case let .array(choices)? = type["anyOf"], case let .object(names)? = choices.first,
              case let .array(values)? = names["enum"] else { return [] }
        return Set(values.compactMap { if case let .string(name) = $0 { name } else { nil } })
    }
    let registry = DataSourceRegistry.builtIn
    #expect(typeNames("provider") == Set(registry.types.map(\.name)))
    #expect(typeNames("widget") == Set(["aerospace", "workspaces", "activeApp", "appMenu", "appleMenu", "controlCenter", "menuBarItems", "clock", "text", "script", "provider", "spacer"]
        + registry.types.filter(\.isNative).map(\.name)))
    // Each optional setting has a value of its type, which sets it, and one of another type, which the decoder rejects.
    let samples: [ProviderConfiguration.CodingKeys: (valid: String, invalid: String)] = [
        .calendars: (#"["Work"]"#, #""Work""#), .lookahead: ("12", #""12""#), .soon: ("10", #""10""#), .now: ("2", #""2""#),
        .processes: ("5", #""5""#), .sortBy: (#""cpu""#, #""unknown""#), .units: (#""bits""#, #""unknown""#),
        .cpuWarning: ("0.8", #""high""#), .memoryWarning: ("0.8", #""high""#)
    ]
    #expect(Set(registry.types.flatMap(\.optionalSettings)) == Set(samples.keys))
    for type in registry.types {
        let decoded = try? JSONDecoder().decode(ProviderConfiguration.self, from: Data(#"{"type":"\#(type.name)"}"#.utf8))
        #expect((decoded != nil) == type.settings.isEmpty, "\(type.name)")
        if let decoded { #expect(decoded == ProviderConfiguration(type: type.name), "\(type.name)") }
        for setting in type.optionalSettings {
            let values = try #require(samples[setting])
            func provider(_ value: String) throws -> ProviderConfiguration {
                try JSONDecoder().decode(ProviderConfiguration.self,
                                         from: Data(#"{"type":"\#(type.name)","\#(setting.stringValue)":\#(value)}"#.utf8))
            }
            #expect(try provider(values.valid) != ProviderConfiguration(type: type.name), "\(type.name).\(setting.stringValue)")
            #expect(throws: (any Error).self, "\(type.name).\(setting.stringValue)") { try provider(values.invalid) }
        }
    }
    // As before the registry, other types accept these settings too; only the type that lists them reads them.
    #expect(try JSONDecoder().decode(ProviderConfiguration.self, from: Data(#"{"type":"system","calendars":["Work"],"soon":10}"#.utf8))
        .type == "system")
}
