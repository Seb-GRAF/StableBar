import AppKit
import Testing
@testable import StableBar

private let crash = "2026-10-26 14:03:12 +02:00: EXC_BAD_ACCESS (SIGSEGV) in WidgetPopup.toggle(_:widget:defaults:store:anchor:), "
    + "StableBar 0.9.0 (421), StableBar-2026-10-26-140312.ips"

private let example = BugReport(
    version: "0.9.0 (Stable, build 421)", system: "26.6.2 (25G83), arm64", mac: "Mac16,8, Apple M4 Pro",
    displays: ["Built-in Retina Display: built-in, 1512×982 points at 2x, notch, main", "DELL U2720Q: external, 2560×1440 points at 2x"],
    configuration: "/Users/someone/.config/stablebar/config.json, valid, 3 widgets in 2 files",
    theme: "catppuccin (bundled)", packages: ["weather 1.0.1"],
    workspaceTool: "AeroSpace (aerospace CLI client version: 0.19.2), /opt/homebrew/bin/aerospace",
    crashes: [crash],
    live: BugReport.Live(access: ["Accessibility allowed", "Calendars not asked yet"], workspaces: "connected", profiles: ["work"],
                         problems: ["Widget Weather: curl failed reading /Users/someone/.cache/weather"]))

@Test func bugReportListsWhatAnIssueNeeds() {
    #expect(example.markdown == """
    - StableBar: 0.9.0 (Stable, build 421)
    - macOS: 26.6.2 (25G83), arm64
    - Mac: Mac16,8, Apple M4 Pro
    - Displays:
      - Built-in Retina Display: built-in, 1512×982 points at 2x, notch, main
      - DELL U2720Q: external, 2560×1440 points at 2x
    - Configuration: ~/.config/stablebar/config.json, valid, 3 widgets in 2 files
    - Theme: catppuccin (bundled)
    - Packages: weather 1.0.1
    - Workspaces: AeroSpace (aerospace CLI client version: 0.19.2), /opt/homebrew/bin/aerospace, connected
    - Access: Accessibility allowed, Calendars not asked yet
    - Active profiles: work
    - Problems:
      - Widget Weather: curl failed reading ~/.cache/weather
    - Crashes in the last 30 days (Settings → Status → Crashes has each report):
      - \(crash)
    """)
}

@Test func bugReportWithoutARunningBarSaysWhatIsMissing() {
    var report = example
    report.live = nil
    report.packages = []
    report.crashes = []
    let markdown = report.markdown
    #expect(markdown.contains("- Packages: none\n"))
    #expect(markdown.contains("- Workspaces: AeroSpace (aerospace CLI client version: 0.19.2), /opt/homebrew/bin/aerospace\n"))
    #expect(markdown.contains("- Running bar: none with this configuration, so access, connections and problems are missing\n"))
    #expect(!markdown.contains("- Access:"))
    #expect(markdown.hasSuffix("- Crashes in the last 30 days: none"))
    report.barRunning = true
    #expect(report.markdown.contains("- Running bar: didn't answer (an older StableBar?), so access, connections and problems are missing\n"))
    report.barRunning = false

    report.live = BugReport.Live(access: [], workspaces: "", profiles: [], problems: [])
    #expect(report.markdown.contains("- Workspaces: AeroSpace (aerospace CLI client version: 0.19.2), /opt/homebrew/bin/aerospace\n"))
    #expect(report.markdown.contains("- Active profiles: Base configuration\n- Problems: none\n"))
}

private func formFields(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private let bug = Feedback(kind: .bug, title: "The clock vanishes after sleep",
                           answers: ["what-happens": "It's gone.", "steps": "1. Sleep\n2. Wake", "expected": "It's back."], report: example)

@Test func feedbackFillsTheIssueFormOfItsKind() throws {
    let url = try #require(bug.issueURL())
    #expect(url.absoluteString.hasPrefix("https://github.com/Seb-GRAF/StableBar/issues/new?"))
    #expect(formFields(url) == ["template": "bug_report.yml", "title": "The clock vanishes after sleep", "what-happens": "It's gone.",
                                "steps": "1. Sleep\n2. Wake", "expected": "It's back.", "environment": example.markdown])
    #expect(!url.absoluteString.contains("+"))

    var idea = bug
    idea.kind = .idea
    idea.answers = ["problem": "No weather.", "proposal": "A weather widget."]
    #expect(formFields(try #require(idea.issueURL())) == ["template": "feature_request.yml", "title": "The clock vanishes after sleep",
                                            "problem": "No weather.", "proposal": "A weather widget."])
}

@Test func feedbackIssueURLCutsTheReportToStayShort() throws {
    var noisy = bug
    noisy.report?.live?.problems = (0..<300).map { "Widget \($0): " + String(repeating: "e", count: 1000) }
    let url = try #require(noisy.issueURL())
    #expect(url.absoluteString.count <= 8000)
    let fields = formFields(url)
    #expect(fields["what-happens"] == "It's gone.")
    let environment = try #require(fields["environment"])
    #expect(environment.hasPrefix("- StableBar: 0.9.0 (Stable, build 421)\n"))
    #expect(environment.contains("- Problems:\n  - Widget 0: eee"))
    #expect(environment.contains(" more"))
    #expect(noisy.body.contains("Widget 19: "))
    #expect(noisy.body.contains("  - … 280 more"), "A posted issue stays far below GitHub's 65,536 characters")

    var long = bug
    long.answers["what-happens"] = String(repeating: "é ", count: 3000)
    #expect(long.issueURL() == nil, "Answers too long for the address leave the form to Post or Copy")
}

@Test func feedbackSearchesForWhatTheTitleIsAbout() {
    #expect(Feedback(title: "StableBar's clock is off by an hour").titleWords == ["clock", "hour"])
    #expect(Feedback(title: "CPU fan bug").titleWords.isEmpty)
}

@Test func feedbackAsksWhatTheIssueFormsRequire() throws {
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for kind in [Feedback.Kind.bug, .idea] {
        let form = try String(contentsOf: repository.appending(path: ".github/ISSUE_TEMPLATE/\(kind.template)"), encoding: .utf8)
        let fields = form.components(separatedBy: "\n  - type: ").dropFirst().compactMap { block -> (id: String, label: String, hint: String, required: Bool)? in
            func value(_ key: String) -> String? {
                block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("\(key): ") }
                    .map { String($0.dropFirst(key.count + 2)) }
            }
            return value("id").map { ($0, value("label") ?? "", value("description") ?? "", block.contains("required: true")) }
        }
        let asked = fields.filter { $0.required && $0.id != "environment" }
        #expect(asked.map(\.id) == kind.questions.map(\.id), "\(kind.template)")
        #expect(asked.map(\.label) == kind.questions.map(\.label), "\(kind.template)")
        #expect(asked.map(\.hint) == kind.questions.map(\.hint), "\(kind.template)")
        if kind == .bug { #expect(Set(fields.map(\.id)).isSuperset(of: ["environment", "evidence"])) }
    }
}

@Test func feedbackWritesTheIssueAsTheFormDoes() {
    var feedback = bug
    feedback.answers["steps"] = nil
    #expect(feedback.body == """
    ### What happens

    It's gone.

    ### Steps to reproduce

    _No response_

    ### Expected

    It's back.

    ### Environment

    \(example.markdown)
    """)
    #expect(feedback.markdown.hasPrefix("# The clock vanishes after sleep\n\n### What happens\n"))
    #expect(feedback.missing == ["Steps to reproduce"])
    feedback.answers["steps"] = " \n"
    feedback.title = ""
    #expect(feedback.missing == ["Title", "Steps to reproduce"])
    #expect(bug.missing.isEmpty)
}

@Test func liveFactsDecodeFromABarOfAnotherVersion() throws {
    let reply = ConfigurationValue.object(["access": .array([.string("Accessibility allowed")]), "addedLater": .bool(true)])
    #expect(try reply.decoded(BugReport.Live.self) == BugReport.Live(access: ["Accessibility allowed"], workspaces: "", profiles: [], problems: []))
}

@Test func configurationSummaryNamesTheThemePackagesAndWorkspaceSource() throws {
    let fixture = try ThemeGalleryFixture(#"{"workspaceSource":"yabai","widgets":[{"id":"spaces","type":"workspaces","position":"left"},{"id":"clock","type":"clock","position":"right"}]}"#)
    defer { fixture.close() }
    let summary = ConfigurationSummary(url: fixture.url)
    #expect(summary.text.hasPrefix("valid, 2 widgets in "))
    #expect(summary.theme == "Built-in")
    #expect(summary.packages == [])
    #expect(summary.workspaceSource == .yabai)

    try fixture.write(#"{"theme":{"id":"nord","version":"1.2.0"},"packages":[{"id":"weather","version":"1.0.1"},{"id":"off","version":"2.0.0","enabled":false}],"widgets":"broken"}"#, to: fixture.url)
    let broken = ConfigurationSummary(url: fixture.url)
    #expect(broken.text.hasPrefix("invalid: "))
    #expect(broken.theme == "nord 1.2.0")
    #expect(broken.packages == ["weather 1.0.1"])
    #expect(broken.workspaceSource == nil)

    try fixture.write(#"{"theme":{"id":"catppuccin"},"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#, to: fixture.url)
    #expect(ConfigurationSummary(url: fixture.url).theme == "catppuccin (bundled)")
    #expect(ConfigurationSummary(url: fixture.url.deletingLastPathComponent().appending(path: "missing.json")).text
        == "no file yet; StableBar creates it from the starter configuration at first launch")
}

@Test func workspaceToolNamesItsVersionAndPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let aerospace = directory.appending(path: "aerospace")
    try Data("#!/bin/sh\necho 'aerospace CLI client version: 0.19.2'\necho 'aerospace server version: 0.19.2'\n".utf8).write(to: aerospace)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: aerospace.path)
    #expect(await BugReport.workspaceTool(.aerospace, path: directory.path) == "AeroSpace (aerospace CLI client version: 0.19.2), \(aerospace.path)")
    #expect(await BugReport.workspaceTool(.yabai, path: directory.path) == "yabai, not found on PATH")
    #expect(await BugReport.workspaceTool(.spaces, path: directory.path) == "macOS Spaces")
    #expect(await BugReport.workspaceTool(nil, path: directory.path) == "not used")
}

@Test @MainActor func runningBarAnswersTheReportRequestWithWhatOnlyItKnows() throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    store.configurationError = "widgets.3.style: The data couldn't be read"
    store.configurationWarning = "Written for StableBar 9.0"
    let live = store.liveReport()
    #expect(live.problems == ["widgets.3.style: The data couldn't be read", "Written for StableBar 9.0"])
    #expect(live.access.map { $0.split(separator: " ").first.map(String.init) } == ["Accessibility", "Calendars"])
    #expect(live.workspaces == "")
    #expect(live.profiles == [])
    #expect(try store.handle(RuntimeRequest(action: .report)).decoded(BugReport.Live.self) == live)
}

@Test @MainActor func gatheredReportDescribesThisMacAndTheConfiguration() async throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    defer { fixture.close() }
    let report = await BugReport.gather(configuration: fixture.url, live: nil, path: "")
    #expect(!report.version.isEmpty)
    #expect(report.system.contains("("))
    #expect(report.configuration.hasPrefix("\(fixture.url.path), valid, 1 widget in "))
    #expect(report.theme == "Built-in")
    #expect(report.workspaceTool == "not used")
    #expect(report.displays.count == NSScreen.screens.count)
    #expect(report.live == nil)
}

@Test func reportCommandParsesWithAndWithoutAConfiguration() throws {
    guard case let .report(url) = try LaunchCommand(arguments: ["--report"]) else { Issue.record("Expected report"); return }
    #expect(url == LaunchCommand.configurationURL)
    guard case let .report(custom) = try LaunchCommand(arguments: ["--config", "/tmp/custom.json", "--report"]) else {
        Issue.record("Expected report"); return
    }
    #expect(custom.path == "/tmp/custom.json")
    for arguments in [["--report", "extra"], ["--report", "--persist"]] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
    #expect(LaunchCommand.usage.contains("StableBar [--config PATH] --report\n"))
}
