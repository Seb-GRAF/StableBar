import AudioToolbox
import CoreAudio
import Foundation

/// The default output device's, or with `input` the default input device's, volume, mute state and
/// name from CoreAudio, and for input whether any app records from it. Its listeners follow the
/// default device and the device list, and the default device's volume, mute state and use.
final class AudioMonitor: ChangeMonitor, @unchecked Sendable {
    /// The `temporary` field that holds the volume, such as `62%`, for a moment after it changes.
    static let changedVolumeField = "changedVolume"
    /// How long the volume shows after a change, in seconds.
    static let changedVolumeDuration = 1.5

    private let input: Bool
    private let relay = MainQueueRelay()
    private let queue = DispatchQueue(label: "StableBar.AudioMonitor")
    /// The last output read, which the next read compares with. Only touched on the main actor, where
    /// reads happen.
    private var previous: ScriptOutput?
    // The listener state below is only touched on `queue`, where CoreAudio delivers the listeners.
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceAddresses: [AudioObjectPropertyAddress] = []
    private var processes: [AudioObjectID] = []
    private var processListener: AudioObjectPropertyListenerBlock?

    init(input: Bool = false) {
        self.input = input
    }

    private var scope: AudioObjectPropertyScope { input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput }

    /// Whether it tells recording from playback by the processes using the device. A duplex device
    /// runs for playback alone, and macOS 14.2 added the process objects that tell them apart.
    private var readsProcesses: Bool {
        if #available(macOS 14.2, *) { input } else { false }
    }

    private var systemAddresses: [AudioObjectPropertyAddress] {
        ([input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]
            + (readsProcesses ? [kAudioHardwarePropertyProcessObjectList] : [])).map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
    }

    private var deviceProperties: [AudioObjectPropertyAddress] {
        [0, 1, 2].map {
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: $0)
        } + [AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)]
            + (input && !readsProcesses ? [Self.runningAddress] : [])
    }

    private static let runningAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let processListAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let recordingAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let inputDevicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                                        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)

    func read() throws -> ScriptOutput {
        if input { return try readDevice() }
        let output = Self.showingChange(to: try readDevice(), from: previous)
        previous = output
        return output
    }

    /// `output` with a `temporary` that shows its volume for a moment when its volume or mute state
    /// differs from `previous`'s, as `volumeChange` reports them. The volume is empty while muted or
    /// without a volume control. The first read shows nothing.
    static func showingChange(to output: ScriptOutput, from previous: ScriptOutput?) -> ScriptOutput {
        guard let previous, let change = BuiltInEvent.volumeChange.variables(from: previous, to: output) else { return output }
        var output = output
        let info = change["INFO"] ?? ""
        let volume = change["MUTED"] == "true" || info.isEmpty ? "" : "\(info)%"
        output.temporary = TemporaryOutput(fields: [changedVolumeField: volume], duration: changedVolumeDuration)
        return output
    }

    /// The widest speaker `icon(volume:muted:)` gives, whose width the Sound widget keeps.
    static let widestIcon = "speaker.wave.3"

    /// The speaker for `volume`: crossed out while muted, else without waves at zero and with one,
    /// two or three as it rises, a wave a third. Without a volume control, two waves.
    static func icon(volume: Double?, muted: Bool) -> String {
        if muted { return "speaker.slash" }
        guard let volume else { return "speaker.wave.2" }
        switch Int((volume * 100).rounded()) {
        case ...0: return "speaker"
        case ...33: return "speaker.wave.1"
        case ...66: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }

    private func readDevice() throws -> ScriptOutput {
        let device = try Self.defaultDevice(input: input)
        guard device != kAudioObjectUnknown else {
            return ScriptOutput(text: input ? "No input" : "No output", icon: input ? "mic.slash" : "speaker.slash",
                                fields: ["volumeAvailable": "false"], lists: ["devices": []])
        }
        // A device that is being unplugged may not tell its name; the next change reads it again.
        let name = (try? Self.name(of: device)) ?? ""
        var volumes: [Float32] = []
        for channel: UInt32 in [0, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: channel)
            if AudioObjectHasProperty(device, &address) {
                var value: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                    volumes.append(value)
                    if channel == 0 { break }
                }
            }
        }
        let volume = volumes.isEmpty ? nil : Double(volumes.reduce(0, +) / Float32(volumes.count))
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)
        var fields = ["device": name, "deviceID": String(device), "volumeAvailable": String(volume != nil)]
        if muteStatus == noErr { fields["muted"] = String(muted != 0) }
        var icon = Self.icon(volume: volume, muted: muted != 0)
        if input {
            let inUse = isRecording(from: device)
            fields["inUse"] = String(inUse)
            icon = muted != 0 ? "mic.slash" : inUse ? "mic.fill" : "mic"
        }
        return ScriptOutput(text: volume.map { "\(Int(($0 * 100).rounded()))%" } ?? name, icon: icon,
                            value: volume, fields: fields, lists: ["devices": try Self.devices(scope: scope)], values: volume.map { ["volume": $0] })
    }

    /// Whether any process records from `device`, or before macOS 14.2 whether any uses it at all.
    private func isRecording(from device: AudioDeviceID) -> Bool {
        guard readsProcesses else { return Self.flag(of: device, at: Self.runningAddress) }
        return Self.objects(of: AudioObjectID(kAudioObjectSystemObject), at: Self.processListAddress).contains { process in
            Self.flag(of: process, at: Self.recordingAddress) && Self.objects(of: process, at: Self.inputDevicesAddress).contains(device)
        }
    }

    /// Calls `changed` on the main actor, so a change never runs between a refresh's read and its
    /// send. CoreAudio reports on `queue`, and `relay` hops to the main queue before it calls `changed`.
    func start(changed: @escaping @Sendable () -> Void) throws {
        try queue.sync {
            removeListeners()
            relay.start(changed)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.systemChanged() }
            systemListener = listener
            for var address in systemAddresses {
                let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                guard status == noErr else {
                    removeListeners()
                    relay.stop()
                    throw CommandFailure(message: "Could not watch audio devices (\(status)).")
                }
            }
            watchDefaultDevice()
            watchProcesses()
        }
    }

    func stop() {
        relay.stop()
        queue.sync { removeListeners() }
    }

    /// On `queue`: the default device or the device list changed.
    private func systemChanged() {
        let current = (try? Self.defaultDevice(input: input)) ?? AudioObjectID(kAudioObjectUnknown)
        if !Self.covers(device: current, properties: properties(of: current), watched: device, addresses: deviceAddresses) {
            watchDefaultDevice()
        }
        watchProcesses()
        relay.notify()
    }

    /// Whether the device listener, on `watched` at `addresses`, already covers `device` and
    /// each of its `properties`. A device can publish a property late, such as a Bluetooth device's
    /// volume, and a listener can fail to register, so the next device-list change registers again.
    static func covers(device: AudioObjectID, properties: [AudioObjectPropertyAddress],
                       watched: AudioObjectID, addresses: [AudioObjectPropertyAddress]) -> Bool {
        device == watched && properties.allSatisfy { property in
            addresses.contains { $0.mSelector == property.mSelector && $0.mScope == property.mScope && $0.mElement == property.mElement }
        }
    }

    /// On `queue`: moves the device listener to the current default device.
    private func watchDefaultDevice() {
        unwatchDevice()
        guard systemListener != nil, let device = try? Self.defaultDevice(input: input), device != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.relay.notify() }
        var watched: [AudioObjectPropertyAddress] = []
        for var address in properties(of: device) {
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr { watched.append(address) }
        }
        self.device = device
        deviceListener = listener
        deviceAddresses = watched
    }

    /// On `queue`.
    private func unwatchDevice() {
        if let deviceListener {
            for var address in deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, deviceListener)
            }
        }
        device = AudioObjectID(kAudioObjectUnknown)
        deviceListener = nil
        deviceAddresses = []
    }

    /// On `queue`: moves the recording listener to the current processes.
    private func watchProcesses() {
        unwatchProcesses()
        guard systemListener != nil, readsProcesses else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.relay.notify() }
        processes = Self.objects(of: AudioObjectID(kAudioObjectSystemObject), at: Self.processListAddress)
        for process in processes {
            for var address in [Self.recordingAddress, Self.inputDevicesAddress] {
                AudioObjectAddPropertyListenerBlock(process, &address, queue, listener)
            }
        }
        processListener = listener
    }

    /// On `queue`.
    private func unwatchProcesses() {
        if let processListener {
            for process in processes {
                for var address in [Self.recordingAddress, Self.inputDevicesAddress] {
                    AudioObjectRemovePropertyListenerBlock(process, &address, queue, processListener)
                }
            }
        }
        processes = []
        processListener = nil
    }

    /// On `queue`.
    private func removeListeners() {
        unwatchProcesses()
        unwatchDevice()
        if let systemListener {
            for var address in systemAddresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, systemListener)
            }
        }
        systemListener = nil
    }

    /// Sets the default output device's volume to `volume`, 0–1, keeping its balance, and unmutes it
    /// for a volume above zero, as the Sound menu's slider does.
    static func setVolume(_ volume: Double) throws {
        let device = try defaultDevice(input: false)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address) else {
            throw CommandFailure(message: "The audio output has no volume control.")
        }
        var value = Float32(min(max(volume, 0), 1))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { throw CommandFailure(message: "Could not set the volume (\(status)).") }
        var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        if value > 0, AudioObjectHasProperty(device, &mute) {
            var unmuted: UInt32 = 0
            AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
        }
    }

    private static func defaultDevice(input: Bool) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw CommandFailure(message: "Could not read the audio \(input ? "input" : "output") device (\(status)).") }
        return device
    }

    /// The volume, mute and use properties that `device` has.
    private func properties(of device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        guard device != kAudioObjectUnknown else { return [] }
        return deviceProperties.filter { address in
            var address = address
            return AudioObjectHasProperty(device, &address)
        }
    }

    private static func flag(of object: AudioObjectID, at address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// The objects that `object` lists at `address`, none when it can't tell.
    private static func objects(of object: AudioObjectID, at address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func name(of device: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { throw CommandFailure(message: "Could not read audio device name (\(status)).") }
        return name.takeRetainedValue() as String
    }

    private static func devices(scope: AudioObjectPropertyScope) throws -> [[String: String]] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw CommandFailure(message: "Could not list audio devices (\(status)).") }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let readStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        guard readStatus == noErr else { throw CommandFailure(message: "Could not read audio devices (\(readStatus)).") }
        return deviceRows(devices.filter { hasStreams($0, scope: scope) }, name: name(of:))
    }

    /// A row for each of `devices` whose name can be read. A device that is being unplugged may no
    /// longer tell its name, and the list leaves it out.
    static func deviceRows(_ devices: [AudioDeviceID], name: (AudioDeviceID) throws -> String) -> [[String: String]] {
        devices.compactMap { device in (try? name(device)).map { ["id": String(device), "name": $0] } }
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
    }
}
