import Foundation

/// Persists explicit user grants; a valid code signature proves integrity, not publisher authenticity.
@MainActor
final class NativePluginTrustStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func isTrusted(pluginID: String, bundleID: String, version: String, signature: NativePluginSignature) throws -> Bool {
        try read().grants[pluginID] == Grant(bundleID: bundleID, version: version, signature: signature)
    }

    func grant(pluginID: String, bundleID: String, version: String, signature: NativePluginSignature) throws {
        var document = try read()
        document.grants[pluginID] = Grant(bundleID: bundleID, version: version, signature: signature)
        try write(document)
    }

    func revoke(pluginID: String) throws {
        var document = try read()
        guard document.grants.removeValue(forKey: pluginID) != nil else { return }
        try write(document)
    }

    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }

    private func write(_ document: Document) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }
}

private struct Document: Codable {
    var grants: [String: Grant] = [:]
}

private struct Grant: Codable, Equatable {
    let bundleID: String
    let version: String
    let signature: Signature

    init(bundleID: String, version: String, signature: NativePluginSignature) {
        self.bundleID = bundleID
        self.version = version
        self.signature = Signature(signature)
    }
}

private struct Signature: Codable, Equatable {
    let identifier: String
    let teamIdentifier: String
    let cdhash: String

    init(_ signature: NativePluginSignature) {
        identifier = signature.identifier
        teamIdentifier = signature.teamIdentifier
        cdhash = signature.cdhash
    }
}
