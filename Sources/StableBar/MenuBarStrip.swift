import AppKit

extension NSWindow.Level {
    /// Just above the status window level, where macOS 27 puts the menu bar's reveal strip.
    static let aboveMenuBarStrip = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
}

/// The top of each display as the window list shows it. In macOS 27, while the menu bar hides
/// automatically, MenuBarAgent covers the menu bar's area on a display with a notch with an
/// invisible strip above the bar. Clicking the strip shows the menu bar, and the click never
/// reaches the bar.
struct MenuBarStripState: Equatable {
    /// Points below the top edge where macOS starts revealing the menu bar.
    static let revealBand: CGFloat = 5

    private(set) var strips: Set<CGDirectDisplayID> = []
    private(set) var shownMenuBars: Set<CGDirectDisplayID> = []

    init() {}

    init(windows: [[String: Any]], displays: [CGDirectDisplayID: CGRect]) {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = (window[kCGWindowBounds as String] as! CFDictionary?).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { continue }
            for (id, display) in displays
            where bounds.minX <= display.minX + 1 && bounds.maxX >= display.maxX - 1 && bounds.minY <= display.minY + 1 {
                // Other apps put windows at the menu bar's level too, such as screencaptureui covering the whole display.
                let barSized = bounds.height < display.height / 4
                if layer == menuBarLevel, barSized, bounds.maxY > display.minY + 1 { shownMenuBars.insert(id) }
                if layer >= statusLevel, window[kCGWindowOwnerName as String] as? String == "MenuBarAgent",
                   bounds.minY >= display.minY - 1, barSized { strips.insert(id) }
            }
        }
    }

    /// Whether the bar on `display` sits above the strip: there is one, and the menu bar is hidden.
    func raisesBar(on display: CGDirectDisplayID) -> Bool {
        strips.contains(display) && !shownMenuBars.contains(display)
    }

    func showsMenuBar(on display: CGDirectDisplayID) -> Bool {
        shownMenuBars.contains(display)
    }

    static func nearsTop(_ pointer: CGPoint, of display: CGRect) -> Bool {
        display.minX <= pointer.x && pointer.x < display.maxX && pointer.y <= display.minY + revealBand
    }

    /// Checks often while the pointer is on a bar above a strip or a menu bar shows over one, and every
    /// two seconds while a bar sits on a display with a strip or a notch. The strip goes while the lock
    /// screen shows and comes back after it, when the bar lies below it and gets no mouse events.
    static func checkInterval(strips: Set<CGDirectDisplayID>, notched: Set<CGDirectDisplayID>,
                              shownMenuBars: Set<CGDirectDisplayID>, hovering: Bool) -> TimeInterval? {
        if hovering || !shownMenuBars.isDisjoint(with: strips) { return 1.0 / 30 }
        return strips.isEmpty && notched.isEmpty ? nil : 2
    }
}

/// Keeps each bar above the reveal strip while the menu bar is hidden, and below the menu bar
/// while macOS shows it, so clicks reach the bar and a revealed menu bar still covers it.
@MainActor
final class MenuBarStrip: NSResponder {
    private var panels: [CGDirectDisplayID: BarPanel] = [:]
    /// Displays with a notch, where macOS 27 puts the strip.
    private var notched: Set<CGDirectDisplayID> = []
    /// Displays with a strip, kept while their menu bar shows, since the strip may go meanwhile.
    private var strips: Set<CGDirectDisplayID> = []
    private var shownMenuBars: Set<CGDirectDisplayID> = []
    private var timer: Timer?
    private var interval: TimeInterval?

    func update(panels: [CGDirectDisplayID: BarPanel]) {
        for (id, panel) in panels where self.panels[id] !== panel {
            panel.contentView?.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                              owner: self))
        }
        self.panels = panels
        notched = Set(NSScreen.screens.compactMap { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            return panels[id] != nil && screen.auxiliaryTopLeftArea != nil ? id : nil
        })
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        interval = nil
    }

    override func mouseEntered(with event: NSEvent) {
        refresh()
    }

    private func refresh() {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let state = MenuBarStripState(windows: windows, displays: panels.keys.reduce(into: [:]) { $0[$1] = CGDisplayBounds($1) })
        for (id, panel) in panels {
            let level: NSWindow.Level = state.raisesBar(on: id) ? .aboveMenuBarStrip : .floating
            if panel.level != level { panel.level = level }
        }
        strips = state.strips.union(strips.intersection(state.shownMenuBars))
        shownMenuBars = state.shownMenuBars
        schedule()
    }

    /// Checks every two seconds also for a menu bar shown from the keyboard or auto-hide turned off.
    private func schedule() {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let hovering = strips.contains { id in
            panels[id].map { CGRect(x: $0.frame.minX, y: primaryTop - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
                .contains(pointer) } ?? false
        }
        let interval = MenuBarStripState.checkInterval(strips: strips, notched: notched, shownMenuBars: shownMenuBars, hovering: hovering)
        guard interval != self.interval else { return }
        stop()
        guard let interval else { return }
        self.interval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 10
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Reads the window list only where macOS reveals the menu bar, since it costs about a millisecond.
    private func tick() {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        if interval == 2 || !shownMenuBars.isDisjoint(with: strips)
            || strips.contains(where: { MenuBarStripState.nearsTop(pointer, of: CGDisplayBounds($0)) }) {
            refresh()
        } else {
            schedule()
        }
    }
}
