import Foundation

let configurationReferenceExpansionLimit = 100_000
// Keeps reference recursion within a worker thread's stack.
let configurationReferenceDepthLimit = 64

struct ConfigurationContext: Sendable, Equatable {
    var appearance = "light"
    var onBattery = false
    var displayCount = 1
    var externalDisplay = false
    var app = ""
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
    var app: String?
    /// A condition from a newer release, which this one can't check, so the profile never matches on its own.
    var unknownCondition = false

    enum CodingKeys: String, CodingKey, CaseIterable { case appearance, onBattery, displayCount, externalDisplay, app }

    init() {}

    init(from decoder: Decoder) throws {
        unknownCondition = try !decoder.rejectUnknownKeys(CodingKeys.self).isEmpty
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance)
        onBattery = try values.decodeIfPresent(Bool.self, forKey: .onBattery)
        displayCount = try values.decodeIfPresent(Int.self, forKey: .displayCount)
        externalDisplay = try values.decodeIfPresent(Bool.self, forKey: .externalDisplay)
        app = try values.decodeIfPresent(String.self, forKey: .app)
    }

    func matches(_ context: ConfigurationContext) -> Bool {
        !unknownCondition
            && (appearance == nil || appearance == context.appearance)
            && (onBattery == nil || onBattery == context.onBattery)
            && (displayCount == nil || displayCount == context.displayCount)
            && (externalDisplay == nil || externalDisplay == context.externalDisplay)
            && (app == nil || app == context.app)
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
                                       path: [String] = []) throws -> ConfigurationValue {
    var remaining = configurationReferenceExpansionLimit
    var path = path
    var namesOnPath = Set(path)
    return try substituteReferences(value, prefix: prefix, values: values,
                                    path: &path, namesOnPath: &namesOnPath, remaining: &remaining,
                                    depth: max(0, path.count - 1))
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
