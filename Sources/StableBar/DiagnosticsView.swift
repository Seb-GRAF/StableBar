import SwiftUI

enum WidgetStatus: Equatable {
    case failed(String), accessNeeded(SourcePermission), paused, disabled, starting, connected, updating, working

    var title: String {
        switch self {
        case .failed: "Failed"
        case .accessNeeded: "Access needed"
        case .paused: "Paused"
        case .disabled: "Disabled"
        case .starting: "Waiting for data"
        case .connected: "Connected"
        case .updating: "Updating"
        case .working: "Working"
        }
    }

    var detail: String {
        switch self {
        case .failed(let error): error
        case .accessNeeded(let permission): "Allow \(permission.title) access to use this widget."
        case .paused: "Updates are paused while this widget is hidden or your Mac is asleep."
        case .disabled: "This widget is turned off. Enable it in its settings to show it on your bar."
        case .starting: "This source has not returned its first update yet."
        case .connected: "The source is connected and sends changes as they happen."
        case .updating: "The source is updating. The last successful result stays on your bar."
        case .working: "No problem reported."
        }
    }

    var symbol: String {
        switch self {
        case .failed: "exclamationmark.triangle.fill"
        case .accessNeeded: "lock.fill"
        case .paused: "pause.circle"
        case .disabled: "minus.circle"
        case .starting, .updating: "arrow.triangle.2.circlepath"
        case .connected, .working: "checkmark.circle.fill"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .failed, .accessNeeded: true
        default: false
        }
    }

    var color: Color {
        switch self {
        case .failed: .red
        case .accessNeeded: SettingsPalette.warning
        case .connected, .working: SettingsPalette.success
        default: .secondary
        }
    }
}

struct DiagnosticsView: View {
    let editor: ConfigurationEditor
    @State private var selectedID: String?
    @State private var event = "manual"
    @State private var notice: String?
    @State private var error: String?
    @State private var technical = false
    @State private var snapshot: String?
    @State private var snapshotDate: Date?
    @State private var snapshotTask: Task<Void, Never>?
    @State private var actionTask: Task<Void, Never>?
    @State private var needingAttention: Set<String>

    init(editor: ConfigurationEditor) {
        self.editor = editor
        _selectedID = State(initialValue: editor.diagnosticWidgetID ?? "")
        _needingAttention = State(initialValue: Set((editor.store.configuration?.widgets ?? []).filter { editor.store.widgetStatus(for: $0).needsAttention }.map(\.id)))
    }

    private var store: BarStore { editor.store }
    private var widgets: [WidgetConfiguration] { store.configuration?.widgets ?? [] }
    private var names: [String: String] {
        WidgetDisplayName.names(for: widgets, packageNames: store.widgetPackageNames, providers: store.configuration?.providers ?? [:])
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 216)
            Divider()
            VStack(spacing: 0) {
                if let error = error ?? store.configurationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Divider()
                }
                if let widget = widgets.first(where: { $0.id == selectedID }) {
                    details(widget)
                } else {
                    overview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: editor.diagnosticWidgetID) { selectedID = editor.diagnosticWidgetID ?? "" }
        .onChange(of: selectedID) { clearSelection() }
        .onChange(of: widgets.map(\.id)) {
            if !widgets.contains(where: { $0.id == selectedID }) { selectedID = "" }
        }
        .onDisappear { clearSelection() }
        .task(id: editor.searchTarget) {
            if editor.searchTarget == SettingsSearchResult.status.id {
                selectedID = ""
                editor.searchTarget = nil
            }
        }
    }

    private var sidebar: some View {
        let names = names
        return List(selection: $selectedID) {
            Label("All widgets", systemImage: "list.bullet").foregroundStyle(.primary).tag("")
            ForEach(widgets.sorted { needingAttention.contains($0.id) && !needingAttention.contains($1.id) }) { widget in
                let status = store.widgetStatus(for: widget)
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(names[widget.id]!).foregroundStyle(.primary)
                        Text(status.title).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                }
                .tag(widget.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SettingsPalette.sidebar)
    }

    private var overview: some View {
        let attention = widgets.filter { store.widgetStatus(for: $0).needsAttention }
        return Form {
            Section {
                LabeledContent("Widgets", value: String(widgets.count))
                LabeledContent("Need attention", value: String(attention.count))
                LabeledContent("Active profiles", value: store.activeProfiles.isEmpty ? "Base configuration" : store.activeProfiles.joined(separator: ", "))
            } header: {
                SettingsSectionTitle("Status")
            } footer: {
                Text("Select a widget to see its last update, fix a problem or inspect its configuration. Viewing a paused widget does not start it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !attention.isEmpty {
                Section {
                    ForEach(attention) { widget in
                        let status = store.widgetStatus(for: widget)
                        Button { selectedID = widget.id } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(status.color).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(names[widget.id]!)
                                    Text(status.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SettingsSectionTitle("Needs attention")
                }
            } else if !widgets.isEmpty {
                Section {
                    Label("No widget problems reported", systemImage: "checkmark.circle.fill").foregroundStyle(SettingsPalette.success)
                }
            }
            Section {
                LabeledContent("Configuration file") {
                    Button("Open", action: store.openConfiguration)
                    Button("Reload", action: store.reloadConfiguration)
                }
                snapshotControls
            } header: {
                SettingsSectionTitle("Configuration")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func details(_ widget: WidgetConfiguration) -> some View {
        let status = store.widgetStatus(for: widget)
        let script = store.scripts[widget.id]
        return Form {
            Section {
                Text(status.detail).textSelection(.enabled)
                if case let .accessNeeded(permission) = status {
                    SourcePermissionList(permissions: [permission])
                    if permission == .accessibility {
                        Button("Check access", action: store.appMenu.refresh)
                    }
                } else if let updated = script?.diagnostics.lastUpdated {
                    LabeledContent("Last successful update", value: updated.formatted(date: .abbreviated, time: .standard))
                }
                if let script, widget.enabled {
                    HStack {
                        if store.inspectedWidgetID == widget.id {
                            Button("Stop testing") {
                                store.setInspectedWidget(nil)
                                notice = "Testing ended. This source follows its normal visibility settings again."
                            }
                        } else if script.diagnostics.suspended {
                            Button("Resume for testing") {
                                store.setInspectedWidget(widget.id)
                                notice = "This source will stay active until you leave this widget or stop testing."
                            }
                        }
                        Button(refreshTitle(widget)) {
                            script.refresh(ScriptEvent(sender: "manual"))
                            notice = continuous(widget) ? "Connection restart requested." : "Refresh requested."
                        }
                        .disabled(script.diagnostics.suspended)
                    }
                    if let delay = script.diagnostics.nextDelay, script.error != nil {
                        Text("Automatic retries wait \(delay.formatted()) seconds between attempts.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if widget.content == .workspaces {
                    Button("Reconnect workspaces", action: store.workspaceStore.reconnect)
                }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            } header: {
                HStack(spacing: 10) {
                    Image(systemName: status.symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(status.color)
                        .frame(width: 36, height: 36)
                        .background(status.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names[widget.id]!).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        Text(status.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Configure widget") { editor.showWidget(widget.id) }
                }
                .padding(.bottom, 6)
            }
            if let name = widget.providerName {
                let consumers = widgets.filter { $0.enabled && $0.providerName == name }
                if consumers.count > 1 {
                    Section {
                        Text("Refreshing, restarting or testing this source also affects \(consumers.map { names[$0.id]! }.joined(separator: ", ")).")
                            .font(.callout).foregroundStyle(.secondary)
                    } header: {
                        SettingsSectionTitle("Shared data source")
                    }
                }
            }
            DisclosureGroup("Technical details", isExpanded: $technical) {
                LabeledContent("Widget ID", value: widget.id).textSelection(.enabled)
                if let script {
                    if let duration = script.diagnostics.lastDuration {
                        LabeledContent("Last run", value: "\(duration.formatted()) seconds")
                    }
                    LabeledContent("Completed-command CPU time", value: "\(script.diagnostics.cpuTime.formatted()) seconds")
                    LabeledContent("Executions", value: String(script.diagnostics.executionCount))
                    LabeledContent("Failures", value: String(script.diagnostics.failureCount))
                    LabeledContent("Restarts", value: String(script.diagnostics.restartCount))
                }
                snapshotControls
                if let action = script?.output.onClick ?? widget.onClick {
                    Button(actionTask != nil ? "Running click action…" : "Test click action") {
                        let id = widget.id
                        let action = store.runAction(action, widget: widget)
                        actionTask = Task {
                            await action.value
                            if Task.isCancelled { return }
                            actionTask = nil
                            notice = store.actionErrors[id] ?? "Click action completed."
                        }
                    }
                    .disabled(actionTask != nil || !store.barEditing.allowsWidgetActions)
                    Text(action).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                TextField("Event name", text: $event)
                Button("Broadcast event to subscribers") {
                    store.refreshScripts(for: event)
                    notice = "Broadcast “\(event)” to all subscribed widgets and data sources."
                }
                .disabled(event.isEmpty)
                Text("Events are sent to all subscribers, regardless of the selected widget.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var snapshotControls: some View {
        Group {
            HStack {
                Button(snapshot == nil ? "Capture output and configuration" : "Refresh snapshot", action: captureSnapshot)
                    .disabled(snapshotTask != nil)
                if let snapshot {
                    Button("Copy snapshot") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snapshot, forType: .string)
                        notice = "Snapshot copied."
                    }
                }
                if snapshotTask != nil { ProgressView().controlSize(.small) }
            }
            if let snapshotDate {
                Text("Captured \(snapshotDate.formatted(date: .omitted, time: .standard)). Refresh to see newer output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot {
                ScrollView([.vertical, .horizontal]) {
                    Text(snapshot).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(height: 240)
                .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
            }
        }
    }

    private func continuous(_ widget: WidgetConfiguration) -> Bool {
        guard let name = widget.providerName, let provider = store.configuration?.providers[name] else { return false }
        return store.registry[provider.type]?.continuous == true
    }

    private func refreshTitle(_ widget: WidgetConfiguration) -> String {
        if store.scripts[widget.id]?.error != nil { return "Retry now" }
        return continuous(widget) ? "Restart connection" : "Refresh data"
    }

    private func captureSnapshot() {
        snapshotTask = Task {
            do {
                let value = try store.snapshot(id: selectedID == "" ? nil : selectedID)
                let text = try await Task.detached(priority: .utility) {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return String(decoding: try encoder.encode(value), as: UTF8.self)
                }.value
                if Task.isCancelled { return }
                snapshot = text
                snapshotDate = Date()
                error = nil
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            snapshotTask = nil
        }
    }

    private func clearSelection() {
        store.setInspectedWidget(nil)
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshot = nil
        snapshotDate = nil
        technical = false
        actionTask?.cancel()
        actionTask = nil
        notice = nil
        error = nil
    }
}
