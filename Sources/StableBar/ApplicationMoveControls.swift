import AppKit
import SwiftUI

@MainActor @Observable
final class ApplicationMoveController {
    var isInApplications: Bool
    private(set) var isBusy = false
    private(set) var offer: ApplicationMoveOffer?
    private(set) var error: String?
    @ObservationIgnored private let mover: ApplicationMover
    @ObservationIgnored private let relaunch: @Sendable (ApplicationMoveTransaction, ApplicationMoveResume) async throws -> Void
    @ObservationIgnored private let quit: () -> Void

    init(isInApplications: Bool = appIsInApplications(), mover: ApplicationMover = ApplicationMover(),
         error: String? = nil,
         relaunch: @escaping @Sendable (ApplicationMoveTransaction, ApplicationMoveResume) async throws -> Void = {
             try await ApplicationMoveRelaunch.prepare($0, resume: $1)
         }, quit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.isInApplications = isInApplications
        self.mover = mover
        self.error = error
        self.relaunch = relaunch
        self.quit = quit
    }

    var confirmation: String? {
        guard let offer, let existing = offer.existing else { return nil }
        switch offer.action {
        case .replace: return "Replace StableBar \(existing.version) in Applications? The old copy goes to the Trash once the new copy opens."
        case .useExisting: return "StableBar \(existing.version) is already in Applications."
        case .install: return nil
        }
    }

    var action: String {
        switch offer?.action {
        case .replace: "Replace and Relaunch"
        case .useExisting: "Use the One in Applications"
        default: "Move to Applications"
        }
    }

    func canMoveFromSettings(setupIsOpen: Bool) -> Bool { !isInApplications && !setupIsOpen }

    func resumeFromSettings(store: BarStore) -> ApplicationMoveResume? {
        guard canMoveFromSettings(setupIsOpen: store.barEditing.setupIsOpen) else { return nil }
        return ApplicationMoveResume(kind: .settings, configuration: store.sharedConfigurationURL,
            barConfiguration: store.configurationURL, edits: store.sessionEdits.map(ApplicationMoveResume.Edit.init))
    }

    static let setupHint = "Use Finishing touches in setup to move StableBar to Applications."

    func cancel() { offer = nil; error = nil }

    func proceed(resume: () -> ApplicationMoveResume?) async {
        guard !isBusy, resume() != nil else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let mover = mover
            if offer == nil {
                let found = try await Task.detached { try await mover.offer() }.value
                if found.action != .install { offer = found; return }
                offer = found
            }
            guard let offer else { return }
            let transaction = try await Task.detached { try await mover.install(offer) }.value
            do {
                guard let resume = resume() else {
                    throw CommandFailure(message: Self.setupHint)
                }
                // Include edits made during the copy. Edits between this snapshot and quitting cannot carry over.
                try await relaunch(transaction, resume)
            } catch {
                guard !(await mover.system.isRunning(transaction.destination)) else {
                    let note = await Task.detached { transaction.previousCopyNote(using: mover.system) }.value
                    throw CommandFailure(message: "The copy in Applications is now running. Quit it before trying again.\(note)")
                }
                try await Task.detached { try await transaction.rollback(using: mover.system) }.value
                throw error
            }
            quit()
        } catch {
            self.error = "Couldn’t move StableBar. \(ApplicationMover.failureMessage(error))"
            offer = nil
        }
    }

    func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([mover.system.source]) }

    /// A scene exercises the same row without inspecting or changing the host's apps.
    static func sample(_ state: SceneFile.ApplicationMove?, inApplications: Bool = false) -> ApplicationMoveController {
        let controller = ApplicationMoveController(isInApplications: inApplications, relaunch: { _, _ in }, quit: {})
        switch state {
        case .replace, .useExisting:
            let identity = ApplicationBundleIdentity(identifier: "org.stablebar.app", version: "0.8.0", build: "1", executable: "StableBar")
            controller.offer = ApplicationMoveOffer(source: URL(filePath: "/Downloads/StableBar.app"),
                destination: URL(filePath: "/Applications/StableBar.app"), current: identity, existing: identity,
                action: state == .replace ? .replace : .useExisting)
        case .failed: controller.error = "Couldn’t move StableBar. Applications is full. Free some space, then try again."
        case .moving: controller.isBusy = true
        case .ready, .setupOpen, nil: break
        }
        return controller
    }
}

/// The same controls in setup and Settings' Open at login row. Confirmation stays where the move was requested.
struct ApplicationMoveControls: View {
    let controller: ApplicationMoveController
    let resume: () -> ApplicationMoveResume?
    var reveal: () -> Void = {}
    var setup = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let confirmation = controller.confirmation {
                Text(confirmation).fixedSize(horizontal: false, vertical: true)
            }
            if let error = controller.error {
                Text(error).foregroundStyle(setup ? Color.orange : SettingsPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if controller.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Moving and preparing to relaunch…")
                }
            } else {
                if setup {
                    moveButton.buttonStyle(SetupButtonStyle(prominent: false))
                        .fixedSize(horizontal: true, vertical: false)
                    if controller.offer != nil { Button("Cancel", action: controller.cancel).buttonStyle(.plain) }
                } else {
                    HStack(spacing: 8) {
                        if controller.offer != nil { Button("Cancel", action: controller.cancel) }
                        moveButton
                    }
                }
                if controller.error != nil {
                    if setup {
                        finderButton.buttonStyle(SetupButtonStyle(prominent: false))
                    } else {
                        finderButton
                    }
                }
            }
        }
        .font(.system(size: setup ? 12 : 13))
        .frame(maxWidth: setup ? 264 : 360, alignment: .trailing)
    }

    private var moveButton: some View {
        Button(controller.action) { Task { await controller.proceed(resume: resume) } }
    }

    private var finderButton: some View {
        Button("Show in Finder") { reveal(); controller.showInFinder() }
    }
}
