import Foundation
import os

let configurationReferenceExpansionLimit = 100_000
// Keeps reference recursion within a worker thread's stack.
let configurationReferenceDepthLimit = 64

final class ConfigurationReferenceExpansionBudget: Sendable {
    let limit: Int
    let originPathByteLimit: Int?
    private let remaining: OSAllocatedUnfairLock<Int>
    private let remainingOriginPathBytes: OSAllocatedUnfairLock<Int>

    init(limit: Int, originPathByteLimit: Int? = nil) {
        self.limit = limit
        self.originPathByteLimit = originPathByteLimit
        remaining = OSAllocatedUnfairLock(initialState: limit)
        remainingOriginPathBytes = OSAllocatedUnfairLock(initialState: originPathByteLimit ?? 0)
    }

    var consumed: Int { limit - remaining.withLock { $0 } }
    var consumedOriginPathBytes: Int { (originPathByteLimit ?? 0) - remainingOriginPathBytes.withLock { $0 } }

    func recordOriginPath(_ path: String, token: String) throws {
        guard originPathByteLimit != nil else { return }
        let bytes = path.utf8.count
        try remainingOriginPathBytes.withLock { remaining in
            guard bytes <= remaining else {
                remaining = 0
                throw ThemeConfigurationError.referenceOriginsTooLarge(token)
            }
            remaining -= bytes
        }
    }

    fileprivate func withRemaining<T>(_ body: (inout Int) throws -> T) rethrows -> T {
        try remaining.withLockUnchecked { remaining in
            let available = min(remaining, configurationReferenceExpansionLimit)
            var callRemaining = available
            defer { remaining -= available - max(0, callRemaining) }
            return try body(&callRemaining)
        }
    }
}

struct ConfigurationContext: Sendable, Equatable {
    var appearance = "light"
    var onBattery = false
    var displayCount = 1
    var externalDisplay = false
    /// The names of the connected screens.
    var displays: [String] = []
    /// The Wi-Fi network's name: empty off Wi-Fi, without Location access, or when no profile checks it.
    var wifi = ""
    /// Whether an app uses a camera or the microphone, read only when a profile checks them.
    var camera = false
    var microphone = false
    var app = ""
    /// The ID of the theme the bar is drawn with, set by the loader once it has settled the theme.
    var theme = "built-in"
}

struct ConfigurationProfile: Codable, Equatable, Sendable {
    let name: String
    var enabled = true
    var when: ProfileConditions?
    var configuration: [String: ConfigurationValue]

    enum CodingKeys: String, CodingKey, CaseIterable { case name, enabled, when, configuration }

    init(name: String, when: ProfileConditions?, configuration: [String: ConfigurationValue]) {
        self.name = name
        self.when = when
        self.configuration = configuration
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        when = try values.decodeIfPresent(ProfileConditions.self, forKey: .when)
        configuration = try values.decodeIfPresent([String: ConfigurationValue].self, forKey: .configuration) ?? [:]
    }
}

struct ProfileConditions: Codable, Equatable, Sendable {
    var appearance: String?
    var onBattery: Bool?
    var displayCount: Int?
    var externalDisplay: Bool?
    /// The name of a screen that must be connected.
    var display: String?
    var wifi: String?
    var camera: Bool?
    var microphone: Bool?
    var app: String?
    /// Several apps, any of which in front matches. Settings writes `app` for one app, which older releases read.
    var apps: [String]?
    var theme: String?
    /// A condition from a newer release, which this one can't check, so the profile never matches on its own.
    var unknownCondition = false

    enum CodingKeys: String, CodingKey, CaseIterable {
        case appearance, onBattery, displayCount, externalDisplay, display, wifi, camera, microphone, app, apps, theme
    }

    init() {}

    init(from decoder: Decoder) throws {
        unknownCondition = try !decoder.rejectUnknownKeys(CodingKeys.self).isEmpty
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance)
        onBattery = try values.decodeIfPresent(Bool.self, forKey: .onBattery)
        displayCount = try values.decodeIfPresent(Int.self, forKey: .displayCount)
        externalDisplay = try values.decodeIfPresent(Bool.self, forKey: .externalDisplay)
        display = try values.decodeIfPresent(String.self, forKey: .display)
        wifi = try values.decodeIfPresent(String.self, forKey: .wifi)
        camera = try values.decodeIfPresent(Bool.self, forKey: .camera)
        microphone = try values.decodeIfPresent(Bool.self, forKey: .microphone)
        app = try values.decodeIfPresent(String.self, forKey: .app)
        apps = try values.decodeIfPresent([String].self, forKey: .apps)
        theme = try values.decodeIfPresent(String.self, forKey: .theme)
    }

    /// `app` and `apps` as one list. Setting it writes `app` for one app and `apps` for several.
    var appList: [String]? {
        get { app == nil && apps == nil ? nil : (app.map { [$0] } ?? []) + (apps ?? []) }
        set {
            app = newValue?.count == 1 ? newValue?.first : nil
            apps = (newValue?.count ?? 0) > 1 ? newValue : nil
        }
    }

    func matches(_ context: ConfigurationContext) -> Bool {
        !unknownCondition && unmet(in: context).isEmpty
    }

    /// The conditions `context` doesn't meet.
    func unmet(in context: ConfigurationContext) -> [CodingKeys] {
        let appInFront = appList?.contains(context.app) ?? true
        let met: [(CodingKeys, Bool)] = [
            (.appearance, appearance == nil || appearance == context.appearance),
            (.onBattery, onBattery == nil || onBattery == context.onBattery),
            (.displayCount, displayCount == nil || displayCount == context.displayCount),
            (.externalDisplay, externalDisplay == nil || externalDisplay == context.externalDisplay),
            (.display, display.map { context.displays.contains($0) } ?? true),
            (.wifi, wifi == nil || wifi == context.wifi),
            (.camera, camera == nil || camera == context.camera),
            (.microphone, microphone == nil || microphone == context.microphone),
            (.app, app == nil || appInFront),
            (.apps, apps == nil || appInFront),
            // Classic is Built-in's files, so profiles that included files keep on `built-in` still apply to it.
            (.theme, theme == nil || theme == context.theme || theme == "built-in" && context.theme == "classic"),
        ]
        return met.filter { !$0.1 }.map(\.0)
    }
}

enum ThemeConfigurationError: LocalizedError {
    case unknownReference(String)
    case referenceCycle([String])
    case referenceExpansionTooLarge(String)
    case referenceOriginsTooLarge(String)
    case referenceNestingTooDeep(String)
    case unknownProfile(String)
    case duplicateProfile(String)

    var errorDescription: String? {
        switch self {
        case let .unknownReference(name): "Unknown configuration reference: \(name)."
        case let .referenceCycle(names): "Configuration reference cycle: \(names.joined(separator: " → "))."
        case let .referenceExpansionTooLarge(name):
            "Configuration references expand past StableBar's limit at \(name). "
                + "Check tokens or settings that refer to each other."
        case let .referenceOriginsTooLarge(name):
            "Configuration references at \(name) produce more than StableBar can track. "
                + "Check tokens or settings that refer to each other or are used in many places."
        case let .referenceNestingTooDeep(name):
            "Configuration references nest more than 64 levels deep at \(name). "
                + "Check tokens or settings that refer to each other."
        case let .unknownProfile(name): "Unknown configuration profile: \(name)."
        case let .duplicateProfile(name): "Duplicate configuration profile: \(name)."
        }
    }
}

func substituteConfigurationReferences(_ value: ConfigurationValue, prefix: String,
                                       values: [String: ConfigurationValue],
                                       path: [String] = [],
                                       budget: ConfigurationReferenceExpansionBudget? = nil) throws -> ConfigurationValue {
    var path = path
    var namesOnPath = Set(path)
    func resolve(_ remaining: inout Int) throws -> ConfigurationValue {
        try substituteReferences(value, prefix: prefix, values: values,
                                 path: &path, namesOnPath: &namesOnPath, remaining: &remaining,
                                 depth: max(0, path.count - 1))
    }
    if let budget { return try budget.withRemaining(resolve) }
    var remaining = configurationReferenceExpansionLimit
    return try resolve(&remaining)
}

private func substituteReferences(_ value: ConfigurationValue, prefix: String,
                                  values: [String: ConfigurationValue], path: inout [String],
                                  namesOnPath: inout Set<String>,
                                  remaining: inout Int, depth: Int) throws -> ConfigurationValue {
    var depth = depth
    if let name = path.last {
        remaining -= 1
        switch value {
        case let .string(string) where !string.hasPrefix(prefix):
            remaining -= string.utf8.count / 256
        case let .object(object):
            for key in object.keys { remaining -= key.utf8.count / 256 }
        default:
            break
        }
        guard remaining >= 0 else {
            throw ThemeConfigurationError.referenceExpansionTooLarge(name)
        }
        switch value {
        case .array, .object:
            depth += 1
        case let .string(string) where string.hasPrefix(prefix):
            depth += 1
        default:
            break
        }
        guard depth <= configurationReferenceDepthLimit else {
            throw ThemeConfigurationError.referenceNestingTooDeep(name)
        }
    }
    if case let .string(string) = value, string.hasPrefix(prefix) {
        let name = String(string.dropFirst(prefix.count))
        guard !namesOnPath.contains(name) else {
            throw ThemeConfigurationError.referenceCycle(path + [name])
        }
        guard let replacement = values[name] else {
            throw ThemeConfigurationError.unknownReference(string)
        }
        // Visiting the replacement counts the hop's first unit; long names also cost hashing and lookup work.
        remaining -= name.utf8.count / 256
        guard remaining >= 0 else {
            throw ThemeConfigurationError.referenceExpansionTooLarge(name)
        }
        path.append(name)
        namesOnPath.insert(name)
        defer {
            path.removeLast()
            namesOnPath.remove(name)
        }
        return try substituteReferences(replacement, prefix: prefix, values: values,
                                        path: &path, namesOnPath: &namesOnPath, remaining: &remaining, depth: depth)
    }
    switch value {
    case let .object(object):
        return .object(try object.mapValues {
            try substituteReferences($0, prefix: prefix, values: values,
                                     path: &path, namesOnPath: &namesOnPath, remaining: &remaining, depth: depth)
        })
    case let .array(array):
        return .array(try array.map {
            try substituteReferences($0, prefix: prefix, values: values,
                                     path: &path, namesOnPath: &namesOnPath, remaining: &remaining, depth: depth)
        })
    default:
        return value
    }
}
