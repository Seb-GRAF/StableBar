import Foundation

/// Whether an app uses the microphone or a camera, as macOS's privacy indicators show it: the
/// default input device's use and mute state from `AudioMonitor`, and the cameras' from `CameraMonitor`.
final class PrivacyMonitor: ChangeMonitor, @unchecked Sendable {
    private let microphone = AudioMonitor(input: true)
    private let camera = CameraMonitor()

    func read() throws -> ScriptOutput {
        let input = try microphone.read()
        let microphone = input.fields?["inUse"] == "true"
        let camera = try camera.inUse()
        var fields = ["microphone": String(microphone), "camera": String(camera)]
        fields["muted"] = input.fields?["muted"]
        return ScriptOutput(text: "", tooltip: Self.tooltip(microphone: microphone, camera: camera), fields: fields)
    }

    private static func tooltip(microphone: Bool, camera: Bool) -> String {
        switch (microphone, camera) {
        case (true, true): "Microphone and camera in use"
        case (true, false): "Microphone in use"
        case (false, true): "Camera in use"
        case (false, false): "Microphone and camera not in use"
        }
    }

    func start(changed: @escaping @Sendable () -> Void) throws {
        try microphone.start(changed: changed)
        do {
            try camera.start(changed: changed)
        } catch {
            microphone.stop()
            throw error
        }
    }

    func stop() {
        microphone.stop()
        camera.stop()
    }
}
