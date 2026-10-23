import Foundation

let omniwmBundleID = "com.barut.OmniWM"

/// The envelope `omniwmctl` prints for every response, event and local failure.
struct OmniWMResponse<Payload: Decodable>: Decodable {
    let ok: Bool
    let kind: String?
    let code: String?
    let message: String?
    let result: Body?

    struct Body: Decodable { let payload: Payload? }

    var failureMessage: String {
        code == "transport_failure"
            ? "Can't reach OmniWM. Check that it's running and that Enable IPC is on in its menu."
            : "OmniWM: \(message ?? code ?? "request failed")"
    }
}

/// Accepts any payload, for envelopes read only for their status.
struct OmniWMEmpty: Decodable {
    init(from decoder: Decoder) throws {}
}

private struct OmniWMWorkspaces: Decodable {
    let workspaces: [Space]

    struct Space: Decodable {
        let rawName: String
        let displayName: String?
        let display: Display?
        let isVisible: Bool
        let isCurrent: Bool
    }

    struct Display: Decodable { let id: String }
}

private struct OmniWMWindows: Decodable {
    let windows: [Window]

    struct Window: Decodable {
        let id: String
        let windowId: Int
        let workspace: Workspace?
        let app: App?
        let title: String?
        let isScratchpad: Bool?
    }

    struct Workspace: Decodable { let rawName: String }
    struct App: Decodable { let name: String; let bundleId: String? }
}

/// Runs `omniwmctl` with JSON output. A request that changes nothing succeeds; other failures read as sentences.
func omniwmCommand(_ executable: String, arguments: [String]) async throws -> Data {
    do {
        return try await runCommand(executable, arguments: arguments + ["--format", "json"])
    } catch let failure as CommandFailure {
        guard let response = try? JSONDecoder().decode(OmniWMResponse<OmniWMEmpty>.self, from: failure.stdout),
              !response.ok else { throw failure }
        if response.code == "no_change" { return failure.stdout }
        throw CommandFailure(message: response.failureMessage)
    }
}

private func omniwmPayload<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
    let response = try JSONDecoder().decode(OmniWMResponse<Payload>.self, from: data)
    guard response.ok, let payload = response.result?.payload else { throw CommandFailure(message: response.failureMessage) }
    return payload
}

/// OmniWM's own order is the order of its workspace bar. Its current workspace is the focused one, as
/// AeroSpace reports it, even when it holds no focused window.
func omniwmSnapshot(workspaces: Data, windows: Data, screenIDs: [UInt32]) throws -> [Workspace] {
    let windows = try omniwmPayload(OmniWMWindows.self, from: windows).windows
    return try omniwmPayload(OmniWMWorkspaces.self, from: workspaces).workspaces.compactMap { space in
        guard let display = space.display?.id.split(separator: ":").last.flatMap({ UInt32($0) }),
              let monitor = screenIDs.firstIndex(of: display) else { return nil }
        var apps: [WorkspaceApp] = []
        var seen = Set<String>()
        let workspaceWindows = windows.filter { $0.workspace?.rawName == space.rawName && $0.isScratchpad != true }.map { window in
            let name = window.app?.name ?? ""
            let app = WorkspaceApp(workspace: space.rawName, name: name, bundleID: window.app?.bundleId ?? name)
            if seen.insert(app.bundleID).inserted { apps.append(app) }
            return WorkspaceWindow(id: window.windowId, title: window.title ?? "", app: app, reference: window.id)
        }
        return Workspace(name: space.rawName, isFocused: space.isCurrent, isVisible: space.isVisible, monitor: monitor + 1,
                         apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                         windows: workspaceWindows,
                         displayName: space.displayName == space.rawName ? nil : space.displayName)
    }
}
