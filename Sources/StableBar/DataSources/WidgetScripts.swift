import Foundation
import Observation

@MainActor @Observable
final class WidgetScripts {
    private weak var store: BarStore?
    var actionErrors: [String: String] = [:]
    var scripts: [String: ScriptWidget] = [:]
    var providers: [String: ScriptWidget] = [:]
    private var visibleWidgets: [Int: Set<String>] = [:]
    private var pauses: Set<PauseReason> = []
    var popupWidgetID: String?
    private(set) var inspectedWidgetID: String?
    private(set) var inspectorOpen = false
    private var eventObservers: [NSObjectProtocol] = []
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var actionTails: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(store: BarStore) {
        self.store = store
    }

    func run(_ next: Configuration) {
        guard let store else { return }
        let previous = store.configuration?.widgets ?? []
        for (id, script) in scripts {
            let old = previous.first { $0.id == id }
            let new = next.widgets.first { $0.id == id && $0.enabled }
            if case .provider = old?.content {
                scripts.removeValue(forKey: id)
                continue
            }
            if old?.content != new?.content || old?.timeout != new?.timeout
                || old?.environment != new?.environment || store.configuration?.environment != next.environment {
                script.stop()
                scripts.removeValue(forKey: id)
            }
        }
        let usedProviders = next.activeProviders
        for (name, script) in providers {
            if !usedProviders.contains(name) || store.configuration?.providers[name] != next.providers[name]
                || store.configuration?.environment != next.environment {
                script.stop()
                providers.removeValue(forKey: name)
            }
        }
        for name in usedProviders where providers[name] == nil {
            let script = ScriptWidget()
            let provider = next.providers[name]!
            var environment = next.environment
            environment["NAME"] = name
            environment["CONFIG_DIR"] = store.configurationStore.configurationURL.deletingLastPathComponent().path
            environment["STABLEBAR"] = Bundle.main.executablePath
            environment["STABLEBAR_CONFIG"] = store.configurationStore.sharedConfigurationURL.path
            if let events = store.registry[provider.type]?.events, !events.isEmpty {
                script.onOutputChange = { [weak self, weak script] previous, output in
                    for event in events {
                        if let variables = event.variables(from: previous, to: output) { self?.send(event, variables, from: script) }
                    }
                }
            }
            if provider.type == DataSourceType.merge.name {
                script.start(schedule: SourceSchedule(continuous: true)) { [weak self] in
                    MergeSource(inputs: provider.providers) { self?.providers[$0] }
                }
            } else {
                script.start(provider: provider, registry: store.registry, environment: environment)
            }
            providers[name] = script
        }
        for widget in next.widgets where widget.enabled {
            switch widget.content {
            case let .provider(name): scripts[widget.id] = providers[name]
            case let .script(command, interval) where scripts[widget.id] == nil:
                let script = ScriptWidget()
                scripts[widget.id] = script
                script.start(command: command, interval: interval, timeout: widget.timeout,
                             environment: commandEnvironment(widget, configuration: next))
            default: break
            }
        }
    }

    func observeEvents(of next: Configuration) {
        let needsWorkspaces = next.widgets.contains { $0.enabled && ($0.content == .workspaces || $0.display == .active) }
        let center = DistributedNotificationCenter.default()
        for observer in eventObservers { center.removeObserver(observer) }
        let events = Set(next.widgets.filter(\.enabled).flatMap(\.events) + next.activeProviders.flatMap { next.providers[$0]!.events }
                         + (needsWorkspaces && next.workspaceSource == .yabai ? [BuiltInEvent.yabai.rawValue] : []))
        eventObservers = events.map { event in
            center.addObserver(forName: Notification.Name(event), object: nil, queue: .main) { [weak self] notification in
                var environment = withoutShellVariables(notification.userInfo as? [String: String] ?? [:])
                if environment["INFO"] == nil, let info = notification.userInfo as? [String: Any] {
                    environment["INFO"] = notificationInfo(info)
                }
                MainActor.assumeIsolated { self?.refreshScripts(for: event, environment: environment) }
            }
        }
    }

    func setVisibleWidgets(ids: Set<String>, displayID: Int) {
        visibleWidgets[displayID] = ids
        updateSuspension()
    }

    func retainDisplays(_ ids: Set<Int>) {
        visibleWidgets = visibleWidgets.filter { ids.contains($0.key) }
        updateSuspension()
    }

    func setInspectedWidget(_ id: String?) {
        inspectedWidgetID = id
        updateSuspension()
    }

    func setInspectorOpen(_ open: Bool) {
        inspectorOpen = open
        if !open { inspectedWidgetID = nil }
        updateSuspension()
    }

    func widgetStatus(for widget: WidgetConfiguration) -> WidgetStatus {
        guard let store else { return .working }
        if !widget.enabled { return .disabled }
        if let error = actionErrors[widget.id] { return .failed("Click action: \(error)") }
        let script = scripts[widget.id]
        if let error = script?.error { return .failed(error) }
        for input in store.configuration?.providerNames(readBy: widget).dropFirst() ?? [] {
            if let error = providers[input]?.error { return .failed("\(input): \(error)") }
        }
        if widget.content == .workspaces, let error = store.workspaceStore.error { return .failed(error) }
        if !widget.permissions(source: store.configuration?.workspaceSource ?? .aerospace).isEmpty, !store.appMenu.isTrusted {
            return .accessNeeded(.accessibility)
        }
        if let name = widget.providerName, let provider = store.configuration?.providers[name] {
            let sources = provider.type == DataSourceType.merge.name
                ? provider.providers.map { ("\($0).access", store.configuration!.providers[$0]!.type) } : [("access", provider.type)]
            for (field, type) in sources {
                if let permission = store.registry[type]?.permission, let access = script?.output.fields?[field], access != "granted" {
                    return .accessNeeded(permission)
                }
            }
        }
        if script?.diagnostics.suspended == true { return .paused }
        if let script {
            if script.diagnostics.lastUpdated == nil { return .starting }
            if let name = widget.providerName, let provider = store.configuration?.providers[name],
               store.registry[provider.type]?.continuous == true, script.diagnostics.running {
                return .connected
            }
            if script.diagnostics.running { return .updating }
        }
        return .working
    }

    func setPaused(_ paused: Bool, because reason: PauseReason) {
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        updateSuspension()
    }

    func updateSuspension() {
        guard let store else { return }
        store.workspaceStore.dockBadges.isWatching = store.managesConnections && pauses.isEmpty && store.configuration?.showsDockBadges == true
        var visible = visibleWidgets.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        if let popupWidgetID { visible.insert(popupWidgetID) }
        if inspectorOpen, let inspectedWidgetID { visible.insert(inspectedWidgetID) }
        for (name, provider) in providers {
            let definition = store.configuration?.providers[name]
            let sendsSubscribedEvents = store.registry[definition?.type ?? ""]?.events
                .contains { store.configuration?.subscribedEvents.contains($0.rawValue) == true } == true
            let hidden = definition?.whenVisible == true && !sendsSubscribedEvents
                && !(store.configuration?.widgets.contains { store.configuration!.providerNames(readBy: $0).contains(name) && visible.contains($0.id) } ?? false)
            if !pauses.isEmpty || hidden { provider.suspend() } else { provider.resume() }
        }
        for widget in store.configuration?.widgets ?? [] {
            if case .script = widget.content {
                if !pauses.isEmpty { scripts[widget.id]?.suspend() } else { scripts[widget.id]?.resume() }
            }
        }
    }

    private func commandEnvironment(_ widget: WidgetConfiguration, configuration: Configuration) -> [String: String] {
        guard let store else { return [:] }
        var environment = configuration.environment.merging(widget.environment) { _, widget in widget }
        environment["NAME"] = widget.id
        environment["CONFIG_DIR"] = store.configurationStore.configurationURL.deletingLastPathComponent().path
        environment["STABLEBAR"] = Bundle.main.executablePath
        environment["STABLEBAR_CONFIG"] = store.configurationStore.sharedConfigurationURL.path
        return environment
    }

    /// Sends one of StableBar's own events to the widgets and providers that subscribe to it.
    /// `sender`, the provider whose change sent the event, isn't refreshed: it has the change already,
    /// and a refresh would restart it.
    func send(_ event: BuiltInEvent, _ variables: [String: String] = [:], from sender: ScriptWidget? = nil) {
        refreshScripts(for: event.rawValue, environment: variables, skipping: sender)
    }

    func refreshScripts(for event: String, environment: [String: String] = [:], skipping sender: ScriptWidget? = nil) {
        guard let store else { return }
        if event == BuiltInEvent.yabai.rawValue { store.workspaceStore.trigger() }
        var refreshed = Set<ObjectIdentifier>()
        if let sender { refreshed.insert(ObjectIdentifier(sender)) }
        for widget in store.configuration?.widgets ?? [] where widget.enabled {
            let providerEvents: [String]
            if case let .provider(name) = widget.content { providerEvents = store.configuration!.providers[name]!.events }
            else { providerEvents = [] }
            let subscribed = (widget.events + providerEvents).contains(event)
            if subscribed, let script = scripts[widget.id], refreshed.insert(ObjectIdentifier(script)).inserted {
                script.refresh(ScriptEvent(sender: event, environment: environment))
            }
            for input in store.configuration!.providerNames(readBy: widget).dropFirst()
            where subscribed || store.configuration!.providers[input]!.events.contains(event) {
                if let script = providers[input], refreshed.insert(ObjectIdentifier(script)).inserted {
                    script.refresh(ScriptEvent(sender: event, environment: environment))
                }
            }
        }
    }

    /// Refreshes `widget` and, for a merge, the providers it combines, which hold its data.
    func refresh(_ widget: WidgetConfiguration, event: ScriptEvent) {
        guard let store else { return }
        scripts[widget.id]?.refresh(event)
        for input in store.configuration!.providerNames(readBy: widget).dropFirst() { providers[input]?.refresh(event) }
    }

    @discardableResult
    func runAction(_ command: String, widget: WidgetConfiguration,
                   event: ScriptEvent = ScriptEvent(sender: "mouse.clicked")) -> Task<Void, Never> {
        runAction(.command(command), widget: widget, event: event)
    }

    @discardableResult
    func runAction(_ action: BlockAction, widget: WidgetConfiguration,
                   event: ScriptEvent = ScriptEvent(sender: "mouse.clicked")) -> Task<Void, Never> {
        guard let store, store.barEditing.allowsWidgetActions else { return Task {} }
        let id = UUID()
        let script = scripts[widget.id]
        let environment = commandEnvironment(widget, configuration: store.configuration!)
        let previous = actionTails[widget.id]?.task
        let task = Task {
            await previous?.value
            defer {
                actions.removeValue(forKey: id)
                if actionTails[widget.id]?.id == id { actionTails.removeValue(forKey: widget.id) }
            }
            do {
                try Task.checkCancellation()
                switch action {
                case let .command(command):
                    _ = try await runCommand("/bin/zsh", arguments: ["-c", command],
                                             timeout: widget.timeout, environment: event.commandEnvironment(environment))
                case let .set(setting):
                    let value = event.environment["VALUE"]!
                    try await BlockingWork.run { try setting.set(value) }
                }
                if let script, scripts[widget.id] === script {
                    refresh(widget, event: ScriptEvent(sender: "action", environment: event.environment))
                }
                if actionErrors[widget.id] != nil { actionErrors[widget.id] = nil }
            } catch {
                if Task.isCancelled { return }
                actionErrors[widget.id] = error.localizedDescription
            }
        }
        actions[id] = task
        actionTails[widget.id] = (id, task)
        return task
    }

    func move(_ source: MenuBarItemSource, to placement: MenuBarItemPlacement, before index: Int?, in widget: WidgetConfiguration) {
        guard let store, case let .menuBarItems(_, _, _, hidden) = widget.content else { return }
        let properties = menuBarItemsProperties(shown: widget.shownMenuBarItems, hidden: hidden, moving: source, to: placement, before: index,
                                                among: store.appMenu.menuBarItems)
        do {
            try store.customizationHistory.change(ConfigurationEdit(action: .set, id: widget.id, properties: properties))
            if actionErrors[widget.id] != nil { actionErrors[widget.id] = nil }
        } catch {
            actionErrors[widget.id] = errorMessage(error)
        }
    }

    /// Selects the keyboard input source with `id`, or without one, the next, for a click on `widget`.
    func selectInputSource(_ id: String?, widget: WidgetConfiguration) {
        do {
            try InputSourceMonitor.select(id)
            if actionErrors[widget.id] != nil { actionErrors[widget.id] = nil }
        } catch {
            actionErrors[widget.id] = errorMessage(error)
        }
    }

    /// Makes the audio device with `id` the default output, or with `input` the default input, for a click on `widget`.
    func selectAudioDevice(_ id: String, input: Bool, widget: WidgetConfiguration) {
        do {
            try AudioMonitor.setDefaultDevice(id, input: input)
            if actionErrors[widget.id] != nil { actionErrors[widget.id] = nil }
        } catch {
            actionErrors[widget.id] = errorMessage(error)
        }
    }

    /// Sends `command` to the playing app, for a click on `widget`.
    func sendNowPlaying(_ command: NowPlaying.Command, widget: WidgetConfiguration) {
        Task {
            do {
                try await NowPlaying.send(command)
                if actionErrors[widget.id] != nil { actionErrors[widget.id] = nil }
            } catch {
                actionErrors[widget.id] = errorMessage(error)
            }
        }
    }

    func stop() {
        for script in scripts.values { script.stop() }
        for provider in providers.values { provider.stop() }
        providers.removeAll()
        scripts.removeAll()
        for action in actions.values { action.cancel() }
        actions.removeAll()
        actionTails.removeAll()
        for observer in eventObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        eventObservers.removeAll()
    }
}

func withoutShellVariables(_ environment: [String: String]) -> [String: String] {
    let shell = shellEnvironment.withLock { $0 }
    return environment.filter { shell[$0.key] == nil }
}

/// A distributed notification's payload as JSON. `JSONSerialization` raises an exception on values
/// JSON can't hold, so dates become ISO 8601 strings and the rest, such as data, is left out.
func notificationInfo(_ payload: [String: Any]) -> String? {
    func jsonValue(_ value: Any) -> Any? {
        switch value {
        case let date as Date: date.formatted(.iso8601)
        case let array as [Any]: array.compactMap(jsonValue)
        case let dictionary as [String: Any]: dictionary.compactMapValues(jsonValue)
        default: JSONSerialization.isValidJSONObject([value]) ? value : nil
        }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload.compactMapValues(jsonValue), options: [.sortedKeys]) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}
