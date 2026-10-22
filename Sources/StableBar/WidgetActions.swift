import AppKit
import SwiftUI

struct WidgetActions: Decodable, Sendable {
    var rightClick: String?
    var middleClick: String?
    var scrollUp: String?
    var scrollDown: String?
    var mouseEntered: String?
    var mouseExited: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case rightClick, middleClick, scrollUp, scrollDown, mouseEntered, mouseExited }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rightClick = try values.decodeIfPresent(String.self, forKey: .rightClick)
        middleClick = try values.decodeIfPresent(String.self, forKey: .middleClick)
        scrollUp = try values.decodeIfPresent(String.self, forKey: .scrollUp)
        scrollDown = try values.decodeIfPresent(String.self, forKey: .scrollDown)
        mouseEntered = try values.decodeIfPresent(String.self, forKey: .mouseEntered)
        mouseExited = try values.decodeIfPresent(String.self, forKey: .mouseExited)
    }
}

enum OpenTarget {
    case url(URL)
    case application(String)

    init?(_ value: String) {
        if let url = URL(string: value), let scheme = url.scheme {
            guard ["http", "https", "mailto", "x-apple.systempreferences"].contains(scheme.lowercased()) else { return nil }
            self = .url(url)
        } else if value.contains("."),
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) {
            self = .application(value)
        } else {
            return nil
        }
    }

    func open() {
        switch self {
        case let .url(url): NSWorkspace.shared.open(url)
        case let .application(identifier):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { NSWorkspace.shared.open(url) }
        }
    }
}

/// Asks whether to quit process `pid`, naming it or the app it is, then quits it or, with Force Quit, ends it at once.
@MainActor func confirmQuit(_ pid: pid_t) {
    let app = NSRunningApplication(processIdentifier: pid)
    var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    proc_name(pid, &name, UInt32(name.count))
    let alert = NSAlert()
    alert.messageText = "Quit “\(app?.localizedName ?? name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })”?"
    alert.informativeText = "Force Quit ends it at once, losing any unsaved changes."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Force Quit")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response != .alertThirdButtonReturn else { return }
    let force = response == .alertSecondButtonReturn
    if let app {
        _ = force ? app.forceTerminate() : app.terminate()
    } else if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
        NSAlert(error: POSIXError(POSIXErrorCode(rawValue: errno)!)).runModal()
    }
}

struct WidgetActionContext: Sendable {
    let sender: String
    var button: String?
    var modifiers: NSEvent.ModifierFlags = []
    var scrollDelta: Double?
    let display: Int

    var environment: [String: String] {
        let modifierNames: [(NSEvent.ModifierFlags, String)] = [
            (.shift, "shift"), (.control, "ctrl"), (.option, "alt"), (.command, "cmd"), (.function, "fn")
        ]
        var values = [
            "MODIFIER": modifierNames.filter { modifiers.contains($0.0) }.map { $0.1 }.joined(separator: " "),
            "SID": String(display)
        ]
        if let button { values["BUTTON"] = button }
        if let scrollDelta { values["SCROLL_DELTA"] = String(scrollDelta) }
        return values
    }
}

struct WidgetActionCapture: NSViewRepresentable {
    let actions: WidgetActions
    let display: Int
    let perform: (String, WidgetActionContext) -> Void

    func makeNSView(context: Context) -> WidgetActionView {
        WidgetActionView(actions: actions, display: display, perform: perform)
    }

    func updateNSView(_ nsView: WidgetActionView, context: Context) {
        nsView.actions = actions
        nsView.display = display
        nsView.perform = perform
    }
}

final class WidgetActionView: NSView {
    var actions: WidgetActions
    var display: Int
    var perform: (String, WidgetActionContext) -> Void

    init(actions: WidgetActions, display: Int, perform: @escaping (String, WidgetActionContext) -> Void) {
        self.actions = actions
        self.display = display
        self.perform = perform
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("WidgetActionView is created programmatically.") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
        return command(for: event) == nil ? nil : self
    }

    override func rightMouseDown(with event: NSEvent) {
        if let command = command(for: event) {
            perform(command, WidgetActionContext(sender: "mouse.clicked", button: "right",
                                                modifiers: event.modifierFlags, display: display))
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if let command = command(for: event) {
            perform(command, WidgetActionContext(sender: "mouse.clicked", button: "middle",
                                                modifiers: event.modifierFlags, display: display))
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let command = command(for: event) {
            perform(command, WidgetActionContext(sender: "mouse.scrolled", modifiers: event.modifierFlags,
                                                scrollDelta: event.scrollingDeltaY, display: display))
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func command(for event: NSEvent) -> String? {
        switch event.type {
        case .rightMouseDown: actions.rightClick
        case .otherMouseDown where event.buttonNumber == 2: actions.middleClick
        case .scrollWheel where event.scrollingDeltaY > 0: actions.scrollUp
        case .scrollWheel where event.scrollingDeltaY < 0: actions.scrollDown
        default: nil
        }
    }
}
