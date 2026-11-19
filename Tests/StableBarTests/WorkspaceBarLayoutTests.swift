import Foundation
import Observation
import Testing
@testable import StableBar

private let laptop = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil)
private let terminal = WorkspaceApp(workspace: "1", name: "Terminal", bundleID: "com.apple.Terminal")

@MainActor private func makeStore() throws -> BarStore {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"spaces","type":"workspaces","position":"left","workspace":{"windows":true}},
                {"id":"clock","type":"text","text":"12:00","position":"right"}]}
    """#.utf8))
    store.barPresentation.preparePresentations()
    return store
}

/// Workspace 1 holds a terminal; workspace 2 is empty. Both are on `monitor`.
private func workspaces(focused: String?, title: String = "zsh", monitor: Int = 1) -> [Workspace] {
    [Workspace(name: "1", isFocused: focused == "1", isVisible: focused == "1", monitor: monitor, apps: [terminal],
               windows: [WorkspaceWindow(id: 1, title: title, app: terminal)]),
     Workspace(name: "2", isFocused: focused == "2", isVisible: focused == "2", monitor: monitor)]
}

/// Counts how often the widgets the bar lays out on `display` are invalidated while `change` runs.
@MainActor private func invalidations(of store: BarStore, on display: BarDisplay, _ change: () -> Void) -> Int {
    let count = Count()
    withObservationTracking { _ = store.barEditing.widgets(on: display) } onChange: { count.add() }
    change()
    return count.value
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Test @MainActor func switchingWorkspacesLeavesTheBarsWidgetsValid() throws {
    let store = try makeStore()
    store.workspaceStore.workspaces = workspaces(focused: "1")
    #expect(invalidations(of: store, on: laptop) { store.workspaceStore.workspaces = workspaces(focused: "2") } == 0)
    #expect(invalidations(of: store, on: laptop) { store.workspaceStore.workspaces = workspaces(focused: "2", title: "vim") } == 0)
    #expect(invalidations(of: store, on: laptop) { store.workspaceStore.error = nil } == 0)
    #expect(store.barEditing.widgets(on: laptop).map(\.id) == ["spaces", "clock"])
}

@Test @MainActor func aWorkspaceWidgetLeavesTheBarWhenItsDisplayHasNothingToShow() throws {
    let store = try makeStore()
    store.workspaceStore.workspaces = workspaces(focused: "1")
    #expect(store.barEditing.widgets(on: laptop).map(\.id) == ["spaces", "clock"])
    #expect(invalidations(of: store, on: laptop) { store.workspaceStore.workspaces = workspaces(focused: "1", monitor: 2) } == 1)
    #expect(store.barEditing.widgets(on: laptop).map(\.id) == ["clock"])
    #expect(invalidations(of: store, on: laptop) { store.workspaceStore.workspaces = workspaces(focused: "2") } == 1)
    #expect(store.barEditing.widgets(on: laptop).map(\.id) == ["spaces", "clock"])
}

@Test func aFiltersEmptinessMatchesTheWorkspacesItShows() {
    let notes = WorkspaceApp(workspace: "3", name: "Notes", bundleID: "com.apple.Notes")
    let spaces = [
        Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1, apps: [terminal],
                  windows: [WorkspaceWindow(id: 1, title: "zsh", app: terminal)]),
        Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1),
        Workspace(name: "3", isFocused: true, isVisible: true, monitor: 2, apps: [notes]),
        Workspace(name: "4", isFocused: false, isVisible: true, monitor: 3)
    ]
    let filters = [
        WorkspaceFilter(monitor: 1, showEmpty: false),
        WorkspaceFilter(monitor: 1, showEmpty: false, hideApps: ["Terminal"]),
        WorkspaceFilter(monitor: 1, showEmpty: true, hideApps: ["Terminal"]),
        WorkspaceFilter(monitor: 1, showEmpty: true, hideWorkspaces: ["1", "2"]),
        WorkspaceFilter(monitor: 2, showEmpty: false, hideApps: ["com.apple.Notes"], hideWorkspaces: ["3"]),
        WorkspaceFilter(monitor: 3, showEmpty: false),
        WorkspaceFilter(monitor: 4, showEmpty: true)
    ]
    #expect(filters.map { $0.isEmpty(in: spaces) } == [false, true, false, true, false, false, true])
    for filter in filters { #expect(filter.isEmpty(in: spaces) == filter.apply(to: spaces).isEmpty) }
}

@Test @MainActor func focusMovingToAnotherDisplayMovesOnlyWidgetsShownOnTheActiveDisplay() throws {
    let store = try makeStore()
    let external = BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)
    let notes = WorkspaceApp(workspace: "2", name: "Notes", bundleID: "com.apple.Notes")
    /// Workspace 1 on the laptop and workspace 2 on the external display, each with a window.
    func displays(focused: String) -> [Workspace] {
        [Workspace(name: "1", isFocused: focused == "1", isVisible: true, monitor: 1, apps: [terminal],
                   windows: [WorkspaceWindow(id: 1, title: "zsh", app: terminal)]),
         Workspace(name: "2", isFocused: focused == "2", isVisible: true, monitor: 2, apps: [notes],
                   windows: [WorkspaceWindow(id: 2, title: "Notes", app: notes)])]
    }
    store.workspaceStore.workspaces = displays(focused: "1")
    #expect(invalidations(of: store, on: laptop) { store.workspaceStore.workspaces = displays(focused: "2") } == 0)

    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"clock","type":"text","text":"12:00","position":"right","display":"active"}]}
    """#.utf8))
    store.barPresentation.preparePresentations()
    #expect(store.barEditing.widgets(on: external).map(\.id) == ["clock"])
    #expect(invalidations(of: store, on: external) { store.workspaceStore.workspaces = displays(focused: "1") } == 1)
    #expect(store.barEditing.widgets(on: external).isEmpty)
    #expect(store.barEditing.widgets(on: laptop).map(\.id) == ["clock"])
}
