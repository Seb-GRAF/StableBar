import Foundation

private struct RiftDisplay: Decodable {
    let uuid: String
    let screenId: UInt32
    let isActiveSpace: Bool
    let isActiveContext: Bool
}

private struct RiftWorkspace: Decodable {
    let id: String
    let index: Int
    let name: String
    let isActive: Bool
    let windows: [Window]

    struct Window: Decodable {
        let id: ID
        let title: String
        let bundleId: String?
        let appName: String?
    }

    struct ID: Decodable { let pid: Int32; let idx: UInt32 }
}

func riftSnapshot(_ executable: String, screenIDs: [UInt32]) async throws -> [Workspace] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let displays = try decoder.decode([RiftDisplay].self, from: await runCommand(executable, arguments: ["query", "displays"]))
    var snapshot: [Workspace] = []
    for display in displays {
        guard display.isActiveSpace, let monitor = screenIDs.firstIndex(of: display.screenId) else { continue }
        let data = try await runCommand(executable, arguments: ["query", "workspaces", "--display", display.uuid])
        snapshot += try decoder.decode([RiftWorkspace].self, from: data).map { space in
            var apps: [WorkspaceApp] = []
            var seen = Set<String>()
            let windows = space.windows.map { window in
                let appName = window.appName ?? ""
                let app = WorkspaceApp(workspace: space.id, name: appName, bundleID: window.bundleId ?? appName)
                if seen.insert(app.bundleID).inserted { apps.append(app) }
                return WorkspaceWindow(id: Int(window.id.idx), title: window.title, app: app,
                                       reference: #"{"pid":\#(window.id.pid),"idx":\#(window.id.idx)}"#)
            }
            return Workspace(name: space.id, isFocused: space.isActive && display.isActiveContext, isVisible: space.isActive, monitor: monitor + 1,
                             apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                             windows: windows, displayName: space.name, riftDisplay: display.uuid, riftIndex: space.index)
        }
    }
    return snapshot
}
