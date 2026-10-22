import AppKit
import Foundation
import Observation
import Testing
import os
@testable import StableBar

private let threeWidgets = ##"""
{"bar":{"style":{"background":"#000000"}},"widgets":[
  {"id":"a","type":"script","command":"true","position":"left"},
  {"id":"b","type":"script","command":"true","position":"left"},
  {"id":"c","type":"text","text":"C","position":"right"}]}
"""##

@MainActor private func makeStore(_ json: String) throws -> BarStore {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    for widget in store.configuration?.widgets ?? [] {
        if case .script = widget.content { store.scripts[widget.id] = ScriptWidget() }
    }
    store.preparePresentations()
    return store
}

private func output(_ json: String) throws -> ScriptOutput {
    try ScriptOutput.read(Data(json.utf8))
}

@Test @MainActor func outputUpdatesInvalidateOnlyTheWidgetsTheyRestyle() async throws {
    let store = try makeStore(threeWidgets)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    let second = try #require(store.presentations["b"])
    let third = try #require(store.presentations["c"])
    try await confirmation("a is restyled", expectedCount: 1) { restyled in
        try await confirmation("b, c and the bar stay valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = first.style } onChange: { restyled() }
            withObservationTracking { _ = second.style; _ = second.hidden; _ = second.display } onChange: { invalidated() }
            withObservationTracking { _ = third.style } onChange: { invalidated() }
            withObservationTracking { _ = store.barStyle; _ = store.presentations } onChange: { invalidated() }
            try a.accept(output(##"{"text":"1","style":{"foreground":"#ff0000"}}"##))
        }
    }
    #expect(first.style.style(hovered: false).foreground == HexColor(0xff0000ff))
    try await confirmation("Output that keeps a's style leaves it valid", expectedCount: 0) { invalidated in
        withObservationTracking { _ = first.style; _ = first.hidden; _ = first.display } onChange: { invalidated() }
        try a.accept(output(##"{"text":"2","style":{"foreground":"#ff0000"}}"##))
    }
    try await confirmation("widgetStyles restyle their target", expectedCount: 1) { restyled in
        try await confirmation("b stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = third.style } onChange: { restyled() }
            withObservationTracking { _ = second.style } onChange: { invalidated() }
            try a.accept(output(##"{"text":"3","style":{"foreground":"#ff0000"},"widgetStyles":{"c":{"background":"#00ff00"}}}"##))
        }
    }
    #expect(third.style.base.background == .color(HexColor(0x00ff00ff)))
    try await confirmation("barStyle restyles the bar", expectedCount: 1) { restyled in
        try await confirmation("widgets stay valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = store.barStyle } onChange: { restyled() }
            withObservationTracking { _ = second.style; _ = third.style } onChange: { invalidated() }
            try a.accept(output(##"{"text":"4","style":{"foreground":"#ff0000"},"widgetStyles":{"c":{"background":"#00ff00"}},"barStyle":{"background":"#0000ff"}}"##))
        }
    }
    #expect(store.barStyle.background == .color(HexColor(0x0000ffff)))
}

@Test @MainActor func hiddenAndDisplayOutputChangeOnlyTheirWidgetsPresence() async throws {
    let store = try makeStore(threeWidgets)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    let second = try #require(store.presentations["b"])
    try await confirmation("a's presence changes", expectedCount: 1) { changed in
        try await confirmation("b stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = first.hidden; _ = first.display } onChange: { changed() }
            withObservationTracking { _ = second.hidden; _ = second.display; _ = second.style } onChange: { invalidated() }
            try a.accept(output(#"{"text":"","hidden":true,"display":"main"}"#))
        }
    }
    #expect(first.hidden)
    #expect(first.display == .main)
    a.error = "Offline"
    store.updatePresentations()
    #expect(!first.hidden)
}

@Test @MainActor func successfulActionsLeaveActionErrorsUntouched() async throws {
    let store = try makeStore(threeWidgets)
    let text = try #require(store.configuration?.widgets.first { $0.id == "c" })
    await confirmation("No widget re-reads an action error", expectedCount: 0) { invalidated in
        withObservationTracking { _ = store.actionErrors["a"] } onChange: { invalidated() }
        await store.runAction("true", widget: text).value
    }
    #expect(store.actionErrors.isEmpty)
}

@Test @MainActor func reloadingResolvesScriptStylesInTheStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    try Data(##"""
    {"widgets":[{"id":"status","type":"script","position":"right","interval":null,
      "command":"printf '{\"text\":\"Ready\",\"style\":{\"foreground\":\"#ff0000\"},\"barStyle\":{\"background\":\"#00ff00\"}}'"}]}
    """##.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    for _ in 0..<100 {
        if store.barStyle.background == .color(HexColor(0x00ff00ff)) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.barStyle.background == .color(HexColor(0x00ff00ff)))
    #expect(store.presentations["status"]?.style.base.foreground == HexColor(0xff0000ff))
}

@Test @MainActor func aStoreThatOnlyShowsAnotherStoresScriptsLeavesThemReportingToIt() throws {
    let bar = try makeStore(threeWidgets)
    let a = try #require(bar.scripts["a"])
    try a.accept(output(##"{"text":"1","style":{"foreground":"#ff0000"}}"##))
    let preview = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    preview.configuration = bar.configuration
    preview.scripts = bar.scripts
    preview.preparePresentations()
    #expect(preview.presentations["a"]?.style.base.foreground == HexColor(0xff0000ff))
    try a.accept(output(##"{"text":"2","style":{"foreground":"#00ff00"}}"##))
    #expect(bar.presentations["a"]?.style.base.foreground == HexColor(0x00ff00ff))
}

@Test @MainActor func scriptUpdatesInvalidateOnlyTheViewsTheyAffect() throws {
    let store = try makeStore(threeWidgets)
    let configuration = try #require(store.configuration)
    let a = try #require(store.scripts["a"])
    let bar = BarView(store: store, display: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil))
    let widgets = Dictionary(uniqueKeysWithValues: configuration.widgets.map {
        ($0.id, WidgetView(widget: $0, defaults: configuration.defaults, popupDefaults: configuration.popupDefaults, store: store,
                           monitor: 1, defaultAnimation: WidgetAnimation(duration: 0.2), defaultTransition: .none))
    })
    var updates = 0
    func invalidated(by extra: String) throws -> [String] {
        let views = OSAllocatedUnfairLock(initialState: [String]())
        withObservationTracking { _ = bar.body } onChange: { views.withLock { $0.append("bar") } }
        withObservationTracking { _ = store.barStyle } onChange: { views.withLock { $0.append("decoration") } }
        for (id, view) in widgets {
            withObservationTracking { _ = view.body } onChange: { views.withLock { $0.append(id) } }
        }
        updates += 1
        try a.accept(output(#"{"text":"\#(updates)"\#(extra)}"#))
        return views.withLock { $0 }.sorted()
    }
    let style = ##","style":{"foreground":"#ff0000"}"##
    let widgetStyles = ##","widgetStyles":{"c":{"background":"#00ff00"}}"##
    let barStyle = ##","barStyle":{"background":"#0000ff"}"##
    #expect(try invalidated(by: "") == ["a"])
    #expect(try invalidated(by: style) == ["a"])
    #expect(try invalidated(by: style + widgetStyles) == ["a", "c"])
    #expect(try invalidated(by: style + widgetStyles + barStyle) == ["a", "decoration"])
    #expect(try invalidated(by: style + widgetStyles + barStyle + #","hidden":true"#) == ["a", "bar"])
    #expect(try invalidated(by: style + widgetStyles + barStyle + #","display":"main""#) == ["a", "bar"])
}

@Test @MainActor func aFailureBringsAHiddenWidgetBack() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    let failure = directory.appending(path: "failure")
    try JSONSerialization.data(withJSONObject: ["widgets": [[
        "id": "status", "type": "script", "position": "right", "interval": NSNull(),
        "command": #"if [ -f "$FAILURE" ]; then printf Offline >&2; exit 1; fi; printf '{"text":"","hidden":true}'"#,
        "environment": ["FAILURE": failure.path]
    ]]]).write(to: url, options: .atomic)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    let script = try #require(store.scripts["status"])
    let presentation = try #require(store.presentations["status"])
    for _ in 0..<100 {
        if presentation.hidden { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(presentation.hidden)
    try Data().write(to: failure)
    script.refresh(ScriptEvent(sender: "check"))
    for _ in 0..<100 {
        if !presentation.hidden { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!presentation.hidden)
    #expect(script.error == "Offline")
}

@Test @MainActor func openingAPopupMarksOnlyTheInstanceThatAnchorsIt() async throws {
    let store = try makeStore(threeWidgets)
    let first = try #require(store.presentations["a"])
    let second = try #require(store.presentations["b"])
    let anchor = NSView()
    let elsewhere = NSView()
    await confirmation("a's popup opens", expectedCount: 1) { opened in
        await confirmation("b stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = first.popupAnchor } onChange: { opened() }
            withObservationTracking { _ = second.popupAnchor; _ = second.style } onChange: { invalidated() }
            store.setPopupVisibleWidget("a", anchor: anchor)
        }
    }
    #expect(first.popupAnchor == ObjectIdentifier(anchor))
    #expect(first.popupAnchor != ObjectIdentifier(elsewhere))
    store.setPopupVisibleWidget("b", anchor: elsewhere)
    #expect(first.popupAnchor == nil)
    #expect(second.popupAnchor == ObjectIdentifier(elsewhere))
    store.setPopupVisibleWidget(nil)
    #expect(second.popupAnchor == nil)
}

@Test @MainActor func openingAPopupInvalidatesOnlyTheViewsOfTheWidgetThatOpenedIt() throws {
    let store = try makeStore(threeWidgets)
    let configuration = try #require(store.configuration)
    let widgets = Dictionary(uniqueKeysWithValues: configuration.widgets.map {
        ($0.id, WidgetView(widget: $0, defaults: configuration.defaults, popupDefaults: configuration.popupDefaults, store: store,
                           monitor: 1, defaultAnimation: WidgetAnimation(duration: 0.2), defaultTransition: .none))
    })
    func invalidated(by change: () -> Void) -> [String] {
        let views = OSAllocatedUnfairLock(initialState: [String]())
        for (id, view) in widgets {
            withObservationTracking { _ = view.body } onChange: { views.withLock { $0.append(id) } }
        }
        change()
        return views.withLock { $0 }.sorted()
    }
    let aAnchor = NSView()
    let bAnchor = NSView()
    #expect(invalidated { store.setPopupVisibleWidget("a", anchor: aAnchor) } == ["a"])
    #expect(invalidated { store.setPopupVisibleWidget("b", anchor: bAnchor) } == ["a", "b"])
    #expect(invalidated { store.setPopupVisibleWidget(nil) } == ["b"])
}

@Test @MainActor func outputStateRestylesOnlyItsWidget() async throws {
    let store = try makeStore(##"""
    {"defaults":{"states":{"warning":{"foreground":"#ff0000"}}},"widgets":[
      {"id":"a","type":"script","command":"true","position":"left"},
      {"id":"b","type":"script","command":"true","position":"left"}]}
    """##)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    let second = try #require(store.presentations["b"])
    try await confirmation("a enters warning", expectedCount: 1) { restyled in
        try await confirmation("b stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = first.style } onChange: { restyled() }
            withObservationTracking { _ = second.style } onChange: { invalidated() }
            try a.accept(output(#"{"text":"12%","state":"warning"}"#))
        }
    }
    #expect(first.style.state == "warning")
    #expect(first.style.style(hovered: false).foreground == HexColor(0xff0000ff))
    try a.accept(output(#"{"text":"40%"}"#))
    #expect(first.style.state == nil)
}

@Test @MainActor func snapshotsReportTheDataState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    try Data(#"""
    {"widgets":[{"id":"power","type":"script","position":"right","interval":null,
      "command":"printf '{\"text\":\"Low\",\"state\":\"warning\"}'"}]}
    """#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    for _ in 0..<100 {
        if store.presentations["power"]?.style.state == "warning" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard case let .object(snapshot) = try store.snapshot(id: "power") else {
        Issue.record("Expected an object snapshot")
        return
    }
    #expect(snapshot["state"] == .string("warning"))
}

@Test @MainActor func snapshotsReportNoStateForAnEmptyOutputState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    try Data(#"""
    {"widgets":[{"id":"power","type":"script","position":"right","interval":null,
      "command":"printf '{\"text\":\"Idle\",\"state\":\"\"}'"}]}
    """#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    for _ in 0..<100 {
        if store.scripts["power"]?.output.text == "Idle" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.scripts["power"]?.output.text == "Idle")
    #expect(store.presentations["power"]?.style.state == nil)
    guard case let .object(snapshot) = try store.snapshot(id: "power") else {
        Issue.record("Expected an object snapshot")
        return
    }
    #expect(snapshot["state"] == .null)
}

@Test @MainActor func rulesRunWhenOutputArrivesForEachWidgetOfASharedProvider() async throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[
      {"id":"compact","type":"battery","position":"right","rules":[{"when":{"value":"percent","below":0.2},"state":"warning"}]},
      {"id":"detail","type":"battery","position":"right","rules":[{"when":{"value":"percent","below":0.5},"state":"muted"}]},
      {"id":"clock","type":"clock","position":"right"}]}
    """#.utf8))
    let battery = ScriptWidget()
    store.scripts = ["compact": battery, "detail": battery]
    store.preparePresentations()
    let compact = try #require(store.presentations["compact"])
    let detail = try #require(store.presentations["detail"])
    let clock = try #require(store.presentations["clock"])
    try battery.accept(output(#"{"text":"40%","values":{"percent":0.4}}"#))
    #expect(compact.style.state == nil)
    #expect(detail.style.state == "muted")
    try await confirmation("compact enters warning", expectedCount: 1) { changed in
        try await confirmation("the others stay valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = compact.style } onChange: { changed() }
            withObservationTracking { _ = detail.style; _ = clock.style } onChange: { invalidated() }
            try battery.accept(output(#"{"text":"15%","values":{"percent":0.15}}"#))
        }
    }
    #expect(compact.style.state == "warning")
    #expect(detail.style.state == "muted")
}

@Test @MainActor func hidingAWidgetWithATransitionChangesOnlyItsPresence() async throws {
    let store = try makeStore(##"""
    {"widgets":[{"id":"a","type":"script","command":"true","position":"left","transition":"fade"},
                {"id":"b","type":"script","command":"true","position":"left"}]}
    """##)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    let second = try #require(store.presentations["b"])
    try await confirmation("a hides", expectedCount: 1) { hidden in
        try await confirmation("b stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = first.hidden } onChange: { hidden() }
            withObservationTracking { _ = second.hidden; _ = second.style; _ = second.display } onChange: { invalidated() }
            try a.accept(output(#"{"text":"","hidden":true}"#))
        }
    }
    #expect(first.hidden)
    try a.accept(output(#"{"text":"Back"}"#))
    #expect(!first.hidden)
}

@Test @MainActor func temporaryOutputShowsItsFieldsForItsDurationThenExpires() async throws {
    let store = try makeStore(threeWidgets)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    let second = try #require(store.presentations["b"])
    try await confirmation("a shows its temporary fields", expectedCount: 1) { shown in
        try await confirmation("b stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = first.temporaryFields } onChange: { shown() }
            withObservationTracking { _ = second.temporaryFields; _ = second.style } onChange: { invalidated() }
            try a.accept(output(#"{"text":"","icon":"speaker.wave.2","temporary":{"fields":{"text":"62"},"duration":1}}"#))
        }
    }
    #expect(first.temporaryFields == ["text": "62"])
    try a.accept(output(#"{"text":"","icon":"speaker.wave.2"}"#))
    #expect(first.temporaryFields == ["text": "62"])
    _ = try await expiry(of: first)
    try await confirmation("Nothing runs after it expires", expectedCount: 0) { changed in
        withObservationTracking { _ = first.temporaryFields; _ = first.style; _ = first.hidden } onChange: { changed() }
        try await Task.sleep(for: .milliseconds(300))
    }
}

@Test @MainActor func aDifferentTemporaryOutputStartsOverWhileTheSameOneDoesNot() async throws {
    let store = try makeStore(threeWidgets)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    try a.accept(output(#"{"text":"","temporary":{"fields":{"text":"61"},"duration":0.2}}"#))
    try a.accept(output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":30}}"#))
    #expect(first.temporaryFields == ["text": "62"])
    try await Task.sleep(for: .milliseconds(600))
    #expect(first.temporaryFields == ["text": "62"], "The first temporary output's expiry was cancelled")
    try await confirmation("The same temporary output leaves it alone", expectedCount: 0) { changed in
        withObservationTracking { _ = first.temporaryFields } onChange: { changed() }
        try a.accept(output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":30}}"#))
    }
}

/// Waits until `presentation` shows no temporary fields, and returns when it saw them go. It counts
/// polls instead of watching a deadline: while other tests hold the main actor, the expiry waits in
/// line behind a poll, and a deadline can pass before it runs.
@MainActor private func expiry(of presentation: WidgetPresentation) async throws -> ContinuousClock.Instant {
    for _ in 0..<1000 {
        if presentation.temporaryFields == nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(presentation.temporaryFields == nil)
    return .now
}

@Test @MainActor func theSameTemporaryOutputShowsAgainAfterItExpires() async throws {
    let store = try makeStore(threeWidgets)
    let a = try #require(store.scripts["a"])
    let b = try #require(store.scripts["b"])
    let first = try #require(store.presentations["a"])
    let copied = #"{"text":"","icon":"doc.on.doc","temporary":{"fields":{"text":"Copied"},"duration":0.2}}"#
    try a.accept(output(copied))
    #expect(first.temporaryFields == ["text": "Copied"])
    _ = try await expiry(of: first)
    try b.accept(output(#"{"text":"B"}"#))
    #expect(first.temporaryFields == nil, "Applying a's output again doesn't show it again")
    try a.accept(output(copied))
    #expect(first.temporaryFields == ["text": "Copied"])
    _ = try await expiry(of: first)
}

/// Whether `a`'s temporary output keeps running out on the same schedule after `update` while it shows.
@MainActor private func keepsItsExpiry(after update: (BarStore) throws -> Void) throws -> Bool {
    let store = try makeStore(threeWidgets)
    let a = try #require(store.scripts["a"])
    let first = try #require(store.presentations["a"])
    try a.accept(output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":30}}"#))
    let expiry = try #require(first.expiry)
    try update(store)
    #expect(first.temporaryFields == ["text": "62"])
    return first.expiry == expiry
}

@Test @MainActor func theSameTemporaryOutputWhileItShowsDoesNotStartOver() throws {
    #expect(try keepsItsExpiry { store in
        try store.scripts["a"]?.accept(output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":30}}"#))
    })
    #expect(try !keepsItsExpiry { store in
        try store.scripts["a"]?.accept(output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":31}}"#))
    }, "A different one starts over")
}

@Test @MainActor func anotherWidgetsUpdateDoesNotStartATemporaryOutputOver() throws {
    #expect(try keepsItsExpiry { store in try store.scripts["b"]?.accept(output(#"{"text":"B"}"#)) })
}

@Test func malformedTemporaryOutputIsAnError() throws {
    for json in [#"{"text":"","temporary":{"fields":{"text":"62"},"duration":0}}"#,
                 #"{"text":"","temporary":{"fields":{"text":"62"}}}"#,
                 #"{"text":"","temporary":{"fields":{"text":62},"duration":1}}"#,
                 #"{"text":"","temporary":{"fields":{"text":"62"},"duration":1,"seconds":2}}"#,
                 #"{"text":"","temporary":{"fields":{"text":"62"},"duration":1e30}}"#,
                 #"{"text":"","temporary":{"fields":{"text":"62"},"duration":86400.5}}"#] {
        #expect(throws: DecodingError.self) { try output(json) }
    }
    #expect(try output(#"{"text":"62"}"#).temporary == nil)
    #expect(try output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":1.5}}"#).temporary?.duration == 1.5)
    #expect(try output(#"{"text":"","temporary":{"fields":{"text":"62"},"duration":86400}}"#).temporary?.duration == 86400)
}
