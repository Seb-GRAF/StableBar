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

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type, command, interval, timeout, environment, whenVisible, events, calendars, lookahead, soon, now, processes
    }

    init(type: String) {
        self.type = type
        command = nil
        interval = 5
        timeout = 10
        environment = [:]
        whenVisible = false
        events = []
        calendars = []
        lookahead = 24
        soon = 15
        now = 5
        processes = 0
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        guard let source = DataSourceRegistry.builtIn[type] else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown provider type.")
        }
        command = source.settings.contains(.command) ? try values.decode(String.self, forKey: .command) : nil
        interval = try values.decodeIfPresent(Double.self, forKey: .interval) ?? 5
        timeout = try values.decodeIfPresent(Double.self, forKey: .timeout) ?? 10
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        whenVisible = try values.decodeIfPresent(Bool.self, forKey: .whenVisible) ?? false
        events = try values.decodeIfPresent([String].self, forKey: .events) ?? []
        calendars = try values.decodeIfPresent([String].self, forKey: .calendars) ?? []
        lookahead = try values.decodeIfPresent(Double.self, forKey: .lookahead) ?? 24
        soon = try values.decodeIfPresent(Int.self, forKey: .soon) ?? 15
        now = try values.decodeIfPresent(Int.self, forKey: .now) ?? 5
        processes = try values.decodeIfPresent(Int.self, forKey: .processes) ?? 0
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
