import Observation

/// The workspaces a widget shows on one display.
struct WorkspaceFilter: Hashable {
    let monitor: Int
    let showEmpty: Bool
    var hideApps: [String] = []
    var hideWorkspaces: [String] = []

    func apply(to workspaces: [Workspace]) -> [Workspace] {
        workspaces.compactMap { workspace in
            guard workspace.monitor == monitor, workspace.isFocused || !hideWorkspaces.contains(workspace.name) else { return nil }
            var workspace = workspace
            workspace.apps.removeAll { app in hideApps.contains { appMatches(app, key: $0) } }
            workspace.windows.removeAll { window in hideApps.contains { appMatches(window.app, key: $0) } }
            return showEmpty || workspace.isVisible || !workspace.apps.isEmpty ? workspace : nil
        }
    }
}

/// What the bar's layout reads from the workspaces: the focused workspace's monitor, and whether a display has
/// workspaces to show. Both change far less often than the workspaces, so reading them doesn't lay out every
/// widget on every display again for each switch, focus change or window title.
@MainActor @Observable
final class WorkspaceLayout {
    private(set) var focusedMonitor: Int?
    /// A copy of the workspaces that views don't observe.
    @ObservationIgnored private var workspaces: [Workspace] = []
    /// One flag per filter asked about, so a change invalidates only the widgets that use that filter.
    @ObservationIgnored private var emptiness: [WorkspaceFilter: WorkspaceEmptiness] = [:]

    func update(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        let focused = workspaces.first(where: \.isFocused)?.monitor
        if focusedMonitor != focused { focusedMonitor = focused }
        for (filter, flag) in emptiness {
            let isEmpty = filter.apply(to: workspaces).isEmpty
            if flag.isEmpty != isEmpty { flag.isEmpty = isEmpty }
        }
    }

    /// Whether `filter` leaves its display without workspaces.
    func isEmpty(_ filter: WorkspaceFilter) -> Bool {
        if let flag = emptiness[filter] { return flag.isEmpty }
        let flag = WorkspaceEmptiness(isEmpty: filter.apply(to: workspaces).isEmpty)
        emptiness[filter] = flag
        return flag.isEmpty
    }
}

@MainActor @Observable
private final class WorkspaceEmptiness {
    var isEmpty: Bool

    init(isEmpty: Bool) { self.isEmpty = isEmpty }
}
