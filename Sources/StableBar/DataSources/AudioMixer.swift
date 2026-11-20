import AppKit
import CoreAudio

/// Runs the Sound details' mixer for all of StableBar: it follows the processes that talk to CoreAudio and the output
/// devices, asks for System Audio Recording, saves each app's choice and plays apps back through their taps as
/// `MixerState` decides. There is one, since taps belong to StableBar's process.
@MainActor @Observable
final class AudioMixer {
    static var shared = AudioMixer()
    /// Each app's volume, mute and output, by app, kept across launches.
    static let settingsKey = "audioMixer"
    private nonisolated static let service = "kTCCServiceAudioCapture"

    /// Taps came with macOS 14.2, and only TCC's private calls tell whether the permission they need is allowed.
    static var isAvailable: Bool {
        guard #available(macOS 14.2, *) else { return false }
        return PrivateAPI.accessPreflight != nil && PrivateAPI.accessRequest != nil
    }

    private(set) var state: MixerState
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let taps = Taps()
    /// The last work on the taps, which the next waits for.
    @ObservationIgnored private var tapsTail: Task<Void, Never>?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var processes: [AudioObjectID] = []
    /// Whether it follows CoreAudio, which a scene's sample mixer doesn't.
    @ObservationIgnored private var follows = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode([String: MixerState.Setting].self, from: $0) }
        state = MixerState(settings: saved ?? [:])
    }

    /// A mixer that shows `state` and never touches CoreAudio, for drawing scenes.
    init(sample state: MixerState) {
        defaults = .standard
        self.state = state
        follows = false
    }

    /// Follows CoreAudio from the first call, and checks the permission again on each, since the person can change it
    /// in System Settings.
    func start() {
        guard follows, Self.isAvailable else { return }
        checkPermission()
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } }
        for var address in Self.systemAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = listener
        refresh()
    }

    func setVolume(_ volume: Double, of app: String) { perform(state.handle(.setVolume(app, volume))) }
    func setMuted(_ muted: Bool, of app: String) { perform(state.handle(.setMuted(app, muted))) }
    func setOutput(_ output: String?, of app: String) { perform(state.handle(.setOutput(app, output))) }

    private func checkPermission() {
        let answer = PrivateAPI.accessPreflight!(Self.service as CFString, nil)
        perform(state.handle(.permissionChecked(answer == 0 ? .allowed : answer == 1 ? .denied : .unknown)))
    }

    private func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let objects = AudioMonitor.objects(of: system, at: Self.address(kAudioHardwarePropertyProcessObjectList))
        if objects != processes { watch(objects) }
        let own = ProcessInfo.processInfo.processIdentifier
        let found: [MixerState.Client] = objects.compactMap { object in
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            var address = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid != own else { return nil }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? Self.processName(pid)
            let bundleID = AudioMonitor.string(of: object, at: Self.address(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return MixerState.Client(object: object, bundleID: bundleID, name: name,
                                      playing: AudioMonitor.flag(of: object, at: Self.address(kAudioProcessPropertyIsRunningOutput)))
        }
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier { running[id] = app.localizedName ?? id }
        }
        perform(state.handle(.processesChanged(found, apps: running)))
        let outputs = AudioMonitor.objects(of: system, at: Self.address(kAudioHardwarePropertyDevices)).compactMap { device -> MixerState.Output? in
            guard AudioMonitor.hasStreams(device, scope: kAudioDevicePropertyScopeOutput),
                  let uid = AudioMonitor.string(of: device, at: Self.address(kAudioDevicePropertyDeviceUID)), !uid.hasPrefix(AppAudioTap.uidPrefix),
                  let name = try? AudioMonitor.name(of: device) else { return nil }
            return MixerState.Output(uid: uid, name: name)
        }
        let defaultOutput = (try? AudioMonitor.defaultDevice(input: false)).flatMap { AudioMonitor.string(of: $0, at: Self.address(kAudioDevicePropertyDeviceUID)) }
        perform(state.handle(.outputsChanged(outputs, defaultOutput: defaultOutput)))
    }

    /// Moves the playing listeners to the current processes. Some macOS versions change whether a process plays without
    /// telling its listeners, but tell those of whether it runs at all.
    private func watch(_ objects: [AudioObjectID]) {
        guard let listener else { return }
        for var address in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunning].map(Self.address) {
            for process in processes { AudioObjectRemovePropertyListenerBlock(process, &address, .main, listener) }
            for process in objects { AudioObjectAddPropertyListenerBlock(process, &address, .main, listener) }
        }
        processes = objects
    }

    private func perform(_ effects: [MixerState.Effect]) {
        for effect in effects {
            switch effect {
            case .askPermission:
                // TCC's request holds its thread until the person answers the prompt.
                Task {
                    try? await BlockingWork.run { [self] in
                        PrivateAPI.accessRequest!(Self.service as CFString, nil) { allowed in
                            Task { @MainActor in self.perform(self.state.handle(.permissionAnswered(allowed: allowed))) }
                        }
                    }
                }
            case let .save(settings):
                if settings.isEmpty {
                    defaults.removeObject(forKey: Self.settingsKey)
                } else {
                    defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
                }
            case let .stopTap(id): onTaps { $0.byApp.removeValue(forKey: id)?.stop() }
            case let .startTap(id, tap):
                onTaps(failing: (id, tap)) { taps in
                    guard #available(macOS 14.2, *) else { return }
                    taps.byApp[id] = try AppAudioTap(tap)
                }
            case let .setGain(id, gain): onTaps { $0.byApp[id]?.setGain(gain) }
            case let .setPlaying(id, playing):
                onTaps(failing: state.taps[id].map { (id, $0) }) { try $0.byApp[id]?.setPlaying(playing) }
            }
        }
    }

    /// Runs `work` on the taps after the work before it, off the main actor, since starting and stopping a tap waits for
    /// CoreAudio. When it fails, `MixerState` hears of the plan named by `failing` and ends the app's tap.
    private func onTaps(failing plan: (id: String, tap: MixerState.Tap)? = nil, _ work: @escaping @Sendable (Taps) throws -> Void) {
        let previous = tapsTail
        tapsTail = Task { [taps] in
            await previous?.value
            do {
                try await BlockingWork.run { try work(taps) }
            } catch {
                if let plan { perform(state.handle(.tapFailed(plan.id, plan.tap))) }
            }
        }
    }

    private static let systemAddresses = [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                                          kAudioHardwarePropertyDefaultOutputDevice].map(address)

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// A process without an app, such as `afplay`, goes by its executable's name.
    private nonisolated static func processName(_ pid: pid_t) -> String {
        var name = [UInt8](repeating: 0, count: 256)
        let length = Int(proc_name(pid, &name, UInt32(name.count)))
        return length > 0 ? String(decoding: name.prefix(length), as: UTF8.self) : "Process \(pid)"
    }
}

/// The running taps by app. Only the work `AudioMixer` chains touches them, one piece at a time.
private final class Taps: @unchecked Sendable {
    var byApp: [String: AppAudioTap] = [:]
}
