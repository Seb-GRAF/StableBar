import AppKit
@preconcurrency import ApplicationServices
import Observation

struct WindowClearanceDisplay: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let barFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect, configuration: Configuration, display: BarDisplay, desktopTop: CGFloat) {
        let geometry = configuration.barGeometry(for: display)
        let top = frame.maxY - configuration.bar.offset
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

func frameBelowBar(_ frame: CGRect, displays: [WindowClearanceDisplay]) -> CGRect? {
    let overlaps = displays.map { display in
        let intersection = frame.intersection(display.frame)
        return (display, intersection.isNull ? 0 : intersection.width * intersection.height)
    }
    guard let (display, area) = overlaps.max(by: { $0.1 < $1.1 }), area > 0,
          display.barFrame.intersects(display.frame) else { return nil }
    let top = max(display.visibleFrame.minY, display.barFrame.maxY)
    let height = min(frame.height, display.visibleFrame.maxY - top)
    guard frame.minY < top, height > 0 else { return nil }
    return CGRect(x: frame.minX, y: top, width: frame.width, height: height)
}

@MainActor @Observable
final class WindowClearance: NSObject {
    private(set) var isTrusted = AXIsProcessTrusted()
    private var displays: [WindowClearanceDisplay] = []
    private var applications: [pid_t: WatchedApplication] = [:]
    private var permissionTimer: Timer?
    private var pending: Set<pid_t> = []
    private var task: Task<Void, Never>?

    private struct WatchedApplication {
        let element: AXUIElement
        let observer: AXObserver
        var windows: [AXUIElement] = []
        var adjustedFrames: [AXUIElement: CGRect] = [:]
    }

    func update(enabled: Bool, displays: [WindowClearanceDisplay]) {
        if self.displays != displays {
            self.displays = displays
            for pid in applications.keys { applications[pid]!.adjustedFrames.removeAll() }
        }
        guard enabled else { stop(); return }
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
        }
        refreshPermission()
        applicationsChanged()
    }

    func requestAccess() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
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
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        removeObservers()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
