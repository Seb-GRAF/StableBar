import AppKit
import Observation
import os

struct Workspace: Decodable, Identifiable, Sendable, Equatable {
    let name: String
    let isFocused: Bool
    let isVisible: Bool
    let monitor: Int
    var apps: [WorkspaceApp] = []
    var windows: [WorkspaceWindow] = []
    /// A name the window manager shows instead of `name`, such as an OmniWM workspace's display name.
    var displayName: String?
    var id: String { name }
    var label: String { displayName ?? name }

    enum CodingKeys: String, CodingKey {
        case name = "workspace"
        case isFocused = "workspace-is-focused"
        case isVisible = "workspace-is-visible"
        case monitor = "monitor-appkit-nsscreen-screens-id"
    }
}

struct WorkspaceApp: Decodable, Identifiable, Sendable, Equatable {
    let workspace: String
    let name: String
    let bundleID: String
    var id: String { bundleID }

    enum CodingKeys: String, CodingKey {
        case workspace
        case name = "app-name"
        case bundleID = "app-bundle-id"
    }
}

struct WorkspaceWindow: Decodable, Identifiable, Sendable, Equatable {
    let id: Int
    let title: String
    let app: WorkspaceApp
    /// OmniWM's session-scoped window ID, which `omniwmctl window focus` takes instead of `id`.
    var reference: String?

    enum CodingKeys: String, CodingKey {
        case id = "window-id"
        case title = "window-title"
    }

    init(id: Int, title: String, app: WorkspaceApp, reference: String? = nil) {
        self.id = id
        self.title = title
        self.app = app
        self.reference = reference
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        app = try WorkspaceApp(from: decoder)
    }
}

struct AeroSpaceEvent: Decodable, Sendable {
    let event: String?
    let mode: String?

    enum CodingKeys: String, CodingKey { case event = "_event", mode }
}

enum WorkspaceSource: String, Decodable, Sendable {
    case aerospace, yabai, omniwm, spaces

    var title: String {
        switch self {
        case .aerospace: "AeroSpace"
        case .yabai: "yabai"
        case .omniwm: "OmniWM"
        case .spaces: "Spaces"
        }
    }

    /// The source's command on `path`, or the `omniwmctl` inside OmniWM's app. Spaces needs no command.
    func executable(path: String) -> String? {
        let name: String
        switch self {
        case .aerospace, .yabai: name = rawValue
        case .omniwm: name = "omniwmctl"
        case .spaces: return nil
        }
        if let directory = path.split(separator: ":").first(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }) {
            return "\(directory)/\(name)"
        }
        guard self == .omniwm,
              let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: omniwmBundleID)?
                .appending(path: "Contents/MacOS/omniwmctl").path,
              FileManager.default.isExecutableFile(atPath: bundled) else { return nil }
        return bundled
    }

    /// The window manager setup offers workspaces for: the configured one, else the first one installed.
    static func detected(path: String, preferring configured: WorkspaceSource) -> WorkspaceSource? {
        [configured, .aerospace, .yabai, .omniwm].first { $0.executable(path: path) != nil }
    }
}

func workspaceSnapshot(workspaces: Data, windows: Data) throws -> [Workspace] {
    let windows = try JSONDecoder().decode([WorkspaceWindow].self, from: windows)
    return try JSONDecoder().decode([Workspace].self, from: workspaces)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map { workspace in
            var workspace = workspace
            var bundleIDs = Set<String>()
            workspace.windows = windows.filter { $0.app.workspace == workspace.name }
            workspace.apps = workspace.windows.map(\.app).filter { bundleIDs.insert($0.bundleID).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return workspace
        }
}

@MainActor @Observable
final class WorkspaceStore {
    var source = WorkspaceSource.aerospace {
        didSet {
            if source != oldValue { stop(); workspaces = []; error = nil; connectionError = nil }
        }
    }
    var workspaces: [Workspace] = []
    var error: String?
    private(set) var connectionError: String?
    var reconnectDelay = 2.0
    var onWorkspaceChange: (() -> Void)?
    var onModeChange: ((String?) -> Void)?
    private(set) var mode: String?
    /// Injectable executable lookup lets lifecycle tests use a scratch event stream.
    var executablePath: (() throws -> String)?
    private(set) var tracksWorkspaces = true
    var isRunning: Bool { task != nil }
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var stopping = false
    private var task: Task<Void, Never>?
    private var process: Process?
    private var observers: [NSObjectProtocol] = []

    func workspaces(on monitor: Int, showEmpty: Bool) -> [Workspace] {
        workspaces.filter {
            $0.monitor == monitor && (showEmpty || $0.isVisible || !$0.apps.isEmpty)
        }
    }

    /// Retain the same subscription while either workspaces or presentation needs it.
    func configure(source: WorkspaceSource, workspaces: Bool, mode: Bool) {
        guard !stopping else { return }
        self.source = source
        let addedWorkspaces = workspaces && !tracksWorkspaces
        tracksWorkspaces = workspaces
        if !workspaces { error = nil }
        guard workspaces || (source == .aerospace && mode) else { stop(); return }
        if !isRunning { start() }
        else if addedWorkspaces { requestRefresh() }
    }

    func start() {
        cancelConnection()
        if source == .yabai {
            task = Task { }
            requestRefresh()
            return
        }
        if source == .spaces {
            task = Task { }
            let center = NSWorkspace.shared.notificationCenter
            observers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                              NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
                center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.requestRefresh() }
                }
            }
            requestRefresh()
            return
        }
        let omniwm = source == .omniwm
        let title = source.title
        observers = [NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    == (omniwm ? omniwmBundleID : "bobko.aerospace") else { return }
            MainActor.assumeIsolated { self?.start() }
        }]
        task = Task {
            var failures = 0
            while !Task.isCancelled {
                let started = ContinuousClock.now
                do {
                    let stream = Process()
                    let output = Pipe()
                    stream.executableURL = URL(filePath: try executable())
                    // Without --reconnect, omniwmctl exits when OmniWM quits, so this loop reports it and retries.
                    stream.arguments = omniwm
                        ? ["subscribe", "active-workspace,focused-monitor,focus,windows-changed,layout-changed,display-changed",
                           "--no-send-initial", "--format", "ndjson"]
                        : ["subscribe", "focused-workspace-changed", "focused-monitor-changed", "focus-changed",
                           "window-detected", "mode-changed"]
                    stream.standardOutput = output
                    stream.standardError = FileHandle.standardError
                    let pending = OSAllocatedUnfairLock(initialState: Data())
                    let lines = AsyncStream<Data> { continuation in
                        output.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty { continuation.finish(); return }
                            let parsed = pending.withLock { pending -> [Data] in
                                pending.append(data)
                                var parsed: [Data] = []
                                while let newline = pending.firstIndex(of: 10) {
                                    parsed.append(Data(pending[..<newline]))
                                    pending.removeSubrange(...newline)
                                }
                                return parsed
                            }
                            for line in parsed { continuation.yield(line) }
                        }
                        continuation.onTermination = { _ in output.fileHandleForReading.readabilityHandler = nil }
                    }
                    try Task.checkCancellation()
                    try stream.run()
                    process = stream
                    defer {
                        output.fileHandleForReading.readabilityHandler = nil
                        if stream.isRunning { stream.terminate() }
                    }
                    requestRefresh()
                    // AeroSpace's subscribe sends the current mode immediately on every connection. Consume
                    // that initial snapshot and later events independently of workspace queries.
                    var failure: String?
                    for await line in lines {
                        try Task.checkCancellation()
                        if omniwm { failure = receiveOmniWM(line) ?? failure }
                        else if let event = try? JSONDecoder().decode(AeroSpaceEvent.self, from: line) { receive(event) }
                    }
                    throw CommandFailure(message: failure ?? "\(title) disconnected. Reconnecting…")
                } catch {
                    if Task.isCancelled { return }
                    acceptMode(nil)
                    refreshTask?.cancel()
                    refreshTask = nil
                    refreshPending = false
                    connectionError = error.localizedDescription
                    if tracksWorkspaces { self.error = error.localizedDescription }
                }
                if started.duration(to: .now) >= .seconds(10) { failures = 0 }
                failures += 1
                do { try await Task.sleep(for: .seconds(providerRetryDelay(interval: reconnectDelay, failures: failures))) }
                catch { return }
            }
        }
    }

    func receive(_ event: AeroSpaceEvent) {
        guard source == .aerospace else { return }
        if event.event == "mode-changed" {
            acceptMode(event.mode)
            connectionError = nil
            if !tracksWorkspaces { error = nil }
        } else {
            requestRefresh()
        }
    }

    /// Refreshes on an event and returns the failure a line reports, such as IPC being off.
    private func receiveOmniWM(_ line: Data) -> String? {
        guard let response = try? JSONDecoder().decode(OmniWMResponse<OmniWMEmpty>.self, from: line) else { return nil }
        if !response.ok { return response.failureMessage }
        if response.kind == "event" { requestRefresh() } else { connectionError = nil }
        return nil
    }

    func acceptMode(_ mode: String?) {
        let next = source == .aerospace ? mode : nil
        guard self.mode != next else { return }
        self.mode = next
        onModeChange?(next)
    }

    private func requestRefresh() {
        guard tracksWorkspaces else { return }
        refreshPending = true
        guard refreshTask == nil else { return }
        refreshTask = Task {
            defer { if !Task.isCancelled { refreshTask = nil } }
            while refreshPending && !Task.isCancelled {
                refreshPending = false
                do { try await refresh() }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }

    private func refresh() async throws {
        let snapshot: [Workspace]
        switch source {
        case .aerospace:
            let executable = try executable()
            async let spaces = runCommand(executable, arguments: [
                "list-workspaces", "--all", "--format",
                "%{workspace} %{workspace-is-focused} %{workspace-is-visible} %{monitor-appkit-nsscreen-screens-id}", "--json"
            ])
            async let windows = runCommand(executable, arguments: [
                "list-windows", "--all", "--format", "%{workspace} %{app-name} %{app-bundle-id} %{window-id} %{window-title}", "--json"
            ])
            snapshot = try await workspaceSnapshot(workspaces: spaces, windows: windows)
        case .yabai:
            let executable = try executable()
            async let spaces = runCommand(executable, arguments: ["-m", "query", "--spaces"])
            async let windows = runCommand(executable, arguments: ["-m", "query", "--windows"])
            async let displays = runCommand(executable, arguments: ["-m", "query", "--displays"])
            let bundleIDs = NSWorkspace.shared.runningApplications.reduce(into: [Int32: String]()) { result, app in
                result[app.processIdentifier] = app.bundleIdentifier
            }
            snapshot = try await yabaiSnapshot(spaces: spaces, windows: windows, displays: displays,
                                               screenIDs: screenIDs, bundleIDs: bundleIDs)
        case .omniwm:
            let executable = try executable()
            async let spaces = omniwmCommand(executable, arguments: [
                "query", "workspaces", "--fields", "raw-name,display-name,display,is-visible,is-current"
            ])
            async let windows = omniwmCommand(executable, arguments: [
                "query", "windows", "--fields", "id,window-id,workspace,app,title,is-scratchpad"
            ])
            snapshot = try await omniwmSnapshot(workspaces: spaces, windows: windows, screenIDs: screenIDs)
        case .spaces:
            snapshot = try currentSpaces()
        }
        try Task.checkCancellation()
        let previousWorkspace = workspaces.first(where: \.isFocused)?.name
        if workspaces != snapshot { workspaces = snapshot }
        if previousWorkspace != workspaces.first(where: \.isFocused)?.name { onWorkspaceChange?() }
        error = nil
    }

    func select(_ workspace: Workspace) {
        switch source {
        case .spaces:
            do { try switchToDesktop(Int(workspace.name)!) }
            catch { self.error = error.localizedDescription }
        case .aerospace: run(["workspace", workspace.name])
        case .yabai: run(["-m", "space", "--focus", workspace.name])
        case .omniwm: run(["workspace", "focus-name", workspace.name])
        }
    }

    func focus(_ window: WorkspaceWindow) {
        switch source {
        case .spaces: NSRunningApplication.runningApplications(withBundleIdentifier: window.app.bundleID).first?.activate()
        case .aerospace: run(["focus", "--window-id", String(window.id)])
        case .yabai: run(["-m", "window", "--focus", String(window.id)])
        case .omniwm: if let reference = window.reference { run(["window", "focus", reference]) }
        }
    }

    /// yabai sends no events of its own, so its workspaces refresh after each click.
    private func run(_ arguments: [String]) {
        let source = source
        Task {
            do {
                if source == .omniwm { _ = try await omniwmCommand(executable(), arguments: arguments) }
                else { _ = try await runCommand(executable(), arguments: arguments) }
                if source == .yabai { try await refresh() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var screenIDs: [UInt32] {
        NSScreen.screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
    }

    private func executable() throws -> String {
        if let executablePath { return try executablePath() }
        guard let executable = source.executable(path: shellEnvironment.withLock { $0["PATH"] ?? "" }) else {
            throw CommandFailure(message: "\(source.title) is not on your login shell's PATH.")
        }
        return executable
    }

    func trigger() {
        if source == .yabai && isRunning { requestRefresh() }
    }

    func refreshForDisplayChange() {
        if isRunning { requestRefresh() }
    }

    func reconnect() {
        if isRunning { start() }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        cancelConnection()
        acceptMode(nil)
        connectionError = nil
    }

    private func cancelConnection() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        task?.cancel()
        task = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
}
