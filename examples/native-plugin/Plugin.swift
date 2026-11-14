import AppKit
import SwiftUI

@MainActor
@objc(StableBarNativeWidgetPluginPrincipal)
final class StableBarNativeWidgetPluginPrincipal: NSObject, StableBarNativeWidgetPlugin {
    private let state = DemoState()
    private weak var host: (any StableBarNativeWidgetHost)?

    var apiVersion: Int { 1 }

    func configure(with host: any StableBarNativeWidgetHost, settings: [String: Any]) {
        self.host = host
        state.tapCount = settings["tapCount"] as? Int ?? 0
    }

    func settingsDidChange(_ settings: [String: Any]) {
        if let tapCount = settings["tapCount"] as? Int { state.tapCount = tapCount }
    }

    func stableBarDidReceiveEvent(_ name: String, payload: [String: Any]) {
        state.lastEvent = name
    }

    func makeWidgetView() -> NSView {
        NSHostingView(rootView: DemoWidgetView(state: state) { [weak self] in self?.activateDemoButton() })
    }

    func makePopupView() -> NSView {
        NSHostingView(rootView: DemoPopupView(state: state))
    }

    func start() {
        state.isStarted = true
    }

    func stop() {
        state.isStarted = false
    }

    private func activateDemoButton() {
        guard state.isStarted else { return }
        withAnimation(.spring(duration: 0.3)) { state.tapCount += 1 }
        host?.saveSettings(["tapCount": state.tapCount])
        host?.requestPopup()
    }

    @objc func activateDemoButtonForTesting() {
        activateDemoButton()
    }

    @objc func lastReceivedEventForTesting() -> String? { state.lastEvent }
}

@MainActor
private final class DemoState: ObservableObject {
    @Published var isStarted = false
    @Published var tapCount = 0
    @Published var lastEvent: String?
}

private struct DemoWidgetView: View {
    @ObservedObject var state: DemoState
    let activate: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let info = ProcessInfo.processInfo
            Button {
                activate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.isStarted ? "waveform.path" : "pause.circle")
                        .symbolEffect(.pulse, isActive: state.isStarted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thermal \(info.thermalState.label)").font(.system(size: 11, weight: .medium))
                        Text("\(Int(info.systemUptime) % 100_000)s · taps \(state.tapCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(context.date, style: .time).font(.system(size: 9, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DemoPopupView: View {
    @ObservedObject var state: DemoState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Native plugin demo", systemImage: "puzzlepiece.extension")
                .font(.headline)
            Text("Thermal state: \(ProcessInfo.processInfo.thermalState.label)")
            Text("System uptime: \(Int(ProcessInfo.processInfo.systemUptime)) seconds")
            Text("Widget taps: \(state.tapCount)")
            if let lastEvent = state.lastEvent { Text("Last event: \(lastEvent)") }
            Text(state.isStarted ? "Lifecycle: started" : "Lifecycle: stopped")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }
}

private extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "normal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
