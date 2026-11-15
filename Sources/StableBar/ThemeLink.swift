import Foundation

struct ThemeLink: Equatable, Sendable {
    var manifest: Data
    var configuration: Data

    static let maximumLength = 65_536
    static let maximumFileBytes = 32_768
    static let maximumDepth = 32
    static let maximumProfiles = 16

    init(manifest: Data, configuration: Data) {
        self.manifest = manifest
        self.configuration = configuration
    }

    init?(url: URL) throws(ThemeLinkError) {
        try self.init(url: url, decode: { try JSONDecoder().decode(ConfigurationValue.self, from: $0) })
    }

    // The decoder is injectable so tests can verify that limits are checked before decoding.
    init?(url: URL, decode: (Data) throws -> ConfigurationValue) throws(ThemeLinkError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "stablebar", components.host?.lowercased() == "theme" else { return nil }
        guard url.absoluteString.utf8.count <= Self.maximumLength else { throw .tooLong }
        guard components.path.isEmpty, components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil else { throw .damaged }

        let items = components.queryItems ?? []
        func item(_ name: String) throws(ThemeLinkError) -> String {
            let matches = items.filter { $0.name == name }
            guard matches.count == 1, let value = matches.first?.value else { throw .damaged }
            return value
        }
        let version = try item("v")
        guard version == "1" else {
            guard let number = Int(version), number > 1 else { throw .damaged }
            throw .unsupportedVersion(version)
        }
        guard let manifest = Self.decoded(try item("package")),
              let configuration = Self.decoded(try item("config")) else { throw .damaged }
        let link = Self(manifest: manifest, configuration: configuration)
        try link.validateFiles()
        do {
            for file in [manifest, configuration] {
                guard case .object = try decode(file) else { throw ThemeLinkError.damaged }
            }
        } catch { throw .damaged }
        self.init(manifest: manifest, configuration: configuration)
    }

    func validateFiles() throws(ThemeLinkError) {
        guard manifest.count + configuration.count <= Self.maximumFileBytes else { throw .tooLarge }
        // ConfigurationValue's recursive decoding is expensive even without references, so bound the raw JSON first.
        try Self.checkJSON(manifest, limitProfiles: false)
        try Self.checkJSON(configuration, limitProfiles: true)
    }

    var link: URL {
        var components = URLComponents()
        components.scheme = "stablebar"
        components.host = "theme"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "package", value: Self.encoded(manifest)),
            URLQueryItem(name: "config", value: Self.encoded(configuration))
        ]
        return components.url!
    }

    private static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decoded(_ text: String) -> Data? {
        let unpadded = text.prefix { $0 != "=" }
        let padding = (4 - unpadded.utf8.count % 4) % 4
        guard padding != 3 else { return nil }
        let suffix = text.dropFirst(unpadded.count)
        if !suffix.isEmpty {
            guard suffix.count == padding, suffix.allSatisfy({ $0 == "=" }) else { return nil }
        }
        guard unpadded.utf8.allSatisfy({ byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
            default: false
            }
        }) else { return nil }
        let base64 = unpadded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: padding))
    }

    private static func checkJSON(_ data: Data, limitProfiles: Bool) throws(ThemeLinkError) {
        try scan(data, limitProfiles: limitProfiles)
        do {
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                throw ThemeLinkError.damaged
            }
        } catch { throw .damaged }
    }

    private static func scan(_ data: Data, limitProfiles: Bool) throws(ThemeLinkError) {
        let bytes = try jsonBytes(data)
        var depth = 0
        var inString = false
        var escaped = false
        var expectingKey = true
        var keyStart: Int?
        var key: String?
        var inProfiles = false
        var profileCount = 0
        var inProfile = false

        // Scan every value because parsed dictionaries discard duplicate keys.
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") {
                    inString = false
                    if let start = keyStart {
                        let name = try? JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: .fragmentsAllowed)
                        guard let name = name as? String else { throw .damaged }
                        key = name
                        keyStart = nil
                    }
                }
                continue
            }
            if inProfiles, depth == 2 {
                switch byte {
                case UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
                     UInt8(ascii: " "), UInt8(ascii: "]"): break
                case UInt8(ascii: ","): inProfile = false
                default:
                    if !inProfile {
                        profileCount += 1
                        guard profileCount <= maximumProfiles else { throw .tooManyProfiles }
                        inProfile = true
                    }
                }
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                if limitProfiles, depth == 1, expectingKey {
                    keyStart = index
                    expectingKey = false
                }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                guard depth <= maximumDepth else { throw .tooDeep }
                if limitProfiles, depth == 2, byte == UInt8(ascii: "["), key == "profiles" {
                    inProfiles = true
                    profileCount = 0
                    inProfile = false
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 2, byte == UInt8(ascii: "]") { inProfiles = false }
                depth -= 1
            case UInt8(ascii: ",") where depth == 1:
                expectingKey = true
                key = nil
            default: break
            }
        }
        guard depth == 0, !inString else { throw .damaged }
    }

    private static func jsonBytes(_ data: Data) throws(ThemeLinkError) -> [UInt8] {
        guard var text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else { throw .damaged }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let bytes = Array(text.utf8)
        let first = bytes.first { byte in
            switch byte {
            case UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: " "): false
            default: true
            }
        }
        guard first == UInt8(ascii: "{") else { throw .damaged }
        return bytes
    }
}

enum ThemeLinkError: LocalizedError, Equatable {
    case tooLong, unsupportedVersion(String), damaged, tooLarge, tooDeep, tooManyProfiles
    case notATheme, needsReview, extraFiles
    case barProperty(String), reservedID(String), idTaken(String)
    case versionTaken(id: String, version: String)

    var errorDescription: String? {
        switch self {
        case .tooLong: "This theme link is too long. Download the theme as a zip from the page instead."
        case .unsupportedVersion: "This theme link needs a newer version of StableBar."
        case .damaged: "This theme link is damaged. Copy it again from the page."
        case .tooLarge: "This theme is larger than a theme link can carry (32 KB)."
        case .tooDeep: "This theme nests its settings more than 32 levels deep."
        case .tooManyProfiles: "This theme has more than 16 profiles, which a theme link can't carry."
        case .notATheme: "This link doesn't hold a theme."
        case .needsReview: "This theme asks for hosts, permissions, tools or secrets, which a theme link can't carry."
        case .extraFiles: "This theme refers to other files, such as a screenshot or an include, which a theme link can't carry."
        case let .barProperty(key): "A theme link can't set the bar's \(key)."
        case let .reservedID(id): "\(id) is the ID of a theme that comes with StableBar. Rename the theme on the page."
        case let .idTaken(id): "A widget package already uses the ID \(id). Rename the theme on the page."
        case let .versionTaken(id, version):
            "A different \(id) \(version) is already installed. Raise the version on the page and try again."
        }
    }
}
