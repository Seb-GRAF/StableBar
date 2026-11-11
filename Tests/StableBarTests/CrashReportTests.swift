import AppKit
import Testing
@testable import StableBar

/// A crash report in the format macOS writes to ~/Library/Logs/DiagnosticReports: a JSON header line, then a JSON body.
private func crashReport(app: String = "StableBar", bugType: String = "309", incident: String = "4F1C2A9E", version: String = "0.9.0",
                         captured: String = "2026-10-26 14:03:12.1234 +0200", frames: [[String: Any]]? = nil,
                         message: String? = nil,
                         termination: [String: Any] = ["namespace": "SIGNAL", "indicator": "Segmentation fault: 11", "code": 11]) -> Data {
    let header: [String: Any] = [
        "app_name": app, "name": app, "bug_type": bugType, "incident_id": incident, "timestamp": "2026-10-26 14:03:13.00 +0200",
        "app_version": version, "build_version": version.isEmpty ? "" : "421", "os_version": "macOS 26.6.2 (25G83)", "bundleID": "org.stablebar.app",
        "share_with_app_devs": 0
    ]
    let body: [String: Any] = [
        "captureTime": captured, "incident": incident, "modelCode": "Mac16,1",
        "procPath": "/Users/someone/Applications/StableBar.app/Contents/MacOS/StableBar",
        "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000010"],
        "termination": termination,
        "asi": ["libswiftCore.dylib": [message ?? "/Users/someone/StableBar/Sources/StableBar/WidgetPopup.swift:50: Fatal error: Unexpectedly found nil"]],
        "faultingThread": 1,
        "threads": [
            ["id": 1, "queue": "com.apple.main-thread", "frames": [["imageOffset": 8, "symbol": "main", "symbolLocation": 4, "imageIndex": 0]]],
            ["id": 2, "triggered": true, "name": "Worker", "queue": "com.apple.root.default-qos", "frames": frames ?? [
                ["imageOffset": 4096, "symbol": "_assertionFailure(_:_:file:line:flags:)", "symbolLocation": 276, "imageIndex": 1],
                ["imageOffset": 6192548, "symbol": "WidgetPopup.toggle(_:widget:defaults:store:anchor:)", "symbolLocation": 1308, "imageIndex": 0,
                 "sourceFile": "WidgetPopup.swift", "sourceLine": 50],
                ["imageOffset": 16, "imageIndex": 2]
            ]]
        ],
        "usedImages": [
            ["name": "StableBar", "path": "/Users/USER/*/StableBar.app/Contents/MacOS/StableBar"],
            ["name": "libswiftCore.dylib", "path": "/usr/lib/swift/libswiftCore.dylib"],
            ["name": "libfoo.dylib", "path": "/usr/lib/libfoo.dylib"]
        ]
    ]
    let json = { (value: [String: Any]) in try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    return json(header) + Data("\n".utf8) + json(body)
}

private let reportFile = URL(filePath: "/Users/someone/Library/Logs/DiagnosticReports/StableBar-2026-10-26-140312.ips")

@Test func crashReportReadsTheCrashFromAnIPSFile() throws {
    let report = try #require(CrashReport(data: crashReport(), file: reportFile))
    #expect(report.id == "4F1C2A9E")
    #expect(report.file == reportFile)
    #expect(report.date == ISO8601DateFormatter().date(from: "2026-10-26T12:03:12Z"))
    #expect(report.version == "0.9.0")
    #expect(report.build == "421")
    #expect(report.system == "macOS 26.6.2 (25G83)")
    #expect(report.model == "Mac16,1")
    #expect(report.exception == "EXC_BAD_ACCESS (SIGSEGV)")
    #expect(report.subtype == "KERN_INVALID_ADDRESS at 0x0000000000000010")
    #expect(report.termination == "Segmentation fault: 11")
    #expect(report.message == "~/StableBar/Sources/StableBar/WidgetPopup.swift:50: Fatal error: Unexpectedly found nil")
    #expect(report.thread == "Thread 1 (Worker, com.apple.root.default-qos)")
    #expect(report.frames.map(\.text) == [
        "libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:) + 276",
        "StableBar  WidgetPopup.toggle(_:widget:defaults:store:anchor:) + 1308 (WidgetPopup.swift:50)",
        "libfoo.dylib + 0x10"
    ])
    #expect(report.location == "WidgetPopup.toggle(_:widget:defaults:store:anchor:)")
    #expect(report.summary.hasPrefix("2026-10-26 "))
    #expect(report.summary.hasSuffix(": EXC_BAD_ACCESS (SIGSEGV) in WidgetPopup.toggle(_:widget:defaults:store:anchor:), StableBar 0.9.0 (421), StableBar-2026-10-26-140312.ips"))
}

@Test func crashReportIgnoresOtherReportsAndPartialFiles() {
    #expect(CrashReport(data: crashReport(bugType: "288"), file: reportFile) == nil)
    #expect(CrashReport(data: crashReport(app: "StableBarPackageTests"), file: reportFile) == nil)
    let complete = crashReport()
    #expect(CrashReport(data: complete.prefix(complete.count / 2), file: reportFile) == nil)
    #expect(CrashReport(data: Data("not a report".utf8), file: reportFile) == nil)
}

@Test func crashReportSkipsLaunchesThatDyldStoppedBeforeStableBarRan() {
    let missingFramework: [String: Any] = [
        "namespace": "DYLD", "indicator": "Library missing", "code": 1, "details": ["(terminated at launch; ignore backtrace)"],
        "reasons": ["Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle"]
    ]
    #expect(CrashReport(data: crashReport(version: "", termination: missingFramework), file: reportFile) == nil)
    #expect(CrashReport(data: crashReport(termination: missingFramework), file: reportFile) == nil)
}

@Test func crashReportMarkdownAndIssueURLFitGitHub() throws {
    let report = try #require(CrashReport(data: crashReport(), file: reportFile))
    let markdown = report.markdown
    for line in ["StableBar quit unexpectedly on 2026-10-26", "- StableBar: 0.9.0 (421)", "- macOS: macOS 26.6.2 (25G83)",
                 "- Mac: Mac16,1", "- Exception: EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0000000000000010",
                 "- Termination: Segmentation fault: 11",
                 "- Report: ~/Library/Logs/DiagnosticReports/StableBar-2026-10-26-140312.ips",
                 "Crashed thread: Thread 1 (Worker, com.apple.root.default-qos)",
                 "0  libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:) + 276",
                 "1  StableBar           WidgetPopup.toggle(_:widget:defaults:store:anchor:) + 1308 (WidgetPopup.swift:50)",
                 "2  libfoo.dylib + 0x10"] {
        #expect(markdown.contains(line), "Missing \(line)")
    }
    #expect(!markdown.contains("/Users/"))

    let url = report.issueURL()
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "github.com")
    #expect(components.path == "/Seb-GRAF/StableBar/issues/new")
    let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(fields["template"] == "bug_report.yml")
    #expect(fields["title"] == "StableBar quit unexpectedly: EXC_BAD_ACCESS in WidgetPopup.toggle(_:widget:defaults:store:anchor:)")
    #expect(fields["what-happens"]?.hasPrefix("StableBar quit unexpectedly on 2026-10-26") == true)
    #expect(fields["environment"]?.hasPrefix("StableBar: 0.9.0 (421)\nmacOS: macOS 26.6.2 (25G83)\n") == true)
    #expect(fields["evidence"] == markdown)
    #expect(!url.absoluteString.contains("+"), "A literal + reads as a space in a query")
}

@Test func crashReportIssueURLStaysShortForDeepStacksAndLongMessages() throws {
    let frames = (0..<2000).map { ["imageOffset": $0, "symbol": "recurse(\($0))", "symbolLocation": 12, "imageIndex": 0] as [String: Any] }
    let report = try #require(CrashReport(data: crashReport(frames: frames, message: String(repeating: "x", count: 20_000)), file: reportFile))
    let url = report.issueURL()
    #expect(url.absoluteString.count <= 8000)
    let evidence = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "evidence" }?.value
    #expect(evidence?.contains("- Exception: EXC_BAD_ACCESS (SIGSEGV)") == true)
    #expect(evidence?.contains("StableBar  recurse(0) + 12") == true)
    #expect(evidence?.contains("more frames in the report") == true)
    #expect(report.markdown.contains("\n0   StableBar  recurse(0) + 12\n"))
    #expect(report.markdown.contains("\n59  StableBar  recurse(59) + 12\n… 1940 more frames in the report\n"))
}

@Test func crashReportIssueURLStaysShortForHugeSwiftSymbols() throws {
    let symbol = "specialized " + String(repeating: "Generic<Nested<Value>>.", count: 120) + "body.getter"
    let report = try #require(CrashReport(data: crashReport(frames: [
        ["imageOffset": 1, "symbol": symbol, "symbolLocation": 8, "imageIndex": 0],
        ["imageOffset": 2, "symbol": symbol, "symbolLocation": 9, "imageIndex": 0]
    ]), file: reportFile))
    #expect(symbol.count > 2700)
    let url = report.issueURL()
    #expect(url.absoluteString.count <= 8000)
    let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(try #require(fields["title"]).count <= 256)
    #expect(fields["title"]?.hasPrefix("StableBar quit unexpectedly: EXC_BAD_ACCESS in specialized Generic<Nested<Value>>.") == true)
    #expect(fields["evidence"]?.contains("- Exception: EXC_BAD_ACCESS (SIGSEGV)") == true)
    #expect(report.markdown.contains(symbol), "The copied report keeps whole symbols")
}

@Test func crashReportOfABuildWithoutAVersionCallsItADevelopmentBuild() throws {
    let report = try #require(CrashReport(data: crashReport(version: ""), file: reportFile))
    #expect(report.version == nil)
    #expect(report.build == nil)
    #expect(report.release == "development build")
    #expect(report.markdown.contains("- StableBar: development build\n"))
    #expect(report.summary.contains(", StableBar development build, StableBar-2026-10-26-140312.ips"))
    let environment = URLComponents(url: report.issueURL(), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "environment" }?.value
    #expect(environment?.hasPrefix("StableBar: development build\n") == true)
}

private let october27 = ISO8601DateFormatter().date(from: "2026-10-27T00:00:00Z")!

private func reportFolders() throws -> (folders: [URL], write: (String, Data, Bool) throws -> Void, remove: () -> Void) {
    let logs = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)")
    let retired = logs.appending(path: "Retired")
    try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
    return ([logs, retired], { name, data, isRetired in try data.write(to: (isRetired ? retired : logs).appending(path: name)) },
            { try? FileManager.default.removeItem(at: logs) })
}

@Test @MainActor func crashReportsListStableBarCrashesFromTheLastThirtyDays() async throws {
    let (folders, write, remove) = try reportFolders()
    defer { remove() }
    try write("StableBar-2026-10-26-140312.ips", crashReport(incident: "A"), false)
    try write("StableBar-2026-10-26-140312.ips", crashReport(incident: "A"), true)
    try write("StableBar-2026-10-20-090000.ips", crashReport(incident: "B", captured: "2026-10-20 09:00:00.00 +0200"), true)
    try write("StableBar-2026-09-01-090000.ips", crashReport(incident: "C", captured: "2026-09-01 09:00:00.00 +0200"), false)
    try write("StableBarPackageTests-2026-10-26-140312.ips", crashReport(app: "StableBarPackageTests", incident: "D"), false)
    try write("StableBar-2026-10-25-100000.ips", crashReport(bugType: "288", incident: "E"), false)
    try write("StableBar-2026-10-25-110000.txt", crashReport(incident: "F"), false)
    let defaults = UserDefaults(suiteName: "crash-\(UUID().uuidString)")!
    let crashes = CrashReports(directories: folders, defaults: defaults, now: { october27 })
    #expect(crashes.reports.isEmpty)
    await crashes.refresh()
    #expect(crashes.reports.map(\.id) == ["A", "B"])
}

@Test @MainActor func crashReportsRememberSeenAndDismissedCrashes() async throws {
    let (folders, write, remove) = try reportFolders()
    defer { remove() }
    let suite = "crash-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try write("StableBar-2026-10-20-090000.ips", crashReport(incident: "B", captured: "2026-10-20 09:00:00.00 +0200"), false)
    try write("StableBar-2026-10-26-140312.ips", crashReport(incident: "A"), false)

    let first = CrashReports(directories: folders, defaults: defaults, now: { october27 })
    #expect(first.note == nil)
    await first.refresh()
    #expect(first.unseen.map(\.id) == ["A", "B"])
    #expect(first.note == "StableBar Quit Unexpectedly…")
    first.markSeen()
    #expect(first.unseen.isEmpty)
    #expect(first.note == nil)

    let second = CrashReports(directories: folders, defaults: defaults, now: { october27 })
    await second.refresh()
    #expect(second.unseen.isEmpty)
    try write("StableBar-2026-10-26-200000.ips", crashReport(incident: "N", captured: "2026-10-26 20:00:00.00 +0200"), false)
    await second.refresh()
    #expect(second.unseen.map(\.id) == ["N"])
    second.dismiss(try #require(second.reports.first))
    #expect(second.reports.map(\.id) == ["A", "B"])
    #expect(second.unseen.isEmpty)

    let third = CrashReports(directories: folders, defaults: defaults, now: { october27 })
    await third.refresh()
    #expect(third.reports.map(\.id) == ["A", "B"])
    try FileManager.default.removeItem(at: folders[0].appending(path: "StableBar-2026-10-26-200000.ips"))
    await third.refresh()
    #expect(defaults.stringArray(forKey: "dismissedCrashReports") == [])
}

@Test @MainActor func showingCrashesOpensStatusOnThem() throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"crashes","type":"clock","position":"right"}]}"#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let editor = ConfigurationEditor(store: store)
    editor.troubleshoot("crashes")
    #expect(editor.section == .diagnostics)
    #expect(editor.diagnosticSelection == .widget("crashes"))
    editor.section = .general
    editor.showCrashes()
    #expect(editor.section == .diagnostics)
    #expect(editor.diagnosticSelection == .crashes)
    #expect(SettingsSearchResult.allCases.filter { $0.matches("crash") } == [.status])
    #expect(SettingsSearchResult.status.matches("quit unexpectedly"))
}

@Test @MainActor func statusMenuMentionsANewCrashUntilItIsSeen() async throws {
    let (folders, write, remove) = try reportFolders()
    defer { remove() }
    let suite = "crash-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let store = BarStore(configurationURL: fixture.url)
    defer { store.stop() }
    store.crashReports = CrashReports(directories: folders, defaults: defaults, now: { october27 })
    let menu = NSMenu()
    let delegate = AppDelegate(store: store)
    delegate.menuWillOpen(menu)
    #expect(!menu.items.contains { $0.title == "StableBar Quit Unexpectedly…" })
    try write("StableBar-2026-10-26-140312.ips", crashReport(incident: "A"), false)
    await store.crashReports.refresh()
    delegate.menuWillOpen(menu)
    let item = try #require(menu.items.first { $0.title == "StableBar Quit Unexpectedly…" })
    #expect(item.target === delegate)
    #expect(item.action != nil)
    store.crashReports.markSeen()
    delegate.menuWillOpen(menu)
    #expect(!menu.items.contains { $0.title == "StableBar Quit Unexpectedly…" })
}
