import CoreMediaIO
import Foundation

/// Whether any app uses a camera, from CoreMediaIO. Its listeners follow the camera list and each
/// camera's use. It reads properties only and opens no stream, so macOS doesn't ask for Camera access.
final class CameraMonitor: ChangeMonitor, @unchecked Sendable {
    private let relay = MainQueueRelay()
    private let queue = DispatchQueue(label: "StableBar.CameraMonitor")
    // The listener state below is only touched on `queue`, where CoreMediaIO delivers the listeners.
    private var systemListener: CMIOObjectPropertyListenerBlock?
    private var cameras: [CMIOObjectID] = []
    private var cameraListener: CMIOObjectPropertyListenerBlock?

    private static let devicesAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    private static let runningAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

    func read() throws -> ScriptOutput {
        let inUse = try Self.devices().contains { camera in
            var address = Self.runningAddress
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(camera, &address, 0, nil, size, &size, &running) == noErr && running != 0
        }
        return ScriptOutput(text: inUse ? "On" : "Off", icon: inUse ? "video.fill" : "video", fields: ["inUse": String(inUse)])
    }

    /// Calls `changed` on the main actor, as `AudioMonitor.start` does.
    func start(changed: @escaping @Sendable () -> Void) throws {
        try queue.sync {
            removeListeners()
            relay.start(changed)
            let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.watchCameras()
                self?.relay.notify()
            }
            var address = Self.devicesAddress
            let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, listener)
            guard status == noErr else {
                relay.stop()
                throw CommandFailure(message: "Could not watch cameras (\(status)).")
            }
            systemListener = listener
            watchCameras()
        }
    }

    func stop() {
        relay.stop()
        queue.sync { removeListeners() }
    }

    /// On `queue`: moves the use listener to the current cameras.
    private func watchCameras() {
        unwatchCameras()
        guard systemListener != nil else { return }
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.relay.notify() }
        for camera in (try? Self.devices()) ?? [] {
            var address = Self.runningAddress
            if CMIOObjectAddPropertyListenerBlock(camera, &address, queue, listener) == noErr { cameras.append(camera) }
        }
        cameraListener = listener
    }

    /// On `queue`.
    private func unwatchCameras() {
        if let cameraListener {
            for camera in cameras {
                var address = Self.runningAddress
                CMIOObjectRemovePropertyListenerBlock(camera, &address, queue, cameraListener)
            }
        }
        cameras = []
        cameraListener = nil
    }

    /// On `queue`.
    private func removeListeners() {
        unwatchCameras()
        if let systemListener {
            var address = Self.devicesAddress
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, systemListener)
        }
        systemListener = nil
    }

    private static func devices() throws -> [CMIOObjectID] {
        var address = devicesAddress
        var size: UInt32 = 0
        let status = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw CommandFailure(message: "Could not list cameras (\(status)).") }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        let readStatus = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &devices)
        guard readStatus == noErr else { throw CommandFailure(message: "Could not read cameras (\(readStatus)).") }
        return devices
    }
}
