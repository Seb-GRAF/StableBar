import AppKit
import Foundation
import NativeWidgetPluginABI
import Testing
@testable import StableBar

@MainActor
private struct NativeWidgetPluginLoaderFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "native-plugin-loader-\(UUID().uuidString)", directoryHint: .isDirectory)
    var bundle: URL { directory.appending(path: "Example.bundle", directoryHint: .isDirectory) }
    var trustStore: NativePluginTrustStore { NativePluginTrustStore(url: directory.appending(path: "trust.json")) }

    func createBundle(apiMajor: Any = 1, executable: String = "Example", bundleID: String = "org.example.plugin",
                      version: String = "1.0.0", marker: String = "original") throws {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "BNDL",
            "CFBundleExecutable": executable,
            "NSPrincipalClass": "ExamplePrincipal",
            "StableBarNativeWidgetPluginAPIMajor": apiMajor,
            "NativePluginTestMarker": marker
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    func replaceMarker(_ marker: String) throws {
        let infoURL = bundle.appending(path: "Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        var info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        info["NativePluginTestMarker"] = marker
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    }

    func marker(at bundle: URL) throws -> String? {
        let data = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return info["NativePluginTestMarker"] as? String
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class LoaderTestHost: NSObject, StableBarNativeWidgetHost {
    func requestPopup() {}
    func saveSettings(_ settings: [String: Any]) {}
}

@MainActor
private final class LoaderTestPlugin: NSObject, StableBarNativeWidgetPlugin {
    var apiVersion: Int { 1 }
    var stopCount = 0
    var lastEvent: String?
    func makeWidgetView() -> NSView { NSView() }
    func makePopupView() -> NSView { NSView() }
    func start() {}
    func stop() { stopCount += 1 }
    func stableBarDidReceiveEvent(_ name: String, payload: [String: Any]) { lastEvent = name }
}

@Test @MainActor func nativeWidgetPluginLoaderDoesNotLoadAnUntrustedBundle() throws {
    let fixture = NativeWidgetPluginLoaderFixture()
    defer { fixture.close() }
    try fixture.createBundle()
    let signature = NativePluginSignature(identifier: "org.example.plugin", teamIdentifier: "ABCDE12345", cdhash: "010203")
    var didLoad = false
    let loader = NativeWidgetPluginLoader(
        trustStore: fixture.trustStore,
        signatureVerifier: { _ in signature },
        bundleLoader: { _ in didLoad = true }
    )

    let error = #expect(throws: NativeWidgetPluginLoaderError.self) {
        try loader.load(at: fixture.bundle, expectedPluginID: "org.example.plugin", expectedVersion: "1.0.0")
    }

    #expect(error == .notTrusted)
    #expect(!didLoad)
}

@Test @MainActor func nativeWidgetPluginLoaderLoadsTheVerifiedCopyAfterSourceIsReplaced() throws {
    let fixture = NativeWidgetPluginLoaderFixture()
    defer { fixture.close() }
    try fixture.createBundle()
    let signature = NativePluginSignature(identifier: "org.example.plugin", teamIdentifier: "ABCDE12345", cdhash: "010203")
    try fixture.trustStore.grant(pluginID: "org.example.plugin", bundleID: "org.example.plugin",
                                 version: "1.0.0", signature: signature)
    var verifiedURL: URL?
    var loadedURL: URL?
    var loadedMarker: String?
    let loader = NativeWidgetPluginLoader(
        trustStore: fixture.trustStore,
        signatureVerifier: { url in
            verifiedURL = url
            try fixture.replaceMarker("replaced-after-verification")
            return signature
        },
        bundleLoader: { bundle in
            loadedURL = bundle.bundleURL
            loadedMarker = try fixture.marker(at: bundle.bundleURL)
        },
        principalClassResolver: { _ in LoaderTestPlugin.self }
    )

    var instance: NativeWidgetPluginInstance? = try loader.load(
        at: fixture.bundle, expectedPluginID: "org.example.plugin", expectedVersion: "1.0.0")

    #expect(verifiedURL != fixture.bundle)
    #expect(loadedURL == verifiedURL)
    #expect(loadedMarker == "original")
    #expect(instance?.bundle.bundleURL == verifiedURL)
    let stagedDirectory = try #require(loadedURL?.deletingLastPathComponent())
    let attributes = try FileManager.default.attributesOfItem(atPath: stagedDirectory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    instance?.start(host: LoaderTestHost(), settings: [:])
    instance?.stop()
    instance = nil
    #expect(FileManager.default.fileExists(atPath: stagedDirectory.path))
    #expect(try fixture.marker(at: fixture.bundle) == "replaced-after-verification")
}

@Test @MainActor func nativeWidgetPluginLoaderRejectsMissingPrincipalAfterTrustedLoadWithoutCrashing() throws {
    let fixture = NativeWidgetPluginLoaderFixture()
    defer { fixture.close() }
    try fixture.createBundle()
    let signature = NativePluginSignature(identifier: "org.example.plugin", teamIdentifier: "ABCDE12345", cdhash: "010203")
    try fixture.trustStore.grant(pluginID: "org.example.plugin", bundleID: "org.example.plugin",
                                 version: "1.0.0", signature: signature)
    let loader = NativeWidgetPluginLoader(
        trustStore: fixture.trustStore,
        signatureVerifier: { _ in signature },
        bundleLoader: { _ in }
    )

    #expect(throws: NativeWidgetPluginLoaderError.missingPrincipalClass) {
        try loader.load(at: fixture.bundle, expectedPluginID: "org.example.plugin", expectedVersion: "1.0.0")
    }
}

@Test @MainActor func nativeWidgetPluginLoaderRejectsUnsupportedAPIBeforeSignatureCheck() throws {
    let fixture = NativeWidgetPluginLoaderFixture()
    defer { fixture.close() }
    try fixture.createBundle(apiMajor: 2)
    var checkedSignature = false
    let loader = NativeWidgetPluginLoader(
        trustStore: fixture.trustStore,
        signatureVerifier: { _ in
            checkedSignature = true
            return NativePluginSignature(identifier: "org.example.plugin", teamIdentifier: "ABCDE12345", cdhash: "010203")
        },
        bundleLoader: { _ in Issue.record("An unsupported bundle must never load") }
    )

    let error = #expect(throws: NativeWidgetPluginLoaderError.self) {
        try loader.load(at: fixture.bundle, expectedPluginID: "org.example.plugin", expectedVersion: "1.0.0")
    }

    #expect(error == .unsupportedAPI(2))
    #expect(!checkedSignature)
}

@Test @MainActor func nativeWidgetPluginMetadataRejectsFractionalAPIMajorAndEmptyExecutable() throws {
    let fixture = NativeWidgetPluginLoaderFixture()
    defer { fixture.close() }
    try fixture.createBundle(apiMajor: 1.5)
    #expect(throws: NativeWidgetPluginLoaderError.invalidMetadata) {
        try NativeWidgetPluginMetadata.read(at: fixture.bundle)
    }

    fixture.close()
    try fixture.createBundle(executable: "")
    #expect(throws: NativeWidgetPluginLoaderError.invalidMetadata) {
        try NativeWidgetPluginMetadata.read(at: fixture.bundle)
    }
}

@Test @MainActor func nativeWidgetPluginInstanceForwardsEventsAndStopsWhenReleased() throws {
    let plugin = LoaderTestPlugin()
    var instance: NativeWidgetPluginInstance? = NativeWidgetPluginInstance(bundle: .main, plugin: plugin)
    instance?.sendEvent(name: "host.ready", payload: ["source": "test"])
    #expect(plugin.lastEvent == "host.ready")
    instance?.start(host: LoaderTestHost(), settings: [:])
    instance = nil
    #expect(plugin.stopCount == 1)
}
