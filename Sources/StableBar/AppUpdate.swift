import AppKit
import Sparkle
import SwiftUI

/// Shows Sparkle's updates in the bar instead of Sparkle's windows: a tile at the bar's right end while
/// an update is available, whose popup downloads it and then relaunches StableBar to install it.
@MainActor @Observable
final class AppUpdate: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Stage: CaseIterable {
        case available, downloading, extracting, ready, installing
    }

    private enum DownloadCheck {
        case dismissing, checking
    }

    nonisolated static let widgetID = "stablebar.update"
    static let popup: PopupConfiguration = {
        var popup = PopupConfiguration(height: 420, style: WidgetStyle(paddingHorizontal: 14, paddingVertical: 14, spacing: 10),
                                       layout: PopupBlock(content: .appUpdate))
        popup.animation = WidgetAnimation()
        return popup
    }()

    @ObservationIgnored private(set) var updater: SPUUpdater!
    /// The version on offer, nil when there is no update.
    private(set) var version: String?
    private(set) var changes: [String] = []
    private(set) var stage = Stage.available
    private(set) var progress = 0.0
    private var downloadCheck: DownloadCheck?
    @ObservationIgnored private var reply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var foundUpdate = false
    let starRequest: StarRequest
    /// The version the popup lists changes since, and where it reads their release notes.
    @ObservationIgnored private(set) var installedVersion = AppVersion().version ?? ""
    @ObservationIgnored private(set) var loadHistory: @Sendable (_ installed: String, _ offered: String) async throws -> [UpdateRelease] = {
        try await UpdateRelease.load(after: $0, through: $1)
    }

    init(starRequest: StarRequest = StarRequest(),
         makeUpdater: (any SPUUserDriver, any SPUUpdaterDelegate) -> SPUUpdater = { driver, delegate in
        SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
    }) {
        self.starRequest = starRequest
        super.init()
        updater = makeUpdater(self, self)
    }

    /// StableBar 0.11.0 offered to 0.10.0, with its release notes and the star request in `star`. It checks, loads
    /// and saves nothing: the scenes' sample.
    static func sample(star: StarRequest.State = .repository) -> AppUpdate {
        let update = AppUpdate(starRequest: StarRequest(sample: star))
        let changes = ["show keyboard shortcuts in app menus",
                       "open the Apple menu, System Settings or the lock screen from the Apple logo",
                       "use the lighthouse logo across the app and website"]
        update.installedVersion = "0.10.0"
        update.version = "0.11.0"
        update.changes = changes
        update.loadHistory = { _, _ in
            [UpdateRelease(tagName: "v0.11.0", body: changes.map { "* \($0)" }.joined(separator: "\n"),
                           publishedAt: Date(timeIntervalSinceReferenceDate: 815_000_000))]
        }
        return update
    }

    func start() throws {
        if UserDefaults.standard.string(forKey: "updateTrack") == nil {
            UserDefaults.standard.set(AppVersion().channel == .beta ? "beta" : "stable", forKey: "updateTrack")
        }
        try updater.start()
        let timer = Timer(fire: Date(timeIntervalSinceNow: 15), interval: 4 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdateInformation() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    func checkForUpdateInformation() {
        guard updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return }
        foundUpdate = false
        updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundUpdate = true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if downloadCheck == .dismissing {
            downloadCheck = .checking
            updater.checkForUpdates()
            return
        }
        downloadCheck = nil
        guard updateCheck == .updateInformation, error == nil, foundUpdate, updater.automaticallyChecksForUpdates else { return }
        foundUpdate = false
        updater.checkForUpdatesInBackground()
    }

    /// The tile the bar adds at its right end while there's an update.
    var widget: WidgetConfiguration? {
        version == nil ? nil : Self.tile(stage)
    }

    static func tile(_ stage: Stage) -> WidgetConfiguration {
        let (icon, tooltip) = switch stage {
        case .available: ("arrow.down.circle.fill", "Download update")
        case .downloading: ("arrow.down.circle.fill", "Downloading update…")
        case .extracting: ("arrow.down.circle.fill", "Preparing update…")
        case .ready: ("arrow.triangle.2.circlepath.circle.fill", "Install and relaunch")
        case .installing: ("arrow.triangle.2.circlepath.circle.fill", "Installing update…")
        }
        return try! ConfigurationValue.object([
            "id": .string(widgetID), "position": .string("right"), "type": .string("text"),
            "text": .string(""), "icon": .string(icon), "tooltip": .string(tooltip), "overflow": .string("never"),
            "transition": .string("fade")
        ]).decoded(WidgetConfiguration.self)
    }

    var action: String {
        if downloadCheck != nil { return "Checking…" }
        return switch stage {
        case .available: "Download"
        case .downloading: "Downloading…"
        case .extracting: "Preparing…"
        case .ready: "Install and Relaunch"
        case .installing: "Installing…"
        }
    }

    var canProceed: Bool { downloadCheck == nil && (stage == .available || stage == .ready) }

    /// Downloads the update, or installs it and relaunches StableBar once it's downloaded.
    func proceed() {
        let reply = reply
        self.reply = nil
        if stage == .available {
            downloadCheck = .dismissing
            reply?(.dismiss)
        } else {
            reply?(.install)
        }
    }

    @objc func checkForUpdates() { updater.checkForUpdates() }

    /// The changes a release's notes list: their bullet points up to GitHub's list of new contributors,
    /// without the author and pull request that GitHub's generated notes end each one with.
    static func changes(in notes: String) -> [String] {
        notes.split(whereSeparator: \.isNewline)
            .prefix { !$0.hasPrefix("## New Contributors") }
            .filter { $0.hasPrefix("* ") || $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).replacing(/\s+by @\S+ in \S+$/, with: "") }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.string(forKey: "updateTrack") == "beta" ? ["beta"] : []
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        changes = Self.changes(in: appcastItem.itemDescription ?? "")
        stage = state.stage == .notDownloaded ? .available : .ready
        if downloadCheck == .checking {
            downloadCheck = nil
            stage = .downloading
            reply(.install)
        } else {
            self.reply = reply
            Task { await starRequest.refresh() }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        alert(error, then: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        alert(error, then: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        stage = .downloading
        progress = 0
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        progress = Double(receivedLength) / Double(expectedLength)
    }

    func showDownloadDidStartExtractingUpdate() {
        stage = .extracting
        progress = 0
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        stage = .ready
        self.reply = reply
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        stage = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        reply = nil
        if downloadCheck == .dismissing { return }
        version = nil
        downloadCheck = nil
    }

    private func alert(_ error: any Error, then acknowledgement: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
        acknowledgement()
    }
}

/// The update tile's popup: what's new in the version on offer and the button that downloads it, then
/// installs it, in the theme's popup style.
struct UpdateDetails: View {
    let update: AppUpdate
    let version: String
    let appearance: WidgetAppearance
    @State private var releases: [UpdateRelease] = []
    @State private var notesError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("StableBar \(version)").fontWeight(.semibold)
                Text("You have \(update.installedVersion)").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if releases.isEmpty {
                        ReleaseChanges(version: version, changes: update.changes)
                        if notesError.isEmpty {
                            ProgressView("Loading release history…").controlSize(.small)
                        } else {
                            Text(notesError).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(releases, id: \.tagName) { release in
                            ReleaseChanges(version: String(release.tagName.dropFirst()),
                                           changes: AppUpdate.changes(in: release.body ?? ""))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(destination: URL(string: "https://github.com/Seb-GRAF/StableBar/compare/v\(update.installedVersion)...v\(version)")!) {
                HStack(spacing: 3) {
                    Text("View all changes on GitHub")
                    Image(systemName: "arrow.up.right")
                }
            }
            .foregroundStyle(.secondary)
            Divider()
            if update.starRequest.isShown {
                StarRequestLine(request: update.starRequest, appearance: appearance)
            }
            VStack(spacing: 8) {
                if update.stage == .downloading || update.stage == .extracting {
                    HStack {
                        Text(update.action)
                        Spacer()
                        Text(update.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ProgressView(value: update.progress)
                        .tint(appearance.accent)
                }
                Button(action: update.proceed) {
                    Text(update.action)
                        .fontWeight(.semibold)
                        .foregroundStyle(appearance.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(appearance.accent, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!update.canProceed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AppUpdate.popup.height! - appearance.paddingVertical * 2)
        .task(id: version) {
            releases = []
            notesError = ""
            do {
                let history = try await update.loadHistory(update.installedVersion, version)
                try Task.checkCancellation()
                releases = history
            } catch {
                if !Task.isCancelled { notesError = "Earlier release notes could not be loaded." }
            }
        }
        .task { await update.starRequest.refresh() }
    }
}

private struct ReleaseChanges: View {
    let version: String
    let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes in \(version)").fontWeight(.semibold)
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text((try? AttributedString(markdown: change)) ?? AttributedString(change))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
