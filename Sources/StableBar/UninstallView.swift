import AppKit
import SwiftUI

/// Settings › General › Uninstall: puts back what StableBar changed on this Mac, removes it and quits.
struct UninstallSettings: View {
    let store: BarStore
    @State private var snapshot = UninstallSnapshot()
    @State private var confirming = false

    var body: some View {
        SettingRow(title: "Uninstall StableBar",
                   hint: UninstallSystem.isAvailable ? "Put back the macOS settings StableBar changed, remove what it added, then move it to the Trash."
                       : "Uninstall works from StableBar.app.") {
            Button("Uninstall…") {
                snapshot = UninstallSystem.snapshot()
                confirming = true
            }
            .disabled(!UninstallSystem.isAvailable)
        }
        .sheet(isPresented: $confirming) { UninstallSheet(store: store, snapshot: snapshot) }
    }
}

struct UninstallSheet: View {
    let store: BarStore
    let snapshot: UninstallSnapshot
    @State private var options: UninstallOptions
    @State private var running = false
    @State private var outcomes: [UninstallOutcome]?
    /// Whether `--finish-uninstall` waits for StableBar to quit.
    @State private var finishing = false
    @Environment(\.dismiss) private var dismiss

    init(store: BarStore, snapshot: UninstallSnapshot, outcomes: [UninstallOutcome]? = nil, finishing: Bool = false) {
        self.store = store
        self.snapshot = snapshot
        _options = State(initialValue: UninstallOptions(snapshot))
        _outcomes = State(initialValue: outcomes)
        _finishing = State(initialValue: finishing)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let outcomes { finished(outcomes) } else { confirmation }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if outcomes != nil {
                    Button("Quit StableBar") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button("Uninstall", role: .destructive, action: uninstall).disabled(running)
                }
            }
            .padding(12)
        }
        .frame(width: 520)
        .background(SettingsPalette.background)
        .interactiveDismissDisabled(running || outcomes != nil)
    }

    @ViewBuilder private var confirmation: some View {
        Text("Uninstall StableBar?").font(.system(size: 17, weight: .semibold))
        Text(snapshot.homebrew
             ? "StableBar puts back what it changed on this Mac and removes what it added, then quits. Homebrew installed the app, so finish with \(UninstallSnapshot.homebrewCommand)."
             : "StableBar puts back what it changed on this Mac and removes what it added, then quits and moves itself to the Trash.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(listedSteps, id: \.self) { step in
                Label(step.title, systemImage: "checkmark").labelStyle(UninstallStepLabelStyle())
            }
        }
        if snapshot.menuBarHides {
            Toggle(isOn: $options.showsMenuBar) {
                choice("Turn off the macOS menu bar’s auto-hide", snapshot.turnedOnMenuBarAutoHide
                       ? "StableBar turned it on so the bar could take the menu bar’s place."
                       : "It’s on, but StableBar didn’t turn it on, so it stays unless you check this.")
            }
        }
        if let configuration = snapshot.configuration {
            Toggle(isOn: $options.removesConfiguration) {
                choice("Also move \(configuration.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) to the Trash",
                       "Your configuration, scripts and packages. Keep it to set up StableBar the same way later.")
            }
        }
        if snapshot.asksForPassword {
            Text("macOS asks for an administrator password to remove the \(CommandLineTool.name) command.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The steps the toggles below don't already show.
    private var listedSteps: [UninstallStep] {
        snapshot.steps(options).filter { step in
            switch step {
            case .showMenuBar, .configuration: false
            default: true
            }
        }
    }

    private func choice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func finished(_ outcomes: [UninstallOutcome]) -> some View {
        let failed = outcomes.filter { $0.error != nil }
        Text(failed.isEmpty ? "StableBar is uninstalled" : "Some steps still need you")
            .font(.system(size: 17, weight: .semibold))
        ForEach(failed, id: \.step) { outcome in
            VStack(alignment: .leading, spacing: 3) {
                Label(outcome.step.title, systemImage: "exclamationmark.triangle.fill").labelStyle(UninstallStepLabelStyle(warning: true))
                Text("\(outcome.error ?? "") \(outcome.step.fix)")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
        if finishing {
            Text(snapshot.homebrew
                 ? "Once StableBar has quit, it resets its permissions and deletes its caches and preferences."
                 : "Once StableBar has quit, it resets its permissions, deletes its caches and preferences and moves itself to the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if snapshot.homebrew {
            Text("Homebrew installed StableBar. To remove the app, run this in Terminal after quitting:")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(UninstallSnapshot.homebrewCommand)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UninstallSnapshot.homebrewCommand, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func uninstall() {
        running = true
        Task {
            // Stopped widgets and update checks can't write back the caches and preferences the steps remove.
            store.update?.stop()
            store.stop()
            // What would take away the app, its permissions and preferences waits until StableBar has quit, so a step that
            // fails here leaves it whole until you quit it.
            var outcomes = await Uninstall.run(snapshot.stepsBeforeQuit(options), perform: UninstallSystem.perform)
            if Uninstall.finishesAfterQuit(outcomes) {
                do {
                    try UninstallSystem.finishAfterQuit()
                    finishing = true
                } catch {
                    outcomes += snapshot.stepsAfterQuit.map {
                        UninstallOutcome(step: $0, error: "StableBar couldn’t start this step: \(errorMessage(error))")
                    }
                }
            }
            running = false
            if outcomes.allSatisfy({ $0.error == nil }) && !snapshot.homebrew {
                NSApp.terminate(nil)
            } else {
                self.outcomes = outcomes
            }
        }
    }
}

private struct UninstallStepLabelStyle: LabelStyle {
    var warning = false

    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? SettingsPalette.warning : .secondary)
                .frame(width: 14)
            configuration.title
        }
    }
}
