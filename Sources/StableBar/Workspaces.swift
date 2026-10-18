import AppKit
import Observation
import os

struct Workspace: Decodable, Identifiable, Sendable, Equatable {
    let name: String
    let isFocused: Bool
    let isVisible: Bool
    let monitor: Int
    var apps: [WorkspaceApp] = []
    var id: String { name }

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

struct AeroSpaceEvent: Decodable, Sendable {
    let event: String?
    let mode: String?

    enum CodingKeys: String, CodingKey { case event = "_event", mode }
}

enum WorkspaceSource: String, Decodable, Sendable {
    case aerospace, yabai

    var title: String { self == .aerospace ? "AeroSpace" : "yabai" }
}

func workspaceSnapshot(workspaces: Data, windows: Data) throws -> [Workspace] {
    let apps = try JSONDecoder().decode([WorkspaceApp].self, from: windows)
    return try JSONDecoder().decode([Workspace].self, from: workspaces)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map { workspace in
            var workspace = workspace
            var bundleIDs = Set<String>()
            workspace.apps = apps.filter { $0.workspace == workspace.name && bundleIDs.insert($0.bundleID).inserted }
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
    var reconnectDelay: Duration = .seconds(2)
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
        task = Task {
            while !Task.isCancelled {
                do {
                    let stream = Process()
                    let output = Pipe()
                    stream.executableURL = URL(filePath: try executable())
                    stream.arguments = ["subscribe", "focused-workspace-changed", "focused-monitor-changed", "focus-changed",
                                        "window-detected", "mode-changed"]
                    stream.standardOutput = output
                    stream.standardError = FileHandle.standardError
                    let pending = OSAllocatedUnfairLock(initialState: Data())
                    let events = AsyncStream<AeroSpaceEvent> { continuation in
                        output.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty { continuation.finish(); return }
                            let parsed = pending.withLock { pending -> [AeroSpaceEvent] in
                                pending.append(data)
                                var parsed: [AeroSpaceEvent] = []
                                while let newline = pending.firstIndex(of: 10) {
                                    let line = Data(pending[..<newline])
                                    pending.removeSubrange(...newline)
                                    if let event = try? JSONDecoder().decode(AeroSpaceEvent.self, from: line) { parsed.append(event) }
                                }
                                return parsed
                            }
                            for event in parsed { continuation.yield(event) }
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
                    // subscribe sends the current mode immediately on every connection. Consume
                    // that initial snapshot and later events independently of workspace queries.
                    for await event in events {
                        try Task.checkCancellation()
                        receive(event)
                    }
                    throw CommandFailure(message: "AeroSpace disconnected. Reconnecting…")
                } catch {
                    if Task.isCancelled { return }
                    acceptMode(nil)
                    refreshTask?.cancel()
                    refreshTask = nil
                    refreshPending = false
                    connectionError = error.localizedDescription
                    if tracksWorkspaces { self.error = error.localizedDescription }
                }
                do { try await Task.sleep(for: reconnectDelay) }
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
        let executable = try executable()
        let snapshot: [Workspace]
        switch source {
        case .aerospace:
            async let spaces = runCommand(executable, arguments: [
                "list-workspaces", "--all", "--format",
                "%{workspace} %{workspace-is-focused} %{workspace-is-visible} %{monitor-appkit-nsscreen-screens-id}", "--json"
            ])
            async let windows = runCommand(executable, arguments: [
                "list-windows", "--all", "--format", "%{workspace} %{app-name} %{app-bundle-id}", "--json"
            ])
            snapshot = try await workspaceSnapshot(workspaces: spaces, windows: windows)
        case .yabai:
            async let spaces = runCommand(executable, arguments: ["-m", "query", "--spaces"])
            async let windows = runCommand(executable, arguments: ["-m", "query", "--windows"])
            async let displays = runCommand(executable, arguments: ["-m", "query", "--displays"])
            let screens = NSScreen.screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
            let bundleIDs = NSWorkspace.shared.runningApplications.reduce(into: [Int32: String]()) { result, app in
                result[app.processIdentifier] = app.bundleIdentifier
            }
            snapshot = try await yabaiSnapshot(spaces: spaces, windows: windows, displays: displays,
                                               screenIDs: screens, bundleIDs: bundleIDs)
        }
        try Task.checkCancellation()
        let previousWorkspace = workspaces.first(where: \.isFocused)?.name
        if workspaces != snapshot { workspaces = snapshot }
        if previousWorkspace != workspaces.first(where: \.isFocused)?.name { onWorkspaceChange?() }
        error = nil
    }

    func select(_ workspace: Workspace) {
        Task {
            do {
                let arguments = source == .aerospace ? ["workspace", workspace.name] : ["-m", "space", "--focus", workspace.name]
                _ = try await runCommand(executable(), arguments: arguments)
                if source == .yabai { try await refresh() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func executable() throws -> String {
        if let executablePath { return try executablePath() }
        let directories = shellEnvironment.withLock { $0["PATH"] ?? "" }.split(separator: ":")
        guard let directory = directories.first(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(source.rawValue)") }) else {
            throw CommandFailure(message: "\(source.title) is not on your login shell's PATH.")
        }
        return "\(directory)/\(source.rawValue)"
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
    }
}
