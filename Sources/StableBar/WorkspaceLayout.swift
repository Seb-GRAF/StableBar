import Observation

/// The workspaces a widget shows on one display.
struct WorkspaceFilter: Hashable {
    let monitor: Int
    let showEmpty: Bool
    var hideApps: [String] = []
    var hideWorkspaces: [String] = []

    func apply(to workspaces: [Workspace]) -> [Workspace] {
        workspaces.compactMap { workspace in
            guard shows(workspace) else { return nil }
            var workspace = workspace
            workspace.apps.removeAll(where: hides)
            workspace.windows.removeAll { hides($0.app) }
            return workspace
        }
    }

    /// Whether no workspace is shown, without filtering their apps and windows.
    func isEmpty(in workspaces: [Workspace]) -> Bool {
        !workspaces.contains(where: shows)
    }

    private func shows(_ workspace: Workspace) -> Bool {
        guard workspace.monitor == monitor, workspace.isFocused || !hideWorkspaces.contains(workspace.name) else { return false }
        return showEmpty || workspace.isVisible || workspace.apps.contains { !hides($0) }
    }

    private func hides(_ app: WorkspaceApp) -> Bool {
        hideApps.contains { appMatches(app, key: $0) }
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
            let isEmpty = filter.isEmpty(in: workspaces)
            if flag.isEmpty != isEmpty { flag.isEmpty = isEmpty }
        }
    }

    /// Whether `filter` leaves its display without workspaces.
    func isEmpty(_ filter: WorkspaceFilter) -> Bool {
        if let flag = emptiness[filter] { return flag.isEmpty }
        let flag = WorkspaceEmptiness(isEmpty: filter.isEmpty(in: workspaces))
        emptiness[filter] = flag
        return flag.isEmpty
    }
}

@MainActor @Observable
private final class WorkspaceEmptiness {
    var isEmpty: Bool

    init(isEmpty: Bool) { self.isEmpty = isEmpty }
}
