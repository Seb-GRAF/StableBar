import AppKit
import ApplicationServices

/// Hides or shows the macOS menu bar. It hides only on a macOS that also lets StableBar reveal it on one display,
/// which opening an app menu from the bar needs; without those private calls, the menu bar stays as it is.
func setMenuBarHidden(_ hidden: Bool, canReveal: Bool = PrivateAPI.setMenuBarVisibilityOverride != nil,
                      setAlpha: ((Int32, Double, Double, Float) -> CGError)? = PrivateAPI.setMenuBarInsetAndAlpha) {
    guard !hidden || canReveal, let connection = PrivateAPI.mainConnectionID?(), let setAlpha else { return }
    _ = setAlpha(connection, 0, 1, hidden ? 0 : 1)
}

/// Reveals or hides the hidden macOS menu bar on one display. On a macOS without the private call, nothing changes.
func setMenuBarShown(_ shown: Bool, on display: CGDirectDisplayID) {
    guard let connection = PrivateAPI.mainConnectionID?(), let set = PrivateAPI.setMenuBarVisibilityOverride else { return }
    _ = set(connection, display, shown)
}

struct MenuBarHover {
    /// Points below the top edge where the pointer waits. macOS 27 reveals the menu bar from
    /// anywhere within 4 points of the edge and tracks the pointer down to 5.
    static let holdDepth: CGFloat = 6

    let milliseconds: Double
    let menuBars: [CGRect]
    private(set) var deadline: TimeInterval?
    private var hoveredBar: CGRect?
    private var revealed = false

    init(milliseconds: Double, menuBars: [CGRect]) {
        self.milliseconds = milliseconds
        self.menuBars = menuBars
    }

    mutating func move(_ point: CGPoint, now: TimeInterval) -> CGPoint {
        let bar = menuBars.first { $0.contains(point) }
        if bar != hoveredBar {
            deadline = nil
            revealed = false
            hoveredBar = bar
        }
        guard let bar else { return point }
        if point.y > bar.minY + Self.holdDepth {
            deadline = nil
        } else if !revealed {
            if deadline == nil { deadline = now + milliseconds / 1000 }
            if now >= deadline! {
                deadline = nil
                revealed = true
            } else {
                return CGPoint(x: point.x, y: bar.minY + Self.holdDepth)
            }
        }
        return point
    }

    mutating func reveal(_ point: CGPoint, now: TimeInterval) -> CGPoint? {
        guard let deadline, now >= deadline else { return nil }
        _ = move(point, now: now)
        guard revealed, let hoveredBar else { return nil }
        return CGPoint(x: point.x, y: hoveredBar.minY)
    }

    mutating func cancel() {
        deadline = nil
        hoveredBar = nil
        revealed = false
    }
}

@MainActor
final class MenuBarDelay {
    private var hover = MenuBarHover(milliseconds: 0, menuBars: [])
    private var tap: CFMachPort?
    private var revealTimer: Timer?
    private var permissionTimer: Timer?

    func update(milliseconds: Double, menuBars: [CGRect]) {
        if hover.milliseconds != milliseconds || hover.menuBars != menuBars {
            cancelReveal()
            hover = MenuBarHover(milliseconds: milliseconds, menuBars: menuBars)
        }
        guard milliseconds > 0 else { stop(); return }
        if permissionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAccess() }
            }
            permissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        refreshAccess()
    }

    private func refreshAccess() {
        guard AXIsProcessTrusted(), UserDefaults.standard.bool(forKey: "_HIHideMenuBar") else {
            removeTap()
            return
        }
        guard tap == nil else { return }
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue,
            callback: { _, type, event, context in
                MainActor.assumeIsolated {
                    let delay = Unmanaged<MenuBarDelay>.fromOpaque(context!).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        delay.removeTap()
                    } else {
                        delay.move(event)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func move(_ event: CGEvent) {
        let previous = hover.deadline
        event.location = hover.move(event.location, now: ProcessInfo.processInfo.systemUptime)
        if previous != hover.deadline {
            revealTimer?.invalidate()
            revealTimer = nil
            if let deadline = hover.deadline {
                let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reveal() }
                }
                revealTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func reveal() {
        guard let point = hover.reveal(CGEvent(source: nil)!.location, now: ProcessInfo.processInfo.systemUptime) else { return }
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
        event.post(tap: .cghidEventTap)
    }

    private func cancelReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        hover.cancel()
    }

    private func removeTap() {
        cancelReveal()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        removeTap()
    }
}
