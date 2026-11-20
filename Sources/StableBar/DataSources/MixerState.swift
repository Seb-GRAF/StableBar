/// The Sound details' mixer: the apps that play sound, the volume, mute and output chosen for each, and which of them
/// StableBar plays back itself through a process tap. An app plays through a tap while its choice differs from the
/// default and System Audio Recording is allowed; the first change asks for it. Its owner, `AudioMixer`, reads
/// CoreAudio, saves the choices and runs the taps.
struct MixerState: StateMachine, Equatable {
    /// A process that talks to CoreAudio.
    struct Client: Equatable, Sendable {
        let object: UInt32
        /// Its bundle ID, or its name when it has none.
        let bundleID: String
        let name: String
        let playing: Bool
    }

    /// An app and the processes that play its sound, such as a browser and its helpers.
    struct App: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let processes: [UInt32]
        let playing: Bool
        /// Whether it's a regular app, one with a Dock icon, rather than an agent or a helper of the system.
        let regular: Bool
    }

    struct Output: Equatable, Sendable {
        let uid: String
        let name: String
    }

    /// What the person chose for an app. The default plays as macOS does, without a tap.
    struct Setting: Codable, Equatable, Sendable {
        var volume = 1.0
        var muted = false
        /// The output device's UID, or nil for the default output.
        var output: String?

        var isDefault: Bool { volume == 1 && !muted && output == nil }
    }

    enum Permission: Equatable, Sendable {
        case unknown, asking, allowed, denied
    }

    /// A tap StableBar runs for an app: the processes it mutes at the source, the output device it plays them on, at
    /// what gain, and whether it plays now.
    struct Tap: Equatable, Sendable {
        let processes: [UInt32]
        let output: String
        let gain: Double
        let playing: Bool
    }

    enum Event: Equatable {
        /// The processes that talk to CoreAudio, and the running regular apps' names by bundle ID.
        case processesChanged([Client], apps: [String: String])
        case outputsChanged([Output], defaultOutput: String?)
        /// What macOS says about System Audio Recording, such as after the person changed it in System Settings.
        case permissionChecked(Permission)
        case permissionAnswered(allowed: Bool)
        case setVolume(String, Double)
        case setMuted(String, Bool)
        /// An output device's UID, or nil for the default output.
        case setOutput(String, String?)
        /// The app's tap couldn't start or play as `Tap` planned: it plays as macOS does until its processes or its
        /// output change. A failure of a tap since replaced by one with other processes or another output changes nothing.
        /// The tap stops after the work already queued for it, which may have started the same plan again.
        case tapFailed(String, Tap)
    }

    enum Effect: Equatable {
        case askPermission
        case save([String: Setting])
        case stopTap(String)
        case startTap(String, Tap)
        case setGain(String, Double)
        case setPlaying(String, Bool)
    }

    private(set) var apps: [App] = []
    private(set) var outputs: [Output] = []
    private(set) var defaultOutput: String?
    /// The apps whose choice isn't the default, by ID.
    private(set) var settings: [String: Setting]
    private(set) var permission = Permission.unknown
    private(set) var taps: [String: Tap] = [:]
    /// The taps that couldn't start, which aren't tried again as they were.
    private var failed: [String: Tap] = [:]

    init(settings: [String: Setting] = [:]) {
        self.settings = settings
    }

    /// The apps the mixer lists: the regular apps, those playing now, and those with a choice of their own.
    var shown: [App] { apps.filter { $0.regular || $0.playing || settings[$0.id] != nil } }

    func setting(_ id: String) -> Setting { settings[id] ?? Setting() }

    /// Whether the app's chosen output is gone, so it plays on the default output for now.
    func fallsBack(_ id: String) -> Bool {
        settings[id]?.output.map { uid in !outputs.contains { $0.uid == uid } } ?? false
    }

    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        switch event {
        case let .processesChanged(processes, running): apps = Self.apps(processes, running: running)
        case let .outputsChanged(outputs, defaultOutput):
            self.outputs = outputs
            self.defaultOutput = defaultOutput
        case let .permissionChecked(permission):
            if self.permission != .asking || permission != .unknown { self.permission = permission }
        case let .permissionAnswered(allowed): permission = allowed ? .allowed : .denied
        case let .setVolume(id, volume): effects = change(id) { $0.volume = min(max(volume, 0), 1) }
        case let .setMuted(id, muted): effects = change(id) { $0.muted = muted }
        case let .setOutput(id, output): effects = change(id) { $0.output = output }
        case let .tapFailed(id, tap):
            guard let current = taps[id], current.processes == tap.processes, current.output == tap.output else { break }
            failed[id] = taps.removeValue(forKey: id)
            effects = [.stopTap(id)]
        }
        return effects + tapEffects()
    }

    /// The apps among `processes`. A process whose bundle ID extends a running regular app's, such as
    /// `com.google.Chrome.helper` for `com.google.Chrome`, counts as that app; any other is an app of its own, by its name.
    static func apps(_ processes: [Client], running: [String: String]) -> [App] {
        var found: [String: App] = [:]
        for process in processes {
            let id = running[process.bundleID] != nil ? process.bundleID
                : running.keys.filter { process.bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count } ?? process.bundleID
            let app = found[id]
            found[id] = App(id: id, name: running[id] ?? process.name, processes: (app?.processes ?? []) + [process.object],
                            playing: app?.playing == true || process.playing, regular: running[id] != nil)
        }
        return found.values.sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }

    /// Changes an app's choice and saves it, and asks for System Audio Recording the first time. While it's refused,
    /// the mixer changes nothing.
    private mutating func change(_ id: String, _ edit: (inout Setting) -> Void) -> [Effect] {
        guard permission != .denied else { return [] }
        var setting = setting(id)
        edit(&setting)
        settings[id] = setting.isDefault ? nil : setting
        guard permission == .unknown else { return [.save(settings)] }
        permission = .asking
        return [.save(settings), .askPermission]
    }

    /// Stops the taps no longer wanted or wanted elsewhere, then starts or updates the rest.
    private mutating func tapEffects() -> [Effect] {
        let wanted = wantedTaps()
        var effects: [Effect] = []
        for (id, tap) in taps.sorted(by: { $0.key < $1.key })
        where wanted[id].map({ $0.processes != tap.processes || $0.output != tap.output }) ?? true {
            effects.append(.stopTap(id))
            taps[id] = nil
        }
        for (id, tap) in wanted.sorted(by: { $0.key < $1.key }) {
            if let running = taps[id] {
                if running.gain != tap.gain { effects.append(.setGain(id, tap.gain)) }
                if running.playing != tap.playing { effects.append(.setPlaying(id, tap.playing)) }
            } else {
                effects.append(.startTap(id, tap))
                // Another plan for the app, such as a fallback output, so a failed one may work again later.
                failed[id] = nil
            }
            taps[id] = tap
        }
        return effects
    }

    /// Loudness follows the square of the volume, closer to how ears hear a slider than the volume itself.
    private func wantedTaps() -> [String: Tap] {
        guard permission == .allowed, let defaultOutput else { return [:] }
        var wanted: [String: Tap] = [:]
        for app in apps {
            guard let setting = settings[app.id] else { continue }
            let output = setting.output.flatMap { uid in outputs.contains { $0.uid == uid } ? uid : nil } ?? defaultOutput
            let tap = Tap(processes: app.processes, output: output, gain: setting.muted ? 0 : setting.volume * setting.volume,
                          playing: app.playing)
            if let failed = failed[app.id], failed.processes == tap.processes, failed.output == tap.output { continue }
            wanted[app.id] = tap
        }
        return wanted
    }
}
