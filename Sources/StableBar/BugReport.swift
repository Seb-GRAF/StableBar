import AppKit
@preconcurrency import ApplicationServices
import EventKit
import Foundation

/// What Copy bug report in Status and `StableBar --report` give to paste into an issue: versions, this Mac, the
/// configuration's theme and packages, StableBar's recent crashes and, from a running bar, its access, connection and
/// problems. Home folders become `~`. Configuration values aren't included, so secrets stay out.
struct BugReport: Equatable, Sendable {
    /// What only a running bar knows. A report made while no bar runs with the configuration goes without it.
    struct Live: Codable, Equatable, Sendable {
        var access: [String]
        /// The workspace connection, or empty when no widget shows workspaces.
        var workspaces: String
        var profiles: [String]
        var problems: [String]
    }

    var version: String
    var system: String
    var mac: String
    var displays: [String]
    var configuration: String
    var theme: String
    var packages: [String]
    var workspaceTool: String
    var crashes: [String]
    var live: Live?
    /// Whether a bar runs with the configuration even though `live` is missing, as when it predates the report request.
    var barRunning = false

    var markdown: String { markdown(listLimit: .max, lineLimit: .max) }

    /// The report with at most `listLimit` problems and crashes and `lineLimit` characters in each.
    func markdown(listLimit: Int, lineLimit: Int) -> String {
        func list(_ title: String, _ items: [String]) -> [String] {
            guard !items.isEmpty else { return ["- \(title): none"] }
            let shown = items.prefix(listLimit).map { "  - " + ($0.count > lineLimit ? String($0.prefix(lineLimit)) + "…" : $0) }
            return ["- \(title):"] + shown + (items.count > shown.count ? ["  - … \(items.count - shown.count) more"] : [])
        }
        var lines = ["- StableBar: \(version)", "- macOS: \(system)", "- Mac: \(mac)"]
        lines += list("Displays", displays)
        lines.append("- Configuration: \(configuration)")
        lines.append("- Theme: \(theme)")
        lines.append("- Packages: \(packages.isEmpty ? "none" : packages.joined(separator: ", "))")
        if let live {
            lines.append("- Workspaces: \(workspaceTool)\(live.workspaces.isEmpty ? "" : ", \(live.workspaces)")")
            if !live.access.isEmpty { lines.append("- Access: \(live.access.joined(separator: ", "))") }
            lines.append("- Active profiles: \(live.profiles.isEmpty ? "Base configuration" : live.profiles.joined(separator: ", "))")
            lines += list("Problems", live.problems)
        } else {
            lines.append("- Workspaces: \(workspaceTool)")
            lines.append("- Running bar: \(barRunning ? "didn't answer (an older StableBar?)" : "none with this configuration"), "
                         + "so access, connections and problems are missing")
        }
        lines += list(crashes.isEmpty ? "Crashes in the last 30 days" : "Crashes in the last 30 days (Settings → Status → Crashes has each report)",
                      crashes)
        return CrashReport.redacted(lines.joined(separator: "\n"))
    }

    /// Gathers everything but `live` from this Mac, the configuration file and the crash reports.
    @MainActor static func gather(configuration url: URL, live: Live?, barRunning: Bool = false, path: String) async -> BugReport {
        let summary = await Task.detached(priority: .userInitiated) { ConfigurationSummary(url: url) }.value
        let crashes = await Task.detached(priority: .userInitiated) {
            CrashReports.read(CrashReports.folders, since: Date().addingTimeInterval(-CrashReports.window)).map(\.summary)
        }.value
        return BugReport(version: MacFacts.version, system: MacFacts.system, mac: MacFacts.mac, displays: MacFacts.displays,
                         configuration: "\(url.path), \(summary.text)", theme: summary.theme, packages: summary.packages,
                         workspaceTool: await workspaceTool(summary.workspaceSource, path: path), crashes: crashes, live: live,
                         barRunning: barRunning)
    }

    /// The workspace manager the configuration's widgets read, with its version and where it is.
    static func workspaceTool(_ source: WorkspaceSource?, path: String) async -> String {
        guard let source else { return "not used" }
        guard source != .spaces else { return "macOS Spaces" }
        guard let executable = source.executable(path: path) else { return "\(source.title), not found on PATH" }
        let output = try? await runCommand(executable, arguments: ["--version"], timeout: 5)
        let version = output.flatMap { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isNewline).first }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return "\(source.title)\(version.map { " (\($0))" } ?? ""), \(executable)"
    }

    /// Accessibility and Calendars, as this process has them.
    static func access() -> [String] {
        let calendars = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "allowed"
        case .writeOnly: "write only"
        case .denied: "not allowed"
        case .restricted: "restricted by this Mac"
        default: "not asked yet"
        }
        return ["Accessibility \(AXIsProcessTrusted() ? "allowed" : "not allowed")", "Calendars \(calendars)"]
    }
}

extension BugReport.Live {
    /// A bar of another version may send fewer or more facts; missing ones read as empty.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        access = try values.decodeIfPresent([String].self, forKey: .access) ?? []
        workspaces = try values.decodeIfPresent(String.self, forKey: .workspaces) ?? ""
        profiles = try values.decodeIfPresent([String].self, forKey: .profiles) ?? []
        problems = try values.decodeIfPresent([String].self, forKey: .problems) ?? []
    }
}

/// What a configuration file amounts to, read without starting its scripts.
struct ConfigurationSummary: Sendable {
    /// Such as `valid, 3 widgets in 2 files` or `invalid: …`.
    var text: String
    var theme = "unknown"
    /// Turned-on packages with their versions.
    var packages: [String] = []
    /// The workspace manager, when a widget shows workspaces.
    var workspaceSource: WorkspaceSource?

    init(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            text = "no file yet; StableBar creates it from the starter configuration at first launch"
            theme = "Built-in"
            return
        }
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
        var loader = ConfigurationLoader()
        var document: [String: ConfigurationValue]?
        do {
            let configuration = try loader.load(url)
            text = "valid, \(count(configuration.widgets.count, "widget")) in \(count(loader.dependencies.count, "file"))"
                + (loader.newerVersionWarning.map { "; \($0)" } ?? "")
            document = loader.document
            workspaceSource = configuration.widgets.contains { $0.content == .workspaces } ? configuration.workspaceSource : nil
        } catch {
            text = "invalid: \(errorMessage(error))"
            // An invalid file still names its theme and packages.
            document = try? JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
        }
        guard let document else { return }
        let selection = try? document["theme"]?.decoded(WidgetPackageSelection.self)
        theme = selection.flatMap { $0.enabled ? $0 : nil }.map { "\($0.id) \($0.version ?? "(bundled)")" } ?? "Built-in"
        packages = ((try? document["packages"]?.decoded([WidgetPackageSelection].self)) ?? [])
            .filter(\.enabled).map { [$0.id, $0.version].compactMap { $0 }.joined(separator: " ") }
    }
}

/// Facts about this Mac and this copy of StableBar, shared by bug reports and `StableBar triage`.
enum MacFacts {
    static var version: String {
        let version = AppVersion()
        return version.channel == .development ? version.version.map { "development build \($0)" } ?? "development build"
            : "\(version.version ?? "unknown") (\(version.channel.rawValue)\(version.build.map { ", build \($0)" } ?? ""))"
    }

    static var system: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion) (\(sysctl("kern.osversion"))), \(sysctl("hw.machine"))"
    }

    static var mac: String { "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))" }

    /// Each display: built-in or external, size, scale, notch and which is main.
    @MainActor static var displays: [String] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            var details = [number.map { CGDisplayIsBuiltin($0) != 0 } == true ? "built-in" : "external",
                           "\(Int(screen.frame.width))×\(Int(screen.frame.height)) points at \(screen.backingScaleFactor.formatted())x"]
            if screen.safeAreaInsets.top > 0 { details.append("notch") }
            if screen == NSScreen.screens.first { details.append("main") }
            return "\(screen.localizedName): \(details.joined(separator: ", "))"
        }
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }
}
