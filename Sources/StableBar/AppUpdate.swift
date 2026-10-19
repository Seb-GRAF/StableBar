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

    static let widgetID = "stablebar.update"
    static let popup = PopupConfiguration(style: WidgetStyle(paddingHorizontal: 14, paddingVertical: 14, spacing: 10),
                                          layout: PopupBlock(content: .appUpdate))

    @ObservationIgnored private(set) var updater: SPUUpdater!
    /// The version on offer, nil when there is no update.
    private(set) var version: String?
    private(set) var changes: [String] = []
    private(set) var releaseURL: URL?
    private(set) var stage = Stage.available
    private(set) var progress = 0.0
    @ObservationIgnored private var reply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0

    override init() {
        super.init()
        if UserDefaults.standard.string(forKey: "updateTrack") == nil {
            UserDefaults.standard.set(AppVersion().channel == .beta ? "beta" : "stable", forKey: "updateTrack")
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    }

    /// The tile the bar adds at its right end while there's an update.
    var widget: WidgetConfiguration? {
        version == nil ? nil : Self.tile(stage)
    }

    static func tile(_ stage: Stage) -> WidgetConfiguration {
        let (icon, text) = switch stage {
        case .available: ("arrow.down.circle.fill", "Update")
        case .downloading, .extracting: ("arrow.down.circle", "Downloading…")
        case .ready: ("arrow.clockwise.circle.fill", "Relaunch to update")
        case .installing: ("arrow.clockwise.circle", "Installing…")
        }
        return try! ConfigurationValue.object([
            "id": .string(widgetID), "position": .string("right"), "type": .string("text"),
            "text": .string(text), "icon": .string(icon), "overflow": .string("never")
        ]).decoded(WidgetConfiguration.self)
    }

    var action: String {
        switch stage {
        case .available: "Download"
        case .downloading: "Downloading…"
        case .extracting: "Preparing…"
        case .ready: "Install and Relaunch"
        case .installing: "Installing…"
        }
    }

    var canProceed: Bool { stage == .available || stage == .ready }

    /// Downloads the update, or installs it and relaunches StableBar once it's downloaded.
    func proceed() {
        reply?(.install)
        reply = nil
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
        releaseURL = appcastItem.fullReleaseNotesURL
        stage = state.stage == .notDownloaded ? .available : .ready
        self.reply = reply
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
        version = nil
        reply = nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("StableBar \(version)").fontWeight(.semibold)
                Text("You have \(AppVersion().version!)").foregroundStyle(.secondary)
            }
            if !update.changes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's changed").fontWeight(.semibold)
                    ForEach(Array(update.changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text((try? AttributedString(markdown: change)) ?? AttributedString(change))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let url = update.releaseURL {
                Link(destination: url) {
                    HStack(spacing: 3) {
                        Text("View release on GitHub")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .foregroundStyle(.secondary)
            }
            if update.stage == .downloading || update.stage == .extracting {
                ProgressView(value: update.progress)
            }
            Button(action: update.proceed) {
                Text(update.action)
                    .fontWeight(.semibold)
                    .foregroundStyle(appearance.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(appearance.accent, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!update.canProceed)
        }
    }
}
