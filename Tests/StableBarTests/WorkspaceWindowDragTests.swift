import AppKit
import SwiftUI
import Testing
@testable import StableBar

@Test(arguments: [WorkspaceSource.aerospace, .yabai], [1, 2]) @MainActor
func workspaceWindowDropMovesCapturedWindowsAndRefreshes(source: WorkspaceSource, count: Int) async throws {
    let fixture = try WorkspaceMoveFixture(source: source, movedIDs: Array([73, 74].prefix(count)))
    defer { fixture.close() }
    let store = fixture.store
    let windows = Array(store.workspaces[0].windows.prefix(count))
    let payload = try #require(store.windowDrag.begin(source: source, windows: windows))
    store.windowDrag.target = fixture.destination
    let move = try #require(store.moveWindows(payload, to: fixture.destination))
    #expect(store.moveWindows(payload, to: fixture.destination) == nil)
    #expect(store.windowDrag.active == nil)
    #expect(store.windowDrag.target == nil)
    await move.value
    #expect(store.error == nil)
    #expect(store.workspaces.first(where: { $0.name == fixture.destination })?.windows.map(\.id) == Array([73, 74].prefix(count)))
    #expect(store.workspaces.first(where: { $0.name == "1" })?.windows.map(\.id) == (count == 1 ? [74, 75] : [75]))
    #expect(store.workspaces.first(where: \.isFocused)?.name == "1")
    let commands = try fixture.commands()
    for id in [73, 74].prefix(count) {
        #expect(commands.contains(source == .aerospace
            ? "<move-node-to-workspace><--window-id><\(id)><--><\(fixture.destination)>"
            : "<-m><window><\(id)><--space><\(fixture.destination)>"))
    }
    #expect(commands.count == count + 3)
}

@Test(arguments: [WorkspaceSource.aerospace, .yabai]) @MainActor
func workspaceWindowDropRefreshesPartialMovesAndKeepsTheFailure(source: WorkspaceSource) async throws {
    let fixture = try WorkspaceMoveFixture(source: source, movedIDs: [73], failureID: 74)
    defer { fixture.close() }
    let payload = try #require(fixture.store.windowDrag.begin(source: source, windows: Array(fixture.store.workspaces[0].windows.prefix(2))))
    let move = try #require(fixture.store.moveWindows(payload, to: fixture.destination))
    await move.value
    #expect(fixture.store.error == "Window no longer exists")
    #expect(fixture.store.workspaces.first(where: { $0.name == "1" })?.windows.map(\.id) == [74, 75])
    #expect(fixture.store.workspaces.first(where: { $0.name == fixture.destination })?.windows.map(\.id) == [73])
}

/// The bar can still show a window its manager has taken off every workspace: AeroSpace sends no event when a
/// window leaves, such as when a menu bar app hides its window. Clicking or dragging that window fails.
@Test(arguments: [WorkspaceSource.aerospace, .yabai], [false, true]) @MainActor
func workspaceWindowFailuresDropAWindowThatLeftEveryWorkspace(source: WorkspaceSource, drag: Bool) async throws {
    let fixture = try WorkspaceMoveFixture(source: source, movedIDs: [], failureID: 73, goneIDs: [73])
    defer { fixture.close() }
    let window = fixture.store.workspaces[0].windows[0]
    let task: Task<Void, Never>
    if drag {
        let payload = try #require(fixture.store.windowDrag.begin(source: source, windows: [window]))
        task = try #require(fixture.store.moveWindows(payload, to: fixture.destination))
    } else {
        task = try #require(fixture.store.focus(window))
    }
    await task.value
    #expect(fixture.store.error == nil, "The failure points at an icon that is gone")
    #expect(fixture.store.workspaces.first(where: { $0.name == "1" })?.windows.map(\.id) == [74, 75])
}

@Test(arguments: [WorkspaceSource.aerospace, .yabai]) @MainActor
func workspaceAppDropSkipsAWindowThatLeftEveryWorkspaceAndMovesTheRest(source: WorkspaceSource) async throws {
    let fixture = try WorkspaceMoveFixture(source: source, movedIDs: [74], failureID: 73, goneIDs: [73])
    defer { fixture.close() }
    let finder = fixture.store.workspaces[0].windows.filter { $0.app.bundleID == "com.apple.finder" }
    let payload = try #require(fixture.store.windowDrag.begin(source: source, windows: finder))
    await (try #require(fixture.store.moveWindows(payload, to: fixture.destination))).value
    #expect(fixture.store.error == nil)
    #expect(try fixture.commands().contains(source == .aerospace
        ? "<move-node-to-workspace><--window-id><74><--><\(fixture.destination)>"
        : "<-m><window><74><--space><\(fixture.destination)>"), "The other window still moves")
    #expect(fixture.store.workspaces.first(where: { $0.name == fixture.destination })?.windows.map(\.id) == [74])
}

@Test(arguments: [WorkspaceSource.aerospace, .yabai]) @MainActor
func workspaceWindowFocusRefreshesAndKeepsTheFailureOfAListedWindow(source: WorkspaceSource) async throws {
    let fixture = try WorkspaceMoveFixture(source: source, movedIDs: [], failureID: 73)
    defer { fixture.close() }
    let task = try #require(fixture.store.focus(fixture.store.workspaces[0].windows[0]))
    await task.value
    #expect(fixture.store.error == "Window no longer exists")
    let commands = try fixture.commands()
    #expect(commands.contains(source == .aerospace ? "<focus><--window-id><73>" : "<-m><window><--focus><73>"))
    #expect(commands.count == 4, "The workspaces are read again after the failure")
}

@Test @MainActor func workspaceWindowDropRejectsStaleForeignAndUnsupportedMoves() throws {
    let store = WorkspaceStore()
    defer { store.stop() }
    store.workspaces = dragWorkspaces()
    let windows = Array(store.workspaces[0].windows.prefix(1))
    let payload = try #require(store.windowDrag.begin(source: .aerospace, windows: windows))
    #expect(store.canMoveWindows(payload, to: "2")) // another display is a valid destination
    #expect(!store.canMoveWindows(payload, to: "1"))
    #expect(!store.canMoveWindows(payload, to: "missing"))
    let foreign = WorkspaceWindowDragSession()
    let other = try #require(foreign.begin(source: .aerospace, windows: windows))
    #expect(store.moveWindows(other, to: "2") == nil)
    store.workspaces[0].windows.removeFirst()
    #expect(store.moveWindows(payload, to: "2") == nil)
    store.source = .yabai
    #expect(store.windowDrag.active == nil)
    #expect(store.moveWindows(payload, to: "2") == nil)
    #expect(store.windowDrag.begin(source: .spaces, windows: windows) == nil)
    #expect(store.windowDrag.begin(source: .omniwm, windows: windows) == nil)
    #expect(store.windowDrag.begin(source: .aerospace, windows: []) == nil)
}

@Test @MainActor func workspaceWindowNativeGestureKeepsClicksAndCancelsWithoutMoving() throws {
    let store = WorkspaceStore()
    defer { store.stop() }
    store.workspaces = dragWorkspaces()
    let before = store.workspaces
    let source = CapturingWorkspaceWindowDragSource(rootView: AnyView(Text("Finder").frame(width: 60, height: 24)))
    source.frame = CGRect(x: 0, y: 0, width: 60, height: 24)
    source.store = store
    source.windows = Array(store.workspaces[0].windows.prefix(1))
    var clicks = 0
    source.action = { clicks += 1 }
    source.mouseDown(with: try workspaceMouse(.leftMouseDown, x: 5))
    source.mouseDragged(with: try workspaceMouse(.leftMouseDragged, x: 8))
    source.mouseUp(with: try workspaceMouse(.leftMouseUp, x: 8))
    #expect(clicks == 1)
    #expect(store.windowDrag.active == nil)
    source.mouseDown(with: try workspaceMouse(.leftMouseDown, x: 5))
    source.mouseDragged(with: try workspaceMouse(.leftMouseDragged, x: 10))
    source.mouseDragged(with: try workspaceMouse(.leftMouseDragged, x: 15))
    source.mouseUp(with: try workspaceMouse(.leftMouseUp, x: 15))
    #expect(clicks == 1)
    #expect(source.items.count == 1)
    let payload = try #require(store.windowDrag.active)
    let item = try #require(source.items.first?.item as? NSPasteboardItem)
    #expect(item.string(forType: WorkspaceWindowDragSourceView.pasteboardType) == payload.token.uuidString)
    store.windowDrag.target = "2"
    source.endWindowDrag()
    #expect(store.windowDrag.active == nil)
    #expect(store.windowDrag.target == nil)
    #expect(store.moveWindows(payload, to: "2") == nil)
    #expect(store.workspaces == before)
    let newer = store.windowDrag.begin(source: .aerospace, windows: source.windows)
    source.endWindowDrag()
    #expect(store.windowDrag.active == newer)
    store.source = .spaces
    source.mouseDown(with: try workspaceMouse(.leftMouseDown, x: 5))
    source.mouseDragged(with: try workspaceMouse(.leftMouseDragged, x: 10))
    #expect(store.windowDrag.active == nil)
    #expect(source.items.count == 1)
}

@Test(arguments: [false, true]) @MainActor
func workspaceWindowDragShowsEmptyTargetsAndKeepsWindowGrouping(windows: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"bar":{"height":40},"widgets":[{"id":"spaces","type":"workspaces","position":"left",
      "workspace":{"windows":\(windows),"titleLength":20,"appGlyphs":{"*":"F"}}}]}
    """.utf8))
    var workspaces = dragWorkspaces()
    workspaces[1] = Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1)
    let fixture = OffscreenBar(configuration: configuration,
        display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, workspaces: workspaces)
    defer { fixture.close() }
    await fixture.settle()
    let items = workspaceDragSources(fixture.host)
    #expect(items.count == (windows ? 3 : 2))
    #expect(items.map { $0.windows.map(\.id) } == (windows ? [[73], [74], [75]] : [[73, 74], [75]]))
    let anchor = try #require(fixture.anchors("spaces").first)
    let resting = anchor.convert(anchor.bounds, to: fixture.host)
    let payload = try #require(fixture.store.workspaceStore.windowDrag.begin(source: .aerospace, windows: items[0].windows))
    await fixture.settle()
    let dragging = anchor.convert(anchor.bounds, to: fixture.host)
    #expect(dragging.width > resting.width)
    #expect(dragging.height == resting.height)
    fixture.store.workspaceStore.windowDrag.end(payload)
    await fixture.settle()
    #expect(anchor.convert(anchor.bounds, to: fixture.host) == resting)
    fixture.store.barEditing.begin()
    await fixture.settle()
    #expect(workspaceDragSources(fixture.host).isEmpty)
    #expect(workspaceDropTargets(fixture.host).isEmpty)
    #expect(!fixture.panel.isVisible)
}

@Test(arguments: [WorkspaceSource.aerospace, .yabai], [WorkspaceSource.omniwm, .spaces]) @MainActor
func workspaceWindowDragDisablesWhenTheManagerBecomesUnsupported(source: WorkspaceSource, unsupported: WorkspaceSource) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"height":40},"widgets":[{"id":"spaces","type":"workspaces","position":"left",
      "workspace":{"appGlyphs":{"*":"F"}}}]}
    """#.utf8))
    var workspaces = dragWorkspaces()
    workspaces[1] = Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1)
    let fixture = OffscreenBar(configuration: configuration,
        display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600)
    defer { fixture.close() }
    let store = fixture.store.workspaceStore
    store.source = source
    store.workspaces = workspaces
    await fixture.settle()
    let items = workspaceDragSources(fixture.host)
    #expect(items.count == 2)
    let item = try #require(items.first)
    let payload = try #require(store.windowDrag.begin(source: source, windows: item.windows))
    store.windowDrag.target = "2"
    await fixture.settle()
    let anchor = try #require(fixture.anchors("spaces").first)
    let draggingWidth = anchor.bounds.width
    store.source = unsupported
    store.workspaces = workspaces
    await fixture.settle()
    #expect(store.windowDrag.active == nil)
    #expect(store.windowDrag.target == nil)
    #expect(workspaceDragSources(fixture.host).isEmpty)
    #expect(workspaceDropTargets(fixture.host).isEmpty)
    #expect(store.windowDrag.begin(source: unsupported, windows: item.windows) == nil)
    #expect(!store.canMoveWindows(payload, to: "2"))
    #expect(store.moveWindows(payload, to: "2") == nil)
    let unsupportedAnchor = try #require(fixture.anchors("spaces").first)
    #expect(unsupportedAnchor.bounds.width < draggingWidth)
    #expect(!fixture.panel.isVisible)
}

@MainActor private func workspaceDragSources(_ view: NSView) -> [WorkspaceWindowDragSourceView] {
    (view as? WorkspaceWindowDragSourceView).map { [$0] } ?? view.subviews.flatMap(workspaceDragSources)
}

@MainActor private func workspaceDropTargets(_ view: NSView) -> [WorkspaceWindowDropTargetView] {
    (view as? WorkspaceWindowDropTargetView).map { [$0] } ?? view.subviews.flatMap(workspaceDropTargets)
}

@Test(arguments: [false, true]) @MainActor
func workspaceWindowDropMovesIconsToTheDestination(windows: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"bar":{"height":40,"style":{"background":"#1e1e24"}},"widgets":[
      {"id":"spaces","type":"workspaces","position":"left","workspace":{"windows":\##(windows),"titleLength":20}},
      {"id":"clock","type":"text","text":"14:32","position":"right"}]}
    """##.utf8))
    let fixture = OffscreenBar(configuration: configuration,
        display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600)
    defer { fixture.close() }
    let move = try WorkspaceMoveFixture(source: .aerospace, movedIDs: windows ? [73] : [73, 74],
                                        store: fixture.store.workspaceStore, destination: "2")
    defer { move.close() }
    func capture(_ name: String) throws {
        if ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"] != nil {
            _ = try fixture.bitmap(name: "\(name)-\(windows ? "windows" : "apps")")
        }
    }
    move.store.workspaces[1] = Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1)
    await fixture.settle()
    try capture("workspace-window-drag-before")
    let item = try #require(workspaceDragSources(fixture.host).first)
    let payload = try #require(move.store.windowDrag.begin(source: .aerospace, windows: item.windows))
    await fixture.settle()
    // AppKit finds drop destinations by view frames, which SwiftUI leaves outside the cells'
    // containers, so a registered cell inside the bar would be unreachable.
    func registered(_ view: NSView) -> [NSView] {
        (view.registeredDraggedTypes.contains(WorkspaceWindowDragSourceView.pasteboardType) ? [view] : [])
            + view.subviews.flatMap(registered)
    }
    #expect(registered(fixture.host).isEmpty)
    let target = try #require(workspaceDropTargets(fixture.host).first(where: { $0.workspace == "2" }))
    let origin = try #require(workspaceDropTargets(fixture.host).first(where: { $0.workspace == "1" }))
    func location(_ view: NSView, x: CGFloat) -> NSPoint { view.convert(NSPoint(x: x, y: view.bounds.midY), to: nil) }
    let info = WorkspaceDraggingInfo(source: item, token: payload.token.uuidString, window: fixture.panel)
    defer { info.draggingPasteboard.releaseGlobally() }
    info.draggingLocation = location(origin, x: origin.bounds.midX)
    #expect(fixture.panel.draggingEntered(info).isEmpty)
    #expect(!fixture.panel.performDragOperation(info))
    for x in [target.bounds.minX + 0.5, target.bounds.midX] {
        info.draggingLocation = location(target, x: x)
        #expect(fixture.panel.draggingUpdated(info) == .move, "The label and cell padding must route the drag to the workspace")
        #expect(move.store.windowDrag.target == "2")
    }
    info.draggingLocation = NSPoint(x: fixture.panel.frame.width - 10, y: 20)
    #expect(fixture.panel.draggingUpdated(info).isEmpty)
    #expect(move.store.windowDrag.target == nil)
    info.draggingLocation = location(target, x: target.bounds.midX)
    #expect(fixture.panel.draggingUpdated(info) == .move)
    fixture.panel.draggingExited(info)
    #expect(move.store.windowDrag.target == nil)
    #expect(fixture.panel.draggingEntered(info) == .move)
    #expect(fixture.panel.prepareForDragOperation(info))
    await fixture.settle()
    try capture("workspace-window-drag-target")
    #expect(fixture.panel.performDragOperation(info))
    let task = try #require(move.store.moveTask)
    #expect(!fixture.panel.performDragOperation(info))
    await task.value
    await fixture.settle()
    #expect(workspaceDragSources(fixture.host).map { $0.windows.map(\.id) } == (windows ? [[74], [75], [73]] : [[75], [73, 74]]))
    #expect(move.store.workspaces.first(where: \.isFocused)?.name == "1")
    try capture("workspace-window-drag-after")
    #expect(!fixture.panel.isVisible)
}

@Test @MainActor func workspaceNativeDropRejectsForeignAndCancelledDrags() throws {
    let store = WorkspaceStore()
    defer { store.stop() }
    store.workspaces = dragWorkspaces()
    let windows = Array(store.workspaces[0].windows.prefix(1))
    let payload = try #require(store.windowDrag.begin(source: .aerospace, windows: windows))
    let source = WorkspaceWindowDragSourceView(rootView: AnyView(Text("Finder")))
    source.store = store
    let target = WorkspaceWindowDropTargetView(rootView: AnyView(Text("2")))
    target.store = store
    target.workspace = "2"
    let wrongToken = WorkspaceDraggingInfo(source: source, token: UUID().uuidString)
    let external = WorkspaceDraggingInfo(source: nil, token: payload.token.uuidString)
    let valid = WorkspaceDraggingInfo(source: source, token: payload.token.uuidString)
    defer {
        for info in [wrongToken, external, valid] { info.draggingPasteboard.releaseGlobally() }
    }
    for info in [wrongToken, external] {
        #expect(target.draggingEntered(info).isEmpty)
        #expect(!target.prepareForDragOperation(info))
        #expect(!target.performDragOperation(info))
    }
    #expect(target.draggingEntered(valid) == .move)
    target.draggingExited(valid)
    #expect(store.windowDrag.target == nil)
    store.windowDrag.end(payload)
    #expect(target.draggingUpdated(valid).isEmpty)
    #expect(!target.performDragOperation(valid))
    #expect(store.moveTask == nil)
}

@MainActor private final class WorkspaceDraggingInfo: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingSequenceNumber = 1
    var draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(source: Any?, token: String, window: NSWindow? = nil) {
        draggingSource = source
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.setString(token, forType: WorkspaceWindowDragSourceView.pasteboardType)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private func dragWorkspaces(destination: String = "2") -> [Workspace] {
    let finder = WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")
    let terminal = WorkspaceApp(workspace: "1", name: "Terminal", bundleID: "com.apple.Terminal")
    return [
        Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1, apps: [finder, terminal], windows: [
            WorkspaceWindow(id: 73, title: "First document", app: finder),
            WorkspaceWindow(id: 74, title: "Second document", app: finder),
            WorkspaceWindow(id: 75, title: "Shell", app: terminal)
        ]),
        Workspace(name: destination, isFocused: false, isVisible: false, monitor: 2)
    ]
}

@MainActor private final class CapturingWorkspaceWindowDragSource: WorkspaceWindowDragSourceView {
    var items: [NSDraggingItem] = []
    override func beginWindowDrag(with item: NSDraggingItem, event: NSEvent) { items.append(item) }
}

private func workspaceMouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 5), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor private final class WorkspaceMoveFixture {
    let store: WorkspaceStore
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let destination: String

    /// `goneIDs` are windows the manager no longer lists, although the store's snapshot still shows them.
    init(source: WorkspaceSource, movedIDs: [Int], failureID: Int? = nil, goneIDs: [Int] = [], store: WorkspaceStore? = nil,
         destination requestedDestination: String? = nil) throws {
        _ = NSApplication.shared
        self.store = store ?? WorkspaceStore()
        destination = requestedDestination ?? (source == .aerospace ? "-two words" : "2")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "window-manager")
        let windows = dragWorkspaces()[0].windows.filter { !goneIDs.contains($0.id) }
        let spaces: [[String: Any]]
        let snapshot: [[String: Any]]
        if source == .aerospace {
            spaces = ["1", destination].map { ["workspace": $0, "workspace-is-focused": $0 == "1",
                "workspace-is-visible": $0 == "1", "monitor-appkit-nsscreen-screens-id": 1] }
            snapshot = windows.map { ["workspace": movedIDs.contains($0.id) ? destination : "1",
                "app-name": $0.app.name, "app-bundle-id": $0.app.bundleID, "window-id": $0.id, "window-title": $0.title] }
        } else {
            spaces = [1, 2].map { ["index": $0, "display": 1, "has-focus": $0 == 1, "is-visible": $0 == 1] }
            snapshot = windows.map { ["space": movedIDs.contains($0.id) ? 2 : 1, "pid": 0,
                "app": $0.app.name, "id": $0.id, "title": $0.title] }
            let screen = try #require(NSScreen.screens.first)
            let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            try JSONSerialization.data(withJSONObject: [["id": id.uint32Value, "index": 1]])
                .write(to: directory.appending(path: "displays.json"))
        }
        try JSONSerialization.data(withJSONObject: spaces).write(to: directory.appending(path: "spaces.json"))
        try JSONSerialization.data(withJSONObject: snapshot).write(to: directory.appending(path: "windows.json"))
        try Data("""
        #!/bin/sh
        cd '\(directory.path)' || exit 1
        {
            printf '<%s>' "$@"
            printf '\\n'
        } > "calls.$$"
        if [ "$1" = move-node-to-workspace ] || [ "$1" = focus ] || [ "$2" = window ]; then
            for argument in "$@"; do
                if [ "$argument" = '\(failureID ?? -1)' ]; then
                    echo 'Window no longer exists' >&2
                    exit 1
                fi
            done
            exit 0
        fi
        case "$1" in
            list-workspaces) cat spaces.json ;;
            list-windows) cat windows.json ;;
            -m)
                case "$3" in
                    --spaces) cat spaces.json ;;
                    --windows) cat windows.json ;;
                    --displays) cat displays.json ;;
                esac ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        self.store.source = source
        self.store.workspaces = dragWorkspaces(destination: destination)
        self.store.executablePath = { executable.path }
    }

    func commands() throws -> [String] {
        // Snapshot queries run concurrently, so each process writes its own record.
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("calls.") }
            .map { try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .newlines) }
    }

    func close() {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
