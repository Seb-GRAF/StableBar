import AppKit
@preconcurrency import ApplicationServices
import Observation

struct WindowClearanceDisplay: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let barFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect, configuration: Configuration, display: BarDisplay, desktopTop: CGFloat) {
        let geometry = configuration.barGeometry(for: display)
        let top = frame.maxY - configuration.onScreen(ScreenKind(display)).bar.offset
        self.init(frame: frame, visibleFrame: visibleFrame,
                  barFrame: CGRect(x: frame.minX, y: top - geometry.panelHeight, width: frame.width, height: geometry.panelHeight),
                  desktopTop: desktopTop)
    }

    init(frame: CGRect, visibleFrame: CGRect, barFrame: CGRect, desktopTop: CGFloat) {
        self.frame = CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
        self.visibleFrame = CGRect(x: visibleFrame.minX, y: desktopTop - visibleFrame.maxY,
                                   width: visibleFrame.width, height: visibleFrame.height)
        self.barFrame = CGRect(x: barFrame.minX, y: desktopTop - barFrame.maxY,
                               width: barFrame.width, height: barFrame.height)
    }
}

private let notificationCenterIdentifier = "com.apple.notificationcenterui"

private func barDisplay(for frame: CGRect, in displays: [WindowClearanceDisplay]) -> WindowClearanceDisplay? {
    let overlaps = displays.map { display in
        let intersection = frame.intersection(display.frame)
        return (display, intersection.isNull ? 0 : intersection.width * intersection.height)
    }
    guard let (display, area) = overlaps.max(by: { $0.1 < $1.1 }), area > 0,
          display.barFrame.intersects(display.frame) else { return nil }
    return display
}

func frameBelowBar(_ frame: CGRect, displays: [WindowClearanceDisplay]) -> CGRect? {
    guard let display = barDisplay(for: frame, in: displays) else { return nil }
    let top = max(display.visibleFrame.minY, display.barFrame.maxY)
    let height = min(frame.height, display.visibleFrame.maxY - top)
    guard frame.minY < top, height > 0 else { return nil }
    return CGRect(x: frame.minX, y: top, width: frame.width, height: height)
}

func originBelowBar(_ window: CGRect, bannerTop: CGFloat, displays: [WindowClearanceDisplay]) -> CGPoint? {
    guard let display = barDisplay(for: window, in: displays), window.origin == display.frame.origin else { return nil }
    let bannerMargin = 16.0
    let offset = display.barFrame.maxY + bannerMargin - bannerTop
    guard offset > 0 else { return nil }
    return CGPoint(x: window.minX, y: window.minY + offset)
}

enum NotificationElement { case banner, list, other }

func firstBanner<Element: Hashable>(in window: Element, limit: Int = 200, kind: (Element) -> NotificationElement,
                                    children: (Element) -> [Element]) -> Element? {
    var elements = [window]
    var visited: Set<Element> = []
    var next = 0
    while next < elements.count, visited.count < limit {
        let element = elements[next]
        next += 1
        guard visited.insert(element).inserted else { continue }
        switch kind(element) {
        case .banner: return element
        case .list: return nil
        case .other: elements += children(element)
        }
    }
    return nil
}

@MainActor @Observable
final class WindowClearance: NSObject {
    private(set) var isTrusted = AXIsProcessTrusted()
    private var displays: [WindowClearanceDisplay] = []
    private var keepsWindowsClear = false
    private var keepsNotificationsClear = false
    private var applications: [pid_t: WatchedApplication] = [:]
    private var notificationCenter: (pid: pid_t, element: AXUIElement, observer: AXObserver)?
    private var runningApplications: NSKeyValueObservation?
    private var permissionTimer: Timer?
    private var pending: Set<pid_t> = []
    private var task: Task<Void, Never>?

    private struct WatchedApplication {
        let element: AXUIElement
        let observer: AXObserver
        var windows: [AXUIElement] = []
        var adjustedFrames: [AXUIElement: CGRect] = [:]
    }

    func update(windows: Bool, notifications: Bool, displays: [WindowClearanceDisplay]) {
        if self.displays != displays {
            self.displays = displays
            for pid in applications.keys { applications[pid]!.adjustedFrames.removeAll() }
        }
        keepsWindowsClear = windows
        keepsNotificationsClear = notifications
        guard windows || notifications else { stop(); return }
        if permissionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
            permissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                         NSWorkspace.activeSpaceDidChangeNotification] {
                center.addObserver(self, selector: #selector(applicationsChanged), name: name, object: nil)
            }
            runningApplications = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
                guard ((change.oldValue ?? []) + (change.newValue ?? [])).contains(where: {
                    $0.bundleIdentifier == notificationCenterIdentifier
                }) else { return }
                MainActor.assumeIsolated { self?.applicationsChanged() }
            }
        }
        refreshPermission()
        applicationsChanged()
    }

    func requestAccess() {
        requestAccessibility()
        refreshPermission()
    }

    private func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted { applicationsChanged() }
        else { removeObservers() }
    }

    @objc private func applicationsChanged() {
        guard permissionTimer != nil, isTrusted else { return }
        let running = NSWorkspace.shared.runningApplications.filter {
            keepsWindowsClear && $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        for (pid, application) in applications where !running.contains(where: { $0.processIdentifier == pid }) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(application.observer), .commonModes)
            applications.removeValue(forKey: pid)
        }
        for app in running {
            let pid = app.processIdentifier
            if applications[pid] == nil {
                var observer: AXObserver?
                guard AXObserverCreate(pid, { _, element, _, context in
                    MainActor.assumeIsolated {
                        var pid: pid_t = 0
                        guard AXUIElementGetPid(element, &pid) == .success else { return }
                        Unmanaged<WindowClearance>.fromOpaque(context!).takeUnretainedValue().schedule(pid)
                    }
                }, &observer) == .success, let observer else { continue }
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.1)
                applications[pid] = WatchedApplication(element: element, observer: observer)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            let application = applications[pid]!
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(application.observer, application.element, name as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
            if !app.isHidden { schedule(pid) }
        }
        watchNotificationCenter()
    }

    private func watchNotificationCenter() {
        let pid = keepsNotificationsClear
            ? NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterIdentifier).first?.processIdentifier : nil
        guard pid != notificationCenter?.pid else { return }
        if let notificationCenter {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(notificationCenter.observer), .commonModes)
        }
        notificationCenter = nil
        var observer: AXObserver?
        guard let pid, AXObserverCreate(pid, { _, _, _, context in
            MainActor.assumeIsolated { Unmanaged<WindowClearance>.fromOpaque(context!).takeUnretainedValue().moveBanners() }
        }, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.1)
        notificationCenter = (pid, element, observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        moveBanners()
    }

    private func moveBanners() {
        guard let notificationCenter,
              let windows = attribute(kAXWindowsAttribute, of: notificationCenter.element) as? [AXUIElement] else { return }
        for window in windows {
            guard let banner = banner(in: window), let frame = windowFrame(window), let top = windowFrame(banner)?.minY,
                  var origin = originBelowBar(frame, bannerTop: top, displays: displays) else { continue }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        }
    }

    private func banner(in window: AXUIElement) -> AXUIElement? {
        firstBanner(in: window, kind: { element in
            AXUIElementSetMessagingTimeout(element, 0.1)
            if attribute(kAXIdentifierAttribute, of: element) as? String == "AXNotificationListItems" { return .list }
            return (attribute(kAXSubroleAttribute, of: element) as? String)?.hasPrefix("AXNotificationCenter") == true
                ? .banner : .other
        }, children: { attribute(kAXChildrenAttribute, of: $0) as? [AXUIElement] ?? [] })
    }

    private func schedule(_ pid: pid_t) {
        guard permissionTimer != nil, isTrusted else { return }
        pending.insert(pid)
        task?.cancel()
        task = Task { [weak self] in
            do {
                repeat { try await Task.sleep(for: .milliseconds(150)) }
                while NSEvent.pressedMouseButtons != 0
                guard let self else { return }
                let pids = pending
                pending.removeAll()
                task = nil
                refreshPermission()
                guard isTrusted, permissionTimer != nil else { return }
                for pid in pids { adjustWindows(pid) }
            } catch {}
        }
    }

    private func adjustWindows(_ pid: pid_t) {
        guard var application = applications[pid],
              NSRunningApplication(processIdentifier: pid)?.isHidden == false,
              let windows = attribute(kAXWindowsAttribute, of: application.element) as? [AXUIElement] else { return }
        let notifications = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                             kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification]
        for window in application.windows where !windows.contains(window) {
            for name in notifications { AXObserverRemoveNotification(application.observer, window, name as CFString) }
            application.adjustedFrames.removeValue(forKey: window)
        }
        for window in windows {
            if !application.windows.contains(window) {
                AXUIElementSetMessagingTimeout(window, 0.1)
                for name in notifications {
                    AXObserverAddNotification(application.observer, window, name as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                }
            }
            guard attribute(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole,
                  attribute(kAXMinimizedAttribute, of: window) as? Bool == false,
                  attribute("AXFullScreen", of: window) as? Bool != true,
                  let frame = windowFrame(window), frame != application.adjustedFrames[window],
                  let target = frameBelowBar(frame, displays: displays) else { continue }
            var movable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success,
                  movable.boolValue else { continue }
            application.adjustedFrames[window] = frame
            if target.size != frame.size {
                var resizable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success,
                      resizable.boolValue else { continue }
                var size = target.size
                if AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!) == .success {
                    schedule(pid)
                }
                continue
            }
            var position = target.origin
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &position)!)
        }
        application.windows = windows
        applications[pid] = application
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: window), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute, of: window), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func removeObservers() {
        task?.cancel()
        task = nil
        pending.removeAll()
        for application in applications.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(application.observer), .commonModes)
        }
        applications.removeAll()
        if let notificationCenter {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(notificationCenter.observer), .commonModes)
        }
        notificationCenter = nil
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        runningApplications = nil
        removeObservers()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
