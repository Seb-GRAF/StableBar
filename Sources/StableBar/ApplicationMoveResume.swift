import Foundation

/// Private relaunch state, never configuration syntax. A version lets later builds safely ignore another format.
struct ApplicationMoveResume: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case setup, settings }
    var version = 1
    var kind: Kind
    var configuration: URL
    /// A screen setup can use its own bar while --config still names the shared configuration.
    var barConfiguration: URL?
    var timestamp = Date()
    var setup: Setup?
    var edits: [Edit] = []
    var failure: String?

    struct Setup: Codable, Sendable {
        var step: Int
        var preferences: SetupPreferences
        var preset: SetupPreferences.Preset?
        var openAtLogin: Bool?
        var placementChoice: SetupPreferences.Placement?
        var placementAwaitingAccess: SetupPreferences.Placement?
        var menuBarHidAtStart: Bool
        var stableBarHidMenuBarAtStart: Bool
        var opensAtLoginAtStart: Bool
    }

    /// ConfigurationEdit's public wire format omits the session-only profile target. Keep it in the private record.
    struct Edit: Codable, Sendable {
        var edit: ConfigurationEdit
        var profile: String?

        init(_ edit: ConfigurationEdit) { self.edit = edit; profile = edit.profile }
        var restored: ConfigurationEdit {
            var edit = edit
            edit.profile = profile
            return edit
        }
    }
}

/// Both copies and the helper share StableBar's defaults domain, which Uninstall already clears.
/// Keep only the domain name across actors; tests use isolated domains, never the developer's preferences.
struct ApplicationMoveResumeStore: Codable, Sendable {
    var domain = Bundle.main.bundleIdentifier ?? "org.stablebar.app"
    static let key = "applicationMoveResume"

    func save(_ resume: ApplicationMoveResume) throws {
        let data = try JSONEncoder().encode(resume)
        CFPreferencesSetAppValue(Self.key as CFString, data as CFData, domain as CFString)
        // The detached helper and the next app must see this before the current process exits.
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            throw CommandFailure(message: "Couldn’t save where setup left off. Try again before moving StableBar.")
        }
    }

    func discard() throws {
        CFPreferencesSetAppValue(Self.key as CFString, nil, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            throw CommandFailure(message: "Couldn’t clear the saved setup. Try again before moving StableBar.")
        }
    }

    func take(configuration: URL, barConfiguration: URL? = nil, now: Date = Date()) -> ApplicationMoveResume? {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let value = CFPreferencesCopyAppValue(Self.key as CFString, domain as CFString) else { return nil }
        guard let data = value as? Data,
              let resume = try? JSONDecoder().decode(ApplicationMoveResume.self, from: data), resume.version == 1,
              (0..<15 * 60).contains(now.timeIntervalSince(resume.timestamp)),
              resume.kind != .setup || resume.setup.map({ SetupSession.Step.allCases.indices.contains($0.step) }) == true else {
            try? discard()
            return nil
        }
        // Another instance can start during the handoff. Leave its record until it matches or expires.
        guard resume.configuration.standardizedFileURL == configuration.standardizedFileURL,
              barConfiguration == nil || (resume.barConfiguration ?? resume.configuration).standardizedFileURL == barConfiguration?.standardizedFileURL,
              (try? discard()) != nil else { return nil }
        // Consume before returning: even a crash while restoring can't loop.
        return resume
    }
}

/// Shared by both windows so a manual open during launch uses the same record as the automatic resume.
@MainActor
final class ApplicationMoveLaunchResume {
    private var record: ApplicationMoveResume?
    private(set) var wasResuming = false
    var pendingKind: ApplicationMoveResume.Kind? { record?.kind }

    func load(for store: BarStore, from resumeStore: ApplicationMoveResumeStore = ApplicationMoveResumeStore()) {
        record = resumeStore.take(configuration: store.sharedConfigurationURL, barConfiguration: store.configurationURL)
        wasResuming = record != nil
        if let record { store.sessionEdits = record.edits.map(\.restored) }
    }

    func take(for kind: ApplicationMoveResume.Kind) -> ApplicationMoveResume? {
        guard record?.kind == kind else { return nil }
        defer { record = nil }
        return record
    }
}
