import Foundation
import Testing
@testable import StableBar

private struct NativePluginPackageFixture {
    let fixture = try! ThemeGalleryFixture()
    var directory: URL { fixture.directory.appending(path: "source") }
    var bundle: URL { directory.appending(path: "Code/Example.bundle", directoryHint: .isDirectory) }

    func writePackage(nativeBundle: String = "Code/Example.bundle") throws {
        try fixture.write(#"{"id":"clock","name":"Clock","version":"1.0.0","kind":"widgets","entry":"config.json","nativeBundle":"\#(nativeBundle)"}"#,
                          to: directory.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[]}"#, to: directory.appending(path: "config.json"))
    }

    func makeUnsignedBundle() throws {
        let executable = bundle.appending(path: "Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "clock",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "BNDL",
            "NSPrincipalClass": "ExamplePlugin",
            "StableBarNativeWidgetPluginAPIMajor": 1
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        let source = fixture.directory.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-x", "c", source.path, "-o", executable.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NativePluginSignatureError.invalidBundle }
    }

    func close() { fixture.close() }
}

@Test func packageManifestAcceptsAnOptionalNativeBundlePath() throws {
    let fixture = NativePluginPackageFixture()
    defer { fixture.close() }
    try fixture.writePackage()

    #expect(try fixture.fixture.packages.manifest(at: fixture.directory).nativeBundle == "Code/Example.bundle")
    let legacy = fixture.directory.appending(path: "legacy")
    try fixture.fixture.write(#"{"id":"legacy","name":"Legacy","version":"1","entry":"config.json"}"#,
                              to: legacy.appending(path: "package.json"))
    #expect(try fixture.fixture.packages.manifest(at: legacy).nativeBundle == nil)
}

@Test func nativeBundlesRequireAWidgetsPackage() throws {
    #expect(throws: Error.self) {
        try JSONDecoder().decode(WidgetPackageManifest.self,
                                 from: Data(#"{"id":"theme","name":"Theme","version":"1","kind":"theme","entry":"config.json","nativeBundle":"Theme.bundle"}"#.utf8))
    }
}

@Test func packageInspectionRejectsAnUnsignedNativeBundle() throws {
    let fixture = NativePluginPackageFixture()
    defer { fixture.close() }
    try fixture.writePackage()
    try fixture.makeUnsignedBundle()

    #expect(throws: NativePluginSignatureError.self) { _ = try fixture.fixture.packages.inspect(fixture.directory) }
}

@Test func packageInspectionRejectsNativeBundlePathsOutsideThePackage() throws {
    let fixture = NativePluginPackageFixture()
    defer { fixture.close() }
    try fixture.writePackage(nativeBundle: "../Example.bundle")

    let error = #expect(throws: WidgetPackageError.self) {
        _ = try fixture.fixture.packages.inspect(fixture.directory)
    }
    #expect(error?.localizedDescription.contains("escapes") == true, "Actual error: \(String(describing: error))")
}

@Test func nativeBundlesRequireReviewAndEveryVersionUpgradeAddsItsSigningDetails() throws {
    func inspection(version: String) throws -> WidgetPackageInspection {
        let manifest = try JSONDecoder().decode(WidgetPackageManifest.self, from: Data(
            #"{"id":"clock","name":"Clock","version":"\#(version)","kind":"widgets","entry":"config.json","nativeBundle":"Code/Example.bundle"}"#.utf8))
        let signature = NativePluginSignature(identifier: "clock", teamIdentifier: "TEAM123", cdhash: "aabbccdd")
        let bundle = NativePluginBundle(packageID: manifest.id, version: manifest.version, path: "Code/Example.bundle",
                                        url: URL(fileURLWithPath: "/tmp/Example.bundle"), bundleID: "clock", apiMajor: 1,
                                        signature: signature)
        return WidgetPackageInspection(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/package"), commands: [],
                                       screenshot: nil, widgets: [], nativePluginBundle: bundle)
    }
    let old = try inspection(version: "1.0.0")
    let new = try inspection(version: "1.1.0")

    #expect(old.requiresReview)
    #expect(old.storeReviewStatus == "The Store package includes native code")
    #expect(old.storeReviewHint?.contains("does not restrict") == true)
    #expect(new.additions(since: old) == [new.nativePluginBundle!.review.description])
}

@Test func nativeBundleSignatureChangesRequireReviewEvenWhenVersionStaysTheSame() throws {
    let manifest = try JSONDecoder().decode(WidgetPackageManifest.self, from: Data(
        #"{"id":"clock","name":"Clock","version":"1.0.0","kind":"widgets","entry":"config.json","nativeBundle":"Code/Example.bundle"}"#.utf8))
    func inspection(cdhash: String) -> WidgetPackageInspection {
        let signature = NativePluginSignature(identifier: "clock", teamIdentifier: "TEAM123", cdhash: cdhash)
        let bundle = NativePluginBundle(packageID: manifest.id, version: manifest.version, path: "Code/Example.bundle",
                                        url: URL(fileURLWithPath: "/tmp/Example.bundle"), bundleID: "clock", apiMajor: 1,
                                        signature: signature)
        return WidgetPackageInspection(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/package"), commands: [],
                                       screenshot: nil, widgets: [], nativePluginBundle: bundle)
    }
    let old = inspection(cdhash: "aabbccdd")
    let changed = inspection(cdhash: "ddeeff00")

    #expect(changed.additions(since: old) == [changed.nativePluginBundle!.review.description])
}

@Test func nativePluginReviewExplainsInProcessRiskAndSigningIdentity() {
    let signature = NativePluginSignature(identifier: "clock", teamIdentifier: "TEAM123", cdhash: "aabbccdd")
    let review = NativePluginReview(packageID: "clock", version: "1.0.0", path: "Code/Example.bundle",
                                    bundleID: "clock", apiMajor: 1, signature: signature)

    #expect(review.description.contains("arbitrary native code"))
    #expect(review.description.contains("inside StableBar"))
    #expect(review.description.contains("TEAM123"))
    #expect(review.description.contains("aabbccdd"))
}

@Test @MainActor func directAddWithOnlyADisplayedReviewCannotPassPreflight() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let library = PackageLibrary(store: store)
    let signature = NativePluginSignature(identifier: "clock", teamIdentifier: "TEAM123", cdhash: "aabbccdd")
    let plugin = NativePluginBundle(packageID: "clock", version: "1.0.0", path: "Code/Example.bundle",
                                    url: URL(fileURLWithPath: "/tmp/Example.bundle"), bundleID: "clock", apiMajor: 1,
                                    signature: signature)
    let manifest = try JSONDecoder().decode(WidgetPackageManifest.self, from: Data(
        #"{"id":"clock","name":"Clock","version":"1.0.0","kind":"widgets","entry":"config.json"}"#.utf8))
    let draft = PackageDraft(inspection: WidgetPackageInspection(manifest: manifest, directory: fixture.directory,
                                                                 commands: [], screenshot: nil, widgets: [], nativePluginBundle: plugin),
                             settings: [:])
    draft.reviewedNativePlugin = plugin.review

    let error = #expect(throws: WidgetPackageError.self) {
        // The displayed review on the draft is deliberately not passed as the button's consent argument.
        try library.requireNativeReviewOrTrust(plugin, reviewed: nil)
    }
    #expect(error?.localizedDescription.contains("Review the native code") == true)
}
