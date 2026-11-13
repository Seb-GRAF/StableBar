import Foundation

private struct YabaiSpace: Decodable {
    let index: Int
    let display: Int
    let isFocused: Bool
    let isVisible: Bool

    enum CodingKeys: String, CodingKey {
        case index, display
        case isFocused = "has-focus"
        case isVisible = "is-visible"
    }
}

private struct YabaiWindow: Decodable {
    let id: Int
    let title: String
    let pid: Int32
    let app: String
    let space: Int
    let hasFocus: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, pid, app, space
        case hasFocus = "has-focus"
    }
}

private struct YabaiDisplay: Decodable {
    let id: UInt32
    let index: Int
}

/// The same bounded, read-only snapshot for the running widget and setup's connection check.
func readYabaiWorkspaces(_ executable: String, screenIDs: [UInt32], bundleIDs: [Int32: String],
                         timeout: Double = 10) async throws -> [Workspace] {
    async let spaces = runCommand(executable, arguments: ["-m", "query", "--spaces"], timeout: timeout)
    async let windows = runCommand(executable, arguments: ["-m", "query", "--windows"], timeout: timeout)
    async let displays = runCommand(executable, arguments: ["-m", "query", "--displays"], timeout: timeout)
    return try await yabaiSnapshot(spaces: spaces, windows: windows, displays: displays,
                                   screenIDs: screenIDs, bundleIDs: bundleIDs)
}

func yabaiSnapshot(spaces: Data, windows: Data, displays: Data,
                   screenIDs: [UInt32], bundleIDs: [Int32: String]) throws -> [Workspace] {
    let windows = try JSONDecoder().decode([YabaiWindow].self, from: windows)
    let displays = try JSONDecoder().decode([YabaiDisplay].self, from: displays)
    return try JSONDecoder().decode([YabaiSpace].self, from: spaces)
        .sorted { $0.index < $1.index }
        .compactMap { space in
            guard let display = displays.first(where: { $0.index == space.display }),
                  let monitor = screenIDs.firstIndex(of: display.id) else { return nil }
            let name = String(space.index)
            var apps: [WorkspaceApp] = []
            var workspaceWindows: [WorkspaceWindow] = []
            var seen = Set<String>()
            for window in windows where window.space == space.index {
                let bundleID = bundleIDs[window.pid] ?? window.app
                let app = WorkspaceApp(workspace: name, name: window.app, bundleID: bundleID)
                workspaceWindows.append(WorkspaceWindow(id: window.id, title: window.title, app: app, isFocused: window.hasFocus == true))
                if seen.insert(bundleID).inserted {
                    apps.append(app)
                }
            }
            return Workspace(name: name, isFocused: space.isFocused, isVisible: space.isVisible, monitor: monitor + 1,
                             apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                             windows: workspaceWindows)
        }
}
