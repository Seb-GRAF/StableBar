import AppKit
import Foundation
import Observation
import Testing
@testable import StableBar

private func widget(_ json: String) throws -> WidgetConfiguration {
    try JSONDecoder().decode(WidgetConfiguration.self, from: Data(json.utf8))
}

private func output(_ json: String) throws -> ScriptOutput {
    try ScriptOutput.read(Data(json.utf8))
}

@Test func everyWidgetTypeReadsItsLabelFromOneFunction() throws {
    let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 41)))
    let note = try widget(#"{"id":"note","type":"text","text":"Ready","icon":"bolt","position":"left"}"#)
    #expect(note.label(output: nil, activeApp: "Finder", date: date)
        == WidgetLabel(text: "Ready", icon: "bolt", fields: ["text": "Ready", "icon": "bolt"]))
    let clock = try widget(#"{"id":"time","type":"clock","format":"HH:mm","position":"right"}"#)
    #expect(clock.label(output: nil, activeApp: nil, date: date) == WidgetLabel(text: "09:41", icon: nil, fields: ["text": "09:41", "icon": ""]))
    let app = try widget(#"{"id":"app","type":"activeApp","position":"left"}"#)
    #expect(app.label(output: nil, activeApp: "Finder", date: date).fields == ["text": "Finder", "icon": ""])
    #expect(app.label(output: nil, activeApp: nil, date: date).text == "Desktop")
    let cpu = try widget(#"{"id":"cpu","type":"script","command":"true","icon":"bolt","position":"right"}"#)
    #expect(try cpu.label(output: output(#"{"text":"12%","icon":"cpu","fields":{"load":"1.2","text":"stale"}}"#), activeApp: nil, date: date)
        == WidgetLabel(text: "12%", icon: "cpu", fields: ["load": "1.2", "text": "12%", "icon": "cpu"]))
    #expect(try cpu.label(output: output("Idle"), activeApp: nil, date: date).icon == "bolt")
    #expect(cpu.label(output: nil, activeApp: nil, date: date).text == "…")
    let power = try widget(#"{"id":"power","type":"battery","position":"right"}"#)
    #expect(try power.label(output: output(#"{"text":"AC","icon":"powerplug"}"#), activeApp: nil, date: date).fields["icon"] == "powerplug")
    let spaces = try widget(#"{"id":"spaces","type":"workspaces","position":"left"}"#)
    #expect(spaces.label(output: nil, activeApp: "Finder", date: date) == WidgetLabel(text: "", icon: nil, fields: [:]))
}

@Test @MainActor func onlyActiveAppLabelsReadTheFrontmostApp() async throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    let note = try widget(#"{"id":"note","type":"text","text":"Ready","position":"left"}"#)
    let app = try widget(#"{"id":"app","type":"activeApp","position":"left"}"#)
    await confirmation("The active-app label changes", expectedCount: 1) { changed in
        await confirmation("The text label stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = store.label(for: app) } onChange: { changed() }
            withObservationTracking { _ = store.label(for: note) } onChange: { invalidated() }
            store.activeApp = NSRunningApplication.current
        }
    }
    _ = NSApplication.shared
    let name = try #require(NSRunningApplication.current.localizedName)
    #expect(name != "Desktop")
    #expect(store.label(for: app).text == name)
}

@Test @MainActor func snapshotsShowWhatEveryWidgetShows() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    try Data(#"""
    {"widgets":[{"id":"note","type":"text","text":"Ready","icon":"bolt","position":"left"},
                {"id":"time","type":"clock","format":"HH:mm","position":"right"},
                {"id":"jobs","type":"script","icon":"bolt","position":"right","interval":null,
                 "command":"printf '{\"text\":\"Busy\",\"icon\":\"hammer\",\"fields\":{\"count\":\"3\"}}'"}]}
    """#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    for _ in 0..<100 {
        if store.scripts["jobs"]?.output.text == "Busy" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard case let .object(note) = try store.snapshot(id: "note"), case let .object(time) = try store.snapshot(id: "time"),
          case let .object(jobs) = try store.snapshot(id: "jobs") else {
        Issue.record("Expected object snapshots")
        return
    }
    #expect(note["text"] == .string("Ready"))
    #expect(note["icon"] == .string("bolt"))
    #expect(note["fields"] == .object(["text": .string("Ready"), "icon": .string("bolt")]))
    #expect(jobs["text"] == .string("Busy"))
    #expect(jobs["icon"] == .string("hammer"))
    #expect(jobs["fields"] == .object(["count": .string("3"), "text": .string("Busy"), "icon": .string("hammer")]))
    #expect(time["icon"] == .null)
    guard case let .string(clock)? = time["text"] else {
        Issue.record("Expected the clock's text")
        return
    }
    #expect(clock.count == 5 && clock.contains(":"))
}

@Test func temporaryFieldsReplaceTheTextAndIconTheyName() {
    let label = WidgetLabel(text: "", icon: "speaker.wave.2", fields: ["text": "", "icon": "speaker.wave.2", "device": "Speakers"])
    #expect(label.overlaid(by: nil) == label)
    #expect(label.overlaid(by: ["text": "62"])
        == WidgetLabel(text: "62", icon: "speaker.wave.2", fields: ["text": "62", "icon": "speaker.wave.2", "device": "Speakers"]))
    #expect(label.overlaid(by: ["text": "62", "icon": ""]).icon == nil)
    #expect(label.overlaid(by: ["device": "Headphones"]).fields["device"] == "Headphones")
}

@Test func clockTimeZoneChangesTheDateAcrossMidnight() throws {
    let date = ISO8601DateFormatter().date(from: "2024-03-01T00:30:00Z")!
    func clock(_ zone: String) throws -> WidgetConfiguration {
        try ConfigurationValue.object(["id": .string("clock"), "type": .string("clock"), "position": .string("right"),
                                        "format": .string("yyyy-MM-dd HH:mm"), "timeZone": .string(zone)]).decoded(WidgetConfiguration.self)
    }
    #expect(try clock("UTC").label(output: nil, activeApp: nil, date: date).text == "2024-03-01 00:30")
    #expect(try clock("America/New_York").label(output: nil, activeApp: nil, date: date).text == "2024-02-29 19:30")
    #expect(throws: (any Error).self) { try clock("Not/A_Time_Zone") }
}

@Test func monthCalendarKeepsLeapDayAndNavigatesAcrossTheYearBoundary() {
    let date = ISO8601DateFormatter().date(from: "2024-03-01T00:30:00Z")!
    let zone = TimeZone(identifier: "America/New_York")!
    let february = ClockMonth(date: date, offset: 0, timeZone: zone)
    let dates = february.days.compactMap { $0 }
    #expect(dates.count == 29)
    #expect(february.calendar.component(.day, from: dates.last!) == 29)
    #expect(february.calendar.isDate(dates.last!, inSameDayAs: date))
    let december = ClockMonth(date: date, offset: -2, timeZone: zone)
    #expect(december.calendar.component(.year, from: december.month) == 2023)
    #expect(december.calendar.component(.month, from: december.month) == 12)
    let march = ClockMonth(date: date, offset: 1, timeZone: zone)
    let marchDays = march.days.compactMap { $0 }
    #expect(marchDays.count == 31)
    #expect(Set(marchDays.map { march.calendar.component(.day, from: $0) }).count == 31)
    #expect(march.calendar.component(.hour, from: marchDays.last!) == 0)
}
