import Foundation

struct ProviderConfiguration: Decodable, Equatable, Sendable {
    /// A type name in `DataSourceRegistry.builtIn`.
    let type: String
    let command: String?
    let interval: Double
    let timeout: Double
    let environment: [String: String]
    let whenVisible: Bool
    let events: [String]
    let calendars: [String]
    let lookahead: Double
    let soon: Int
    let now: Int
    let processes: Int
    let sortBy: ProcessSort
    let units: NetworkUnits
    let cpuWarning: Double
    let memoryWarning: Double
    let diskWarning: Double
    let diskCritical: Double
    /// The providers a `merge` combines.
    let providers: [String]
    /// What an `http` provider requests, with `headers` and a `token` sent as `Authorization: Bearer`.
    let url: URL?
    let headers: [String: String]
    let token: String?
    let output: HTTPOutput?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type, command, interval, timeout, environment, whenVisible, events, calendars, lookahead, soon, now, processes
        case sortBy, units, cpuWarning, memoryWarning, diskWarning, diskCritical, providers, url, headers, token, output
    }

    init(type: String) {
        self.type = type
        command = nil
        providers = []
        url = nil
        headers = [:]
        token = nil
        output = nil
        interval = DataSourceRegistry.builtIn[type]?.defaultInterval ?? 5
        timeout = 10
        environment = [:]
        whenVisible = false
        events = []
        calendars = []
        lookahead = 24
        soon = 15
        now = 5
        processes = 0
        sortBy = .memory
        units = .bytes
        cpuWarning = 0.9
        memoryWarning = 0.9
        diskWarning = 0.85
        diskCritical = 0.95
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        guard let source = DataSourceRegistry.builtIn[type] else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown provider type.")
        }
        command = source.settings.contains(.command) ? try values.decode(String.self, forKey: .command) : nil
        providers = source.settings.contains(.providers) ? try values.decode([String].self, forKey: .providers) : []
        url = source.settings.contains(.url) ? try values.decode(URL.self, forKey: .url) : nil
        output = source.settings.contains(.output) ? try values.decode(HTTPOutput.self, forKey: .output) : nil
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        token = try values.decodeIfPresent(String.self, forKey: .token)
        interval = try values.decodeIfPresent(Double.self, forKey: .interval) ?? source.defaultInterval
        timeout = try values.decodeIfPresent(Double.self, forKey: .timeout) ?? 10
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        whenVisible = try values.decodeIfPresent(Bool.self, forKey: .whenVisible) ?? false
        events = try values.decodeIfPresent([String].self, forKey: .events) ?? []
        calendars = try values.decodeIfPresent([String].self, forKey: .calendars) ?? []
        lookahead = try values.decodeIfPresent(Double.self, forKey: .lookahead) ?? 24
        soon = try values.decodeIfPresent(Int.self, forKey: .soon) ?? 15
        now = try values.decodeIfPresent(Int.self, forKey: .now) ?? 5
        processes = try values.decodeIfPresent(Int.self, forKey: .processes) ?? 0
        sortBy = try values.decodeIfPresent(ProcessSort.self, forKey: .sortBy) ?? .memory
        units = try values.decodeIfPresent(NetworkUnits.self, forKey: .units) ?? .bytes
        cpuWarning = try values.decodeIfPresent(Double.self, forKey: .cpuWarning) ?? 0.9
        memoryWarning = try values.decodeIfPresent(Double.self, forKey: .memoryWarning) ?? 0.9
        diskWarning = try values.decodeIfPresent(Double.self, forKey: .diskWarning) ?? 0.85
        diskCritical = try values.decodeIfPresent(Double.self, forKey: .diskCritical) ?? 0.95
        guard interval > 0, interval.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .interval, in: values,
                                                  debugDescription: "A provider interval must be greater than zero and finite.")
        }
        guard timeout > 0, timeout.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .timeout, in: values,
                                                  debugDescription: "A provider timeout must be greater than zero and finite.")
        }
        guard processes >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .processes, in: values, debugDescription: "A provider's processes must be zero or more.")
        }
        if let url, url.scheme?.lowercased() != "https" {
            throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "A provider url must use https.")
        }
    }
}

/// What an `http` provider copies from its JSON response, each part found by a JSON Pointer such as
/// `/current/temperature_2m`. A pointer that finds nothing leaves its part out.
struct HTTPOutput: Decodable, Equatable, Sendable {
    let text: String?
    let fields: [String: String]
    let values: [String: String]
    /// Pointers to arrays: each object in one becomes a row of its members that are strings, numbers or booleans.
    let lists: [String: String]

    enum CodingKeys: String, CodingKey, CaseIterable { case text, fields, values, lists }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        fields = try container.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
        values = try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        lists = try container.decodeIfPresent([String: String].self, forKey: .lists) ?? [:]
        for pointer in [text ?? ""] + fields.values + values.values + lists.values where !pointer.isEmpty && !pointer.hasPrefix("/") {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                   debugDescription: "A JSON Pointer starts with /, unlike \(pointer)."))
        }
    }

    func output(from response: ConfigurationValue) -> ScriptOutput {
        ScriptOutput(text: text.flatMap { response.value(at: $0)?.text } ?? "",
                     fields: fields.compactMapValues { response.value(at: $0)?.text },
                     lists: lists.compactMapValues { pointer in
                         guard case let .array(rows)? = response.value(at: pointer) else { return nil }
                         return rows.compactMap { row in
                             guard case let .object(members) = row else { return nil }
                             return members.compactMapValues(\.text)
                         }
                     },
                     values: values.compactMapValues { response.value(at: $0)?.number })
    }
}

extension ConfigurationValue {
    /// The value that a JSON Pointer (RFC 6901) such as `/items/0/name` finds, or nil when there is none.
    func value(at pointer: String) -> ConfigurationValue? {
        var value = self
        for token in pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch value {
            case let .object(object):
                guard let member = object[key] else { return nil }
                value = member
            case let .array(array):
                guard let index = Int(key), array.indices.contains(index) else { return nil }
                value = array[index]
            default:
                return nil
            }
        }
        return value
    }

    /// A string, a number as JSON writes it, or `true` or `false`.
    fileprivate var text: String? {
        switch self {
        case let .string(string): string
        case let .number(number): Int(exactly: number).map(String.init) ?? String(number)
        case let .bool(bool): String(bool)
        default: nil
        }
    }

    /// A number, or a string that holds one, as some APIs send prices.
    fileprivate var number: Double? {
        switch self {
        case let .number(number): number
        case let .string(string): Double(string)
        default: nil
        }
    }
}

enum ProcessSort: String, Decodable, Sendable {
    case memory, cpu
}

enum NetworkUnits: String, Decodable, Sendable {
    case bytes, bits

    func rate(_ bytes: Double) -> String {
        let base = self == .bytes ? 1024.0 : 1000.0
        let units = self == .bytes ? ["B/s", "KiB/s", "MiB/s", "GiB/s"] : ["bit/s", "kbit/s", "Mbit/s", "Gbit/s"]
        var value = self == .bytes ? bytes : bytes * 8
        var index = 0
        while value >= base && index < units.count - 1 { value /= base; index += 1 }
        return String(format: value < 10 && index > 0 ? "%.1f %@" : "%.0f %@", value, units[index])
    }
}

struct ScriptDiagnostics: Codable, Sendable {
    var running = false
    var suspended = false
    var lastEvent: String?
    var lastStarted: Date?
    var lastUpdated: Date?
    var lastDuration: Double?
    var lastStdout = ""
    var lastStderr = ""
    var executionCount = 0
    var failureCount = 0
    var restartCount = 0
    var consecutiveFailures = 0
    var nextDelay: Double?
    var cpuTime = 0.0
}

func providerRetryDelay(interval: Double, failures: Int) -> Double {
    max(interval, min(300, max(1, interval) * pow(2, Double(min(failures - 1, 9)))))
}
