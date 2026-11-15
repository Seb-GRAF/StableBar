import Foundation

let configurationReferenceExpansionLimit = 100_000

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
    case unknownProfile(String)
    case duplicateProfile(String)

    var errorDescription: String? {
        switch self {
        case let .unknownReference(name): "Unknown configuration reference: \(name)."
        case let .referenceCycle(names): "Configuration reference cycle: \(names.joined(separator: " → "))."
        case let .referenceExpansionTooLarge(name):
            "Configuration references expand to more than 100,000 values at \(name). "
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
    return try substituteReferences(value, prefix: prefix, values: values, path: path, remaining: &remaining)
}

private func substituteReferences(_ value: ConfigurationValue, prefix: String,
                                  values: [String: ConfigurationValue], path: [String],
                                  remaining: inout Int) throws -> ConfigurationValue {
    if case let .string(string) = value, string.hasPrefix(prefix) {
        let name = String(string.dropFirst(prefix.count))
        guard !path.contains(name) else {
            throw ThemeConfigurationError.referenceCycle(path + [name])
        }
        guard let replacement = values[name] else {
            throw ThemeConfigurationError.unknownReference(string)
        }
        return try substituteReferences(replacement, prefix: prefix, values: values,
                                        path: path + [name], remaining: &remaining)
    }
    if let name = path.last {
        remaining -= 1
        guard remaining >= 0 else {
            throw ThemeConfigurationError.referenceExpansionTooLarge(name)
        }
    }
    switch value {
    case let .object(object):
        return .object(try object.mapValues {
            try substituteReferences($0, prefix: prefix, values: values, path: path, remaining: &remaining)
        })
    case let .array(array):
        return .array(try array.map {
            try substituteReferences($0, prefix: prefix, values: values, path: path, remaining: &remaining)
        })
    default:
        return value
    }
}
