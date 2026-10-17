import Foundation
import Testing
@testable import StableBar

private struct BuildMetadataFixture {
    let directory: URL
    let repository: URL
    let sourcePlist: URL
    let packagedPlist: URL
    let app: URL
    let originalPlist: Data

    init(version: String = "0.5.0-beta.74", build: String = "1057") throws {
        let files = FileManager.default
        directory = files.temporaryDirectory.appending(path: UUID().uuidString)
        repository = directory.appending(path: "source")
        sourcePlist = repository.appending(path: "Resources/Info.plist")
        app = directory.appending(path: "StableBar.app")
        packagedPlist = app.appending(path: "Contents/Info.plist")
        originalPlist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleName": "StableBar",
            "CFBundleExecutable": "StableBar",
            "CFBundleIdentifier": "com.stablebar.metadata-test.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "LSMinimumSystemVersion": "14.0"
        ], format: .xml, options: 0)
        try files.createDirectory(at: sourcePlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: repository.appending(path: "scripts"), withIntermediateDirectories: true)
        try files.createDirectory(at: packagedPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalPlist.write(to: sourcePlist)
        let helper = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/prepare-app-info.sh")
        try files.copyItem(at: helper, to: repository.appending(path: "scripts/prepare-app-info.sh"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        let data = try await runCommand("/usr/bin/git", arguments: [
            "-C", repository.path,
            "-c", "user.name=StableBar Tests",
            "-c", "user.email=tests@example.invalid",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
            "-c", "core.hooksPath=/dev/null"
        ] + arguments)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func initializeGit(tag: String? = "v0.5.0-beta.74") async throws {
        try await git(["init", "--quiet"])
        try await git(["add", "."])
        try await git(["commit", "--quiet", "-m", "Initial fixture"])
        if let tag { try await git(["tag", tag]) }
    }

    func package(release: Bool = false) async throws -> Bundle {
        _ = try await runCommand(repository.appending(path: "scripts/prepare-app-info.sh").path,
            arguments: [packagedPlist.path], environment: ["STABLEBAR_RELEASE_BUILD": release ? "1" : "0"])
        #expect(try Data(contentsOf: sourcePlist) == originalPlist)
        let bundle = try #require(Bundle(url: app))
        let original = try #require(PropertyListSerialization.propertyList(
            from: originalPlist, options: [], format: nil) as? [String: Any])
        #expect(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            == original["CFBundleShortVersionString"] as? String)
        #expect(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            == original["CFBundleVersion"] as? String)
        return bundle
    }
}

@Test(arguments: ["0.5.0-beta.74", "0.5.0"])
func packagedVersionReleasePreservesStampedMetadata(version: String) async throws {
    let fixture = try BuildMetadataFixture(version: version)
    defer { fixture.remove() }
    try await fixture.initializeGit()
    try Data("unreleased changes".utf8).write(to: fixture.repository.appending(path: "untracked.txt"))

    let bundle = try await fixture.package(release: true)
    let metadata = AppVersion(bundle: bundle)

    #expect(try Data(contentsOf: fixture.packagedPlist) == fixture.originalPlist)
    #expect(bundle.object(forInfoDictionaryKey: "StableBarDevelopmentBuild") == nil)
    #expect(bundle.object(forInfoDictionaryKey: "StableBarSourceRevision") == nil)
    #expect(metadata.version == version)
    #expect(metadata.build == "1057")
    #expect(metadata.channel == (version.contains("beta") ? .beta : .stable))
}

@Test(arguments: ["0.5.0-beta.74", "0.5.0"])
func packagedVersionCleanTaggedCheckoutIsDevelopment(version: String) async throws {
    let fixture = try BuildMetadataFixture(version: version)
    defer { fixture.remove() }
    try await fixture.initializeGit(tag: "v\(version)")
    let revision = try await fixture.git(["rev-parse", "--short", "HEAD"])

    let bundle = try await fixture.package()
    let metadata = AppVersion(bundle: bundle)

    #expect(bundle.object(forInfoDictionaryKey: "StableBarDevelopmentBuild") as? Bool == true)
    #expect(bundle.object(forInfoDictionaryKey: "StableBarSourceRevision") as? String
        == "\(version)-0-g\(revision)")
    #expect(metadata.channel == .development)
    #expect(metadata.version == "\(version)-0-g\(revision)")
    #expect(metadata.build == nil)
    #expect(try await fixture.git(["status", "--porcelain"]) == "")
}

@Test(arguments: ["clean", "modified", "untracked"])
func packagedVersionIncludesLocalCommitAndDirtyState(state: String) async throws {
    let fixture = try BuildMetadataFixture()
    defer { fixture.remove() }
    try await fixture.initializeGit()
    let trackedFile = fixture.repository.appending(path: "tracked.txt")
    try Data("committed change".utf8).write(to: trackedFile)
    try await fixture.git(["add", "."])
    try await fixture.git(["commit", "--quiet", "-m", "Local change"])
    let revision = try await fixture.git(["rev-parse", "--short", "HEAD"])
    if state == "modified" {
        try Data("uncommitted change".utf8).write(to: trackedFile)
    } else if state == "untracked" {
        try Data("untracked change".utf8).write(to: fixture.repository.appending(path: "untracked.txt"))
    }

    let bundle = try await fixture.package()
    let metadata = AppVersion(bundle: bundle)
    let dirtySuffix = state == "clean" ? "" : "-dirty"

    #expect(metadata.channel == .development)
    #expect(metadata.version == "0.5.0-beta.74-1-g\(revision)\(dirtySuffix)")
    #expect(metadata.build == nil)
}

@Test func packagedVersionUntaggedCheckoutIncludesDevelopmentRevision() async throws {
    let fixture = try BuildMetadataFixture()
    defer { fixture.remove() }
    try await fixture.initializeGit(tag: nil)
    let revision = try await fixture.git(["rev-parse", "--short", "HEAD"])

    let metadata = AppVersion(bundle: try await fixture.package())

    #expect(metadata.channel == .development)
    #expect(metadata.version == "0.0.0-dev.\(revision)")
    #expect(metadata.build == nil)
}

@Test func packagedVersionWithoutGitIsDevelopment() async throws {
    let fixture = try BuildMetadataFixture(version: "0.5.0")
    defer { fixture.remove() }

    let bundle = try await fixture.package()
    let metadata = AppVersion(bundle: bundle)
    let packages = WidgetPackageStore(directory: fixture.directory.appending(path: "packages"),
        appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    #expect(metadata.channel == .development)
    #expect(metadata.version == "0.0.0-dev")
    #expect(metadata.build == nil)
    #expect(!packages.requiresNewerApp("0.4.0"))
    #expect(packages.requiresNewerApp("0.6.0"))
}
