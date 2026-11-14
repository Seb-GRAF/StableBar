import Foundation
import Testing
@testable import StableBar

@MainActor
private struct NativePluginTrustFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "native-plugin-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
    var url: URL { directory.appending(path: "trust.json") }
    var signature: NativePluginSignature {
        NativePluginSignature(identifier: "org.example.plugin", teamIdentifier: "ABCDE12345", cdhash: "010203")
    }

    func store() -> NativePluginTrustStore { NativePluginTrustStore(url: url) }
    func close() { try? FileManager.default.removeItem(at: directory) }
}

@Test @MainActor func nativePluginTrustRequiresExplicitGrantAndPersists() throws {
    let fixture = NativePluginTrustFixture()
    defer { fixture.close() }
    let store = fixture.store()

    #expect(try !store.isTrusted(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                                 version: "1.0.0", signature: fixture.signature))
    try store.grant(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                    version: "1.0.0", signature: fixture.signature)

    let reopened = fixture.store()
    #expect(try reopened.isTrusted(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                                   version: "1.0.0", signature: fixture.signature))
}

@Test @MainActor func nativePluginTrustCanBeRevoked() throws {
    let fixture = NativePluginTrustFixture()
    defer { fixture.close() }
    let store = fixture.store()
    try store.grant(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                    version: "1.0.0", signature: fixture.signature)

    try store.revoke(pluginID: "org.example.plugin")

    #expect(try !store.isTrusted(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                                 version: "1.0.0", signature: fixture.signature))
}

@Test @MainActor func nativePluginTrustDoesNotSurviveBundleVersionOrSignatureChanges() throws {
    let fixture = NativePluginTrustFixture()
    defer { fixture.close() }
    let store = fixture.store()
    try store.grant(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                    version: "1.0.0", signature: fixture.signature)

    #expect(try !store.isTrusted(pluginID: "org.example.plugin", bundleID: "org.example.other.bundle",
                                 version: "1.0.0", signature: fixture.signature))
    #expect(try !store.isTrusted(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                                 version: "1.1.0", signature: fixture.signature))
    let changedSignature = NativePluginSignature(identifier: fixture.signature.identifier,
                                                  teamIdentifier: fixture.signature.teamIdentifier, cdhash: "aabbcc")
    #expect(try !store.isTrusted(pluginID: "org.example.plugin", bundleID: "org.example.plugin.bundle",
                                 version: "1.0.0", signature: changedSignature))
}
