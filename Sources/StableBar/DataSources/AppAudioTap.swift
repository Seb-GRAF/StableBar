import CoreAudio
import Foundation

/// One app's sound played back by StableBar: a process tap mutes the app's processes at the source, and a private
/// aggregate device reads the tap and plays it on an output device at the app's gain. Owned on the main actor.
final class AppAudioTap {
    /// The UIDs of the aggregate devices start with this. A private device is hidden from other apps but not from
    /// StableBar, so its device lists leave these out.
    static let uidPrefix = "org.stablebar.mixer."

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var playing = false
    private let gains = Gains()

    @available(macOS 14.2, *)
    init(_ plan: MixerState.Tap) throws {
        do {
            gains.pointer.initialize(repeating: Float(plan.gain), count: 2)
            let description = CATapDescription(stereoMixdownOfProcesses: plan.processes.map { AudioObjectID($0) })
            // Muted even while the device doesn't run, so the app stays quiet between its sounds instead of playing
            // at full volume until StableBar notices it plays.
            description.muteBehavior = .muted
            description.isPrivate = true
            try check(AudioHardwareCreateProcessTap(description, &tap), "tap the app’s sound")
            let device: [String: Any] = [
                kAudioAggregateDeviceNameKey: "StableBar mixer",
                kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: plan.output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: plan.output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate), "open the app’s output")
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, Self.player(gains)), "play the app’s sound")
            try setPlaying(plan.playing)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func setGain(_ gain: Double) {
        gains.pointer[0] = Float(gain)
    }

    func setPlaying(_ playing: Bool) throws {
        guard playing != self.playing, let proc else { return }
        try check(playing ? AudioDeviceStart(aggregate, proc) : AudioDeviceStop(aggregate, proc), playing ? "play the app’s sound" : "pause the app’s sound")
        self.playing = playing
    }

    /// Ends the tap, so the app plays as macOS does again.
    func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        playing = false
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CommandFailure(message: "Could not \(action) (\(status)).") }
    }

    /// The gain to play at, then the gain the last cycle ended at, which the next one ramps from so a change doesn't
    /// click. Written on the main actor and read on CoreAudio's I/O thread, a Float at a time.
    private final class Gains: @unchecked Sendable {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 2)

        deinit {
            pointer.deallocate()
        }
    }

    /// Copies the tap's sound, the input's last buffer, into the output's first two channels at the gain, and
    /// silences the rest. It runs on CoreAudio's I/O thread, so it neither allocates nor locks, and it isn't isolated
    /// to the main actor, which would stop it there.
    private nonisolated static func player(_ gains: Gains) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            var channels = 0
            for buffer in outputs {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                channels += Int(buffer.mNumberChannels)
            }
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard channels > 0, let source = inputs.last, source.mNumberChannels > 0,
                  let samples = source.mData?.assumingMemoryBound(to: Float.self) else { return }
            let width = Int(source.mNumberChannels)
            let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / width
            let target = gains.pointer[0]
            var gain = gains.pointer[1]
            let step = frames > 0 ? (target - gain) / Float(frames) : 0
            for frame in 0..<frames {
                gain += step
                let left = samples[frame * width] * gain
                let right = width > 1 ? samples[frame * width + 1] * gain : left
                var channel = 0
                for buffer in outputs where channel < 2 {
                    let count = Int(buffer.mNumberChannels)
                    guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                          frame < Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / count else {
                        channel += count
                        continue
                    }
                    for index in 0..<min(count, 2 - channel) {
                        data[frame * count + index] = channels == 1 ? (left + right) / 2 : channel + index == 0 ? left : right
                    }
                    channel += count
                }
            }
            gains.pointer[1] = target
        }
    }
}
