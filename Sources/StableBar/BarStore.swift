import AppKit
import Observation

@MainActor @Observable
final class BarStore: NSObject {
    var configuration: Configuration?
    var configurationError: String?
    var actionErrors: [String: String] = [:]
    var activeApp = NSWorkspace.shared.frontmostApplication
    var activeDisplayID = 1
    var scripts: [String: ScriptWidget] = [:]
    let workspaceStore = WorkspaceStore()
    let popup = WidgetPopup()
    let configurationURL: URL
    var onConfigurationChange: (() -> Void)?
    var onCustomize: (() -> Void)?
    var effectiveDocument: [String: ConfigurationValue] = [:]
    var origins: [String: ConfigurationOrigin] = [:]
    var activeProfiles: [String] = []
    var profiles: [ConfigurationProfile] = []
    var pinnedProfile: String?
    var sessionEdits: [ConfigurationEdit] = []
    var context = ConfigurationContext()
    private var providers: [String: ScriptWidget] = [:]
    private var visibleWidgets: [Int: Set<String>] = [:]
    private var sleeping = false
    private var popupWidgetID: String?
    private var inspectedWidgetID: String?
    private var inspectorOpen = false
    private var configurationLoader = ConfigurationLoader()
    private let configurationWatcher = ConfigurationWatcher()
    private var reloadTask: Task<Void, Never>?
    private var eventObservers: [NSObjectProtocol] = []
    private var reloadObserver: NSObjectProtocol?
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var actionTails: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(configurationURL: URL = LaunchCommand.configurationURL) {
        self.configurationURL = configurationURL
        super.init()
        configurationWatcher.onChange = { [weak self] in self?.scheduleReload() }
    }

    func start() {
        context = SystemContext.current()
        reloadObserver = DistributedNotificationCenter.default().addObserver(
            forName: LaunchCommand.reloadNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadConfiguration() }
            }
        workspaceStore.onWorkspaceChange = { [weak self] in
            guard let self else { return }
            popup.close()
            let focused = workspaceStore.workspaces.first(where: \.isFocused)
            refreshScripts(for: "workspace", environment: ["INFO": focused?.name ?? "", "SID": String(focused?.monitor ?? activeDisplayID)])
        }
        workspaceStore.onModeChange = { [weak self] mode in
            self?.refreshScripts(for: "aerospaceMode", environment: ["INFO": mode])
        }
        do {
            let directory = configurationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: configurationURL.path) {
                let template = Bundle.main.url(forResource: "config", withExtension: "json")!
                let data = try SetupPreferences(placement: .belowMenuBar).applying(
                    to: Data(contentsOf: template),
                    menuBarHeight: max(NSStatusBar.system.thickness, NSScreen.main?.safeAreaInsets.top ?? 0))
                try data.write(to: configurationURL, options: .atomic)
            }
            try migrateConfigurationFile(configurationURL)
            reloadConfiguration()
        } catch {
            configurationError = errorMessage(error)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateActiveApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func updateActiveApp() {
        activeApp = NSWorkspace.shared.frontmostApplication
        if let screen = NSScreen.main { activeDisplayID = BarDisplay(screen: screen).id }
        popup.close()
        refreshContext()
        refreshScripts(for: "frontApp", environment: ["INFO": activeApp?.localizedName ?? "Desktop"])
    }

    func refreshContext() {
        let next = SystemContext.current()
        var nextWithSameApp = next
        nextWithSameApp.app = context.app
        let reload = nextWithSameApp != context || (next.app != context.app && configurationLoader.matchesApps)
        context = next
        if reload { reloadConfiguration() }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                reloadConfiguration()
            } catch {}
        }
    }

    func reloadConfiguration() {
        defer { configurationWatcher.watch(configurationLoader.dependencies) }
        do {
            let base = try configurationLoader.load(configurationURL, context: context)
            let next: Configuration
            if sessionEdits.isEmpty { next = base }
            else {
                let root = try editedDocument([])
                next = try configurationLoader.load(configurationURL, data: configurationData(root), context: context)
            }
            apply(next)
        } catch {
            configurationError = errorMessage(error)
        }
    }

    func editedDocument(_ edits: [ConfigurationEdit]) throws -> [String: ConfigurationValue] {
        let data = try Data(contentsOf: configurationURL)
        var root = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        var loader = ConfigurationLoader()
        var ids: [String] = []
        for edit in sessionEdits { root = try edit.applying(to: root, widgetIDs: &ids) }
        ids = try loader.load(configurationURL, data: configurationData(root), context: context).widgets.map(\.id)
        for edit in edits {
            try edit.validateTargets(in: ids)
            root = try edit.applying(to: root, widgetIDs: &ids)
            if edit.action == .profile || edit.action == .profiles || edit.action == .package {
                ids = try loader.load(configurationURL, data: configurationData(root), context: context).widgets.map(\.id)
            }
        }
        return root
    }

    func applyEdits(_ edits: [ConfigurationEdit], persist: Bool) throws {
        let allEdits = sessionEdits + edits
        let root = try editedDocument(edits)
        let data = try configurationData(root)
        var loader = ConfigurationLoader()
        let next = try loader.load(configurationURL, data: data, context: context)
        if persist { try configurationData(root, editing: Data(contentsOf: configurationURL)).write(to: configurationURL, options: .atomic) }
        sessionEdits = persist ? [] : allEdits
        configurationLoader = loader
        apply(next)
        configurationWatcher.watch(loader.dependencies)
    }

    func setSessionEdits(_ edits: [ConfigurationEdit]) throws {
        let previous = sessionEdits
        sessionEdits = edits
        do { try applyEdits([], persist: false) }
        catch { sessionEdits = previous; throw error }
    }

    private func apply(_ next: Configuration) {
        profiles = configurationLoader.profiles
        pinnedProfile = configurationLoader.pinnedProfile
        if effectiveDocument == configurationLoader.document {
            origins = configurationLoader.origins
            activeProfiles = configurationLoader.activeProfiles
            configurationError = nil
            return
        }
        popup.close()
        let previous = configuration?.widgets ?? []
        for (id, script) in scripts {
            let old = previous.first { $0.id == id }
            let new = next.widgets.first { $0.id == id && $0.enabled }
            if case .provider = old?.content {
                scripts.removeValue(forKey: id)
                continue
            }
            if old?.content != new?.content || old?.timeout != new?.timeout
                || old?.environment != new?.environment || configuration?.environment != next.environment {
                script.stop()
                scripts.removeValue(forKey: id)
            }
        }
        let usedProviders = Set(next.widgets.filter(\.enabled).compactMap { widget -> String? in
            if case let .provider(name) = widget.content { return name }
            return nil
        })
        for (name, script) in providers {
            if !usedProviders.contains(name) || configuration?.providers[name] != next.providers[name]
                || configuration?.environment != next.environment {
                script.stop()
                providers.removeValue(forKey: name)
            }
        }
        for name in usedProviders where providers[name] == nil {
            let script = ScriptWidget()
            var environment = next.environment
            environment["NAME"] = name
            environment["CONFIG_DIR"] = configurationURL.deletingLastPathComponent().path
            script.start(provider: next.providers[name]!, environment: environment)
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
        let needsWorkspaces = next.widgets.contains { $0.enabled && ($0.content == .workspaces || $0.display == .active) }
        let hadWorkspaces = previous.contains { $0.enabled && ($0.content == .workspaces || $0.display == .active) }
        let sourceChanged = workspaceStore.source != next.workspaceSource
        workspaceStore.source = next.workspaceSource
        if sourceChanged { workspaceStore.workspaces = []; workspaceStore.error = nil }
        if needsWorkspaces && (!hadWorkspaces || sourceChanged) { workspaceStore.start() }
        if !needsWorkspaces && hadWorkspaces { workspaceStore.stop() }
        configuration = next
        effectiveDocument = configurationLoader.document
        origins = configurationLoader.origins
        activeProfiles = configurationLoader.activeProfiles
        configurationError = nil
        let center = DistributedNotificationCenter.default()
        for observer in eventObservers { center.removeObserver(observer) }
        let events = Set(next.widgets.filter(\.enabled).flatMap(\.events) + usedProviders.flatMap { next.providers[$0]!.events }
                         + (needsWorkspaces && next.workspaceSource == .yabai ? ["yabai"] : []))
        eventObservers = events.map { event in
            center.addObserver(forName: Notification.Name(event), object: nil, queue: .main) { [weak self] notification in
                var environment = withoutShellVariables(notification.userInfo as? [String: String] ?? [:])
                if environment["INFO"] == nil, let info = notification.userInfo,
                   let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
                    environment["INFO"] = String(decoding: data, as: UTF8.self)
                }
                MainActor.assumeIsolated { self?.refreshScripts(for: event, environment: environment) }
            }
        }
        updateSuspension()
        onConfigurationChange?()
    }

    func setVisibleWidgets(ids: Set<String>, displayID: Int) {
        visibleWidgets[displayID] = ids
        updateSuspension()
    }

    func retainDisplays(_ ids: Set<Int>) {
        visibleWidgets = visibleWidgets.filter { ids.contains($0.key) }
        updateSuspension()
    }

    func setPopupVisibleWidget(_ id: String?) {
        popupWidgetID = id
        updateSuspension()
    }

    func setInspectedWidget(_ id: String?) {
        inspectedWidgetID = id
        updateSuspension()
    }

    func setInspectorOpen(_ open: Bool) {
        inspectorOpen = open
        updateSuspension()
    }

    func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        updateSuspension()
    }

    private func updateSuspension() {
        var visible = visibleWidgets.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        if let popupWidgetID { visible.insert(popupWidgetID) }
        if inspectorOpen, let inspectedWidgetID { visible.insert(inspectedWidgetID) }
        for (name, provider) in providers {
            let hidden = configuration?.providers[name]?.whenVisible == true
                && !(configuration?.widgets.contains { $0.content == .provider(name) && visible.contains($0.id) } ?? false)
            if sleeping || hidden { provider.suspend() } else { provider.resume() }
        }
        for widget in configuration?.widgets ?? [] {
            if case .script = widget.content {
                if sleeping { scripts[widget.id]?.suspend() } else { scripts[widget.id]?.resume() }
            }
        }
    }

    func handle(_ request: RuntimeRequest) throws -> ConfigurationValue {
        switch request.action {
        case .customize: onCustomize?()
        case .reload: try applyEdits([], persist: false)
        case .batch: try applyEdits(request.edits ?? [], persist: request.persist)
        case .reset: try setSessionEdits([])
        case .refresh:
            guard let id = request.id, let script = scripts[id] else { throw CommandFailure(message: "Refresh requires a running widget id.") }
            guard !script.diagnostics.suspended else {
                throw CommandFailure(message: "Widget is suspended. Open it in the inspector or make a consumer visible before refreshing.")
            }
            script.refresh(ScriptEvent(sender: "manual"))
        case .trigger:
            guard let event = request.id else { throw CommandFailure(message: "Trigger requires an event name.") }
            refreshScripts(for: event, environment: withoutShellVariables(request.environment ?? [:]))
        case .query: break
        }
        return try snapshot(id: request.action == .query ? request.id : nil)
    }

    func snapshot(id: String? = nil) throws -> ConfigurationValue {
        if let id {
            let definitions = try effectiveDocument["widgets"]?.decoded([[String: ConfigurationValue]].self) ?? []
            guard let definition = definitions.first(where: { $0["id"] == .string(id) }) else {
                throw CommandFailure(message: "Unknown widget: \(id).")
            }
            var result: [String: ConfigurationValue] = ["configuration": .object(definition),
                "defaults": effectiveDocument["defaults"] ?? .object([:]),
                "origins": .object(origins.filter { $0.key.hasPrefix("widgets.\(id).") }.mapValues { .string($0.description) })]
            if let script = scripts[id] {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                result["diagnostics"] = try JSONDecoder().decode(ConfigurationValue.self, from: encoder.encode(script.diagnostics))
                result["samples"] = .array(script.samples.map(ConfigurationValue.number))
                result["latestOutput"] = (try? JSONDecoder().decode(ConfigurationValue.self, from: Data(script.diagnostics.lastStdout.utf8)))
                    ?? .string(script.diagnostics.lastStdout)
                result["error"] = script.error.map(ConfigurationValue.string) ?? .null
                result["text"] = .string(script.output.text)
                result["fields"] = .object((script.output.fields ?? [:]).mapValues(ConfigurationValue.string))
                result["values"] = .object((script.output.values ?? [:]).mapValues(ConfigurationValue.number))
            }
            return .object(result)
        }
        return .object(["configuration": .object(effectiveDocument),
                        "profiles": .array(activeProfiles.map(ConfigurationValue.string)),
                        "sessionEdits": .number(Double(sessionEdits.count)),
                        "error": configurationError.map(ConfigurationValue.string) ?? .null])
    }

    private func commandEnvironment(_ widget: WidgetConfiguration, configuration: Configuration) -> [String: String] {
        var environment = configuration.environment.merging(widget.environment) { _, widget in widget }
        environment["NAME"] = widget.id
        environment["CONFIG_DIR"] = configurationURL.deletingLastPathComponent().path
        return environment
    }

    func refreshScripts(for event: String, environment: [String: String] = [:]) {
        if event == "yabai" { workspaceStore.trigger() }
        var refreshed = Set<ObjectIdentifier>()
        for widget in configuration?.widgets ?? [] {
            let providerEvents: [String]
            if case let .provider(name) = widget.content { providerEvents = configuration!.providers[name]!.events }
            else { providerEvents = [] }
            if (widget.events + providerEvents).contains(event), let script = scripts[widget.id],
               refreshed.insert(ObjectIdentifier(script)).inserted {
                script.refresh(ScriptEvent(sender: event, environment: environment))
            }
        }
    }

    @discardableResult
    func runAction(_ command: String, widget: WidgetConfiguration,
                   event: ScriptEvent = ScriptEvent(sender: "mouse.clicked")) -> Task<Void, Never> {
        let id = UUID()
        let script = scripts[widget.id]
        let environment = event.commandEnvironment(commandEnvironment(widget, configuration: configuration!))
        let previous = actionTails[widget.id]?.task
        let task = Task {
            await previous?.value
            defer {
                actions.removeValue(forKey: id)
                if actionTails[widget.id]?.id == id { actionTails.removeValue(forKey: widget.id) }
            }
            do {
                try Task.checkCancellation()
                _ = try await runCommand("/bin/zsh", arguments: ["-c", command],
                                         timeout: widget.timeout, environment: environment)
                if let script, scripts[widget.id] === script {
                    script.refresh(ScriptEvent(sender: "action", environment: event.environment))
                }
                actionErrors[widget.id] = nil
            } catch {
                if Task.isCancelled { return }
                actionErrors[widget.id] = error.localizedDescription
            }
        }
        actions[id] = task
        actionTails[widget.id] = (id, task)
        return task
    }

    func openConfiguration() {
        NSWorkspace.shared.open(configurationURL)
    }

    func stop() {
        popup.close()
        reloadTask?.cancel()
        configurationWatcher.stop()
        workspaceStore.stop()
        for script in scripts.values { script.stop() }
        providers.removeAll()
        scripts.removeAll()
        for action in actions.values { action.cancel() }
        actions.removeAll()
        actionTails.removeAll()
        for observer in eventObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        if let reloadObserver { DistributedNotificationCenter.default().removeObserver(reloadObserver) }
        reloadObserver = nil
        eventObservers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

private func withoutShellVariables(_ environment: [String: String]) -> [String: String] {
    let shell = shellEnvironment.withLock { $0 }
    return environment.filter { shell[$0.key] == nil }
}
