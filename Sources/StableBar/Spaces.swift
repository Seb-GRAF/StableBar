import AppKit

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ connection: Int32) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray

private struct ManagedDisplay: Decodable {
    let identifier: String
    let currentSpace: ManagedSpace
    let spaces: [ManagedSpace]

    enum CodingKeys: String, CodingKey {
        case identifier = "Display Identifier"
        case currentSpace = "Current Space"
        case spaces = "Spaces"
    }
}

private struct ManagedSpace: Decodable {
    let id: UInt64
    let type: Int

    enum CodingKeys: String, CodingKey {
        case id = "ManagedSpaceID"
        case type
    }
}

private struct SpaceWindow: Decodable {
    let id: Int
    let pid: Int32
    let app: String
    let title: String?
    let layer: Int

    enum CodingKeys: String, CodingKey {
        case id = "kCGWindowNumber"
        case pid = "kCGWindowOwnerPID"
        case app = "kCGWindowOwnerName"
        case title = "kCGWindowName"
        case layer = "kCGWindowLayer"
    }
}

func spacesSnapshot(displays: Data, windows: Data, windowSpaces: [Int: [UInt64]], activeSpace: UInt64,
                    screenUUIDs: [String], bundleIDs: [Int32: String]) throws -> [Workspace] {
    let windows = try PropertyListDecoder().decode([SpaceWindow].self, from: windows)
        .filter { $0.layer == 0 && bundleIDs[$0.pid] != nil }
    var number = 0
    return try PropertyListDecoder().decode([ManagedDisplay].self, from: displays).flatMap { display in
        let monitor = display.identifier == "Main" ? 0 : screenUUIDs.firstIndex(of: display.identifier)
        return display.spaces.filter { $0.type == 0 }.compactMap { space -> Workspace? in
            number += 1
            guard let monitor else { return nil }
            let name = String(number)
            var apps: [WorkspaceApp] = []
            var workspaceWindows: [WorkspaceWindow] = []
            var seen = Set<String>()
            for window in windows where windowSpaces[window.id]?.contains(space.id) == true {
                let app = WorkspaceApp(workspace: name, name: window.app, bundleID: bundleIDs[window.pid]!)
                workspaceWindows.append(WorkspaceWindow(id: window.id, title: window.title ?? "", app: app))
                if seen.insert(app.bundleID).inserted {
                    apps.append(app)
                }
            }
            return Workspace(name: name, isFocused: space.id == activeSpace, isVisible: space.id == display.currentSpace.id,
                             monitor: monitor + 1,
                             apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                             windows: workspaceWindows)
        }
    }
}

func currentSpaces() throws -> [Workspace] {
    let connection = CGSMainConnectionID()
    let info = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as! [[String: Any]]
    let windowSpaces = info.reduce(into: [Int: [UInt64]]()) { result, window in
        let id = window[kCGWindowNumber as String] as! Int
        result[id] = CGSCopySpacesForWindows(connection, 7, [id] as CFArray) as? [UInt64]
    }
    let screens = NSScreen.screens.map { screen in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        return CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(id).takeRetainedValue()) as String
    }
    let bundleIDs = NSWorkspace.shared.runningApplications.reduce(into: [Int32: String]()) { result, app in
        if app.activationPolicy == .regular { result[app.processIdentifier] = app.bundleIdentifier }
    }
    return try spacesSnapshot(
        displays: PropertyListSerialization.data(fromPropertyList: CGSCopyManagedDisplaySpaces(connection), format: .binary, options: 0),
        windows: PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
        windowSpaces: windowSpaces, activeSpace: CGSGetActiveSpace(connection), screenUUIDs: screens, bundleIDs: bundleIDs)
}

func switchToDesktop(_ number: Int) throws {
    let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    guard let hotKey = hotKeys?[String(117 + number)] as? [String: Any], hotKey["enabled"] as? Bool == true,
          let parameters = (hotKey["value"] as? [String: Any])?["parameters"] as? [Int] else {
        throw CommandFailure(message: "Turn on “Switch to Desktop \(number)” in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
    }
    guard AXIsProcessTrusted() else {
        throw CommandFailure(message: "Allow StableBar in System Settings → Privacy & Security → Accessibility to switch Spaces.")
    }
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(parameters[1]), keyDown: keyDown)!
        event.flags = CGEventFlags(rawValue: UInt64(parameters[2]))
        event.post(tap: .cghidEventTap)
    }
}
