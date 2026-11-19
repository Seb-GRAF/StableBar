import Foundation
import Observation

/// StableBar's crashes from the last 30 days, read from the reports macOS keeps. StableBar stores only which crashes
/// the user has seen or dismissed; the reports stay where macOS wrote them, and macOS removes old ones itself.
@MainActor @Observable
final class CrashReports {
    nonisolated static let window: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let folders: [URL] = {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        return [logs, logs.appending(path: "Retired")]
    }()

    /// Newest first, without the dismissed ones.
    private(set) var reports: [CrashReport] = []
    /// The crashes the user hasn't looked at in Status yet.
    var unseen: [CrashReport] { reports.filter { $0.date > seenThrough } }
    /// The line the bar's menus show while a crash is unseen.
    var note: String? { unseen.isEmpty ? nil : "StableBar Quit Unexpectedly…" }

    private var found: [CrashReport] = []
    private var seenThrough: Date
    private var dismissed: Set<String>
    @ObservationIgnored private let directories: [URL]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date

    init(directories: [URL] = CrashReports.folders, defaults: UserDefaults = .standard,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directories = directories
        self.defaults = defaults
        self.now = now
        seenThrough = defaults.object(forKey: "crashReportsSeenThrough") as? Date ?? .distantPast
        dismissed = Set(defaults.stringArray(forKey: "dismissedCrashReports") ?? [])
    }

    func refresh() async {
        let directories = directories, since = now().addingTimeInterval(-Self.window)
        found = await Task.detached(priority: .utility) { Self.read(directories, since: since) }.value
        let kept = dismissed.intersection(found.map(\.id))
        if kept != dismissed { setDismissed(kept) }
        update()
    }

    func markSeen() {
        guard let newest = reports.first?.date, newest > seenThrough else { return }
        seenThrough = newest
        defaults.set(newest, forKey: "crashReportsSeenThrough")
    }

    /// Hides a crash from the list. The macOS report stays.
    func dismiss(_ report: CrashReport) {
        setDismissed(dismissed.union([report.id]))
        update()
    }

    private func setDismissed(_ ids: Set<String>) {
        dismissed = ids
        defaults.set(ids.sorted(), forKey: "dismissedCrashReports")
    }

    private func update() {
        reports = found.filter { !dismissed.contains($0.id) }
    }

    /// StableBar's crash reports in `directories` since `since`, newest first. A report in both the folder and its
    /// `Retired` folder counts once.
    nonisolated static func read(_ directories: [URL], since: Date) -> [CrashReport] {
        let files = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: .skipsHiddenFiles)) ?? []
        }
        var ids = Set<String>()
        return files
            .filter { $0.lastPathComponent.hasPrefix("StableBar-") && $0.pathExtension == "ips" }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? since) >= since }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { CrashReport(data: $0, file: file) } }
            .filter { $0.date >= since }
            .sorted { $0.date > $1.date }
            .filter { ids.insert($0.id).inserted }
    }
}
