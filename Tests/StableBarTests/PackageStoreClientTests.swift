import CryptoKit
import XCTest
@testable import StableBar

struct LocalPackageIndex {
    let fixture: ThemeGalleryFixture
    var url: URL { fixture.directory.appending(path: "store/index.json") }

    func add(id: String = "store-theme", kind: String? = "theme", configuration: String = #"{"bar":{"height":31}}"#,
             checksum: String? = nil, listedKind: String? = nil, settings: String = "{}", version: String = "1",
             hosts: String = "[]", permissions: String = "[]", requires: String = "[]") async throws -> PackageIndex.Entry {
        let source = fixture.directory.appending(path: "sources/\(id)")
        let kindField = kind.map { #", "kind":"\#($0)""# } ?? ""
        try fixture.write(#"{"id":"\#(id)","name":"Store theme","version":"\#(version)","entry":"config.json","settings":\#(settings),"hosts":\#(hosts),"permissions":\#(permissions),"requires":\#(requires)\#(kindField)}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write(configuration, to: source.appending(path: "config.json"))
        let archive = url.deletingLastPathComponent().appending(path: "\(id).tar.gz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await runCommand("/usr/bin/tar", arguments: ["-czf", archive.path, "-C", source.path, "."])
        let hash = try checksum ?? SHA256.hash(data: Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let indexKind = (listedKind ?? kind).map { #", "kind":"\#($0)""# } ?? ""
        try fixture.write(#"""
        {"packages":[{"id":"future","kind":"future-kind"},
         {"id":"\#(id)","name":"Store theme","version":"\#(version)","archive":"\#(id).tar.gz","sha256":"\#(hash)",
          "source":"https://example.com/package","future":true\#(indexKind)}],"future":true}
        """#, to: url)
        return try await PackageIndex.load(from: url).packages[0]
    }
}

final class PackageStoreClientTests: XCTestCase {
    func testIndexAndVerifiedDownloadsAreCachedForTheSession() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add()
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let entries = try await client.index().packages
        XCTAssertEqual(entries.map(\.id), ["store-theme"])
        let download = try await client.package(entries[0])
        XCTAssertEqual(download.manifest.kind, .theme)
        XCTAssertTrue(download.commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.packages.directory.path))
        try FileManager.default.removeItem(at: index.url.deletingLastPathComponent())
        let cached = try await client.index().packages
        XCTAssertEqual(cached.map(\.id), [entry.id])
        let package = try await client.package(entry)
        XCTAssertEqual(package.directory, download.directory)
        let installed = try await client.installWithoutReview(entry)
        XCTAssertEqual(installed.directory, fixture.directory.appending(path: "packages/store-theme/1"))
        let repeated = try await client.installWithoutReview(entry)
        XCTAssertEqual(repeated.directory, installed.directory)
    }

    func testOfflineIndexFailureCanBeRetriedWithoutAffectingInstalledPackages() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        _ = try fixture.theme(#"{}"#)
        let index = LocalPackageIndex(fixture: fixture)
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        do { _ = try await client.index(); XCTFail("A missing local index must fail") } catch {}
        _ = try await index.add()
        let result = try await client.index()
        XCTAssertEqual(result.packages.count, 1)
        XCTAssertEqual(try fixture.packages.list().map(\.id), ["test-theme"])
    }

    func testCommandFreeWidgetsAndLegacyPackagesCanInstallWithoutReview() async throws {
        for kind: String? in ["widgets", nil] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let index = LocalPackageIndex(fixture: fixture)
            let entry = try await index.add(id: "clock", kind: kind, configuration: #"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
            let installed = try await PackageStoreClient(packages: fixture.packages, indexURL: index.url).installWithoutReview(entry)
            XCTAssertEqual(installed.manifest.id, "clock")
            XCTAssertTrue(installed.commands.isEmpty)
        }
    }

    func testCommandsIncludingInactiveProfilesAndTemplatesAlwaysRequireReview() async throws {
        for configuration in [
            #"{"widgets":[{"id":"script","type":"script","position":"left","command":"echo forbidden"}]}"#,
            #"{"widgets":[],"profiles":[{"name":"inactive","when":{"appearance":"dark"},"configuration":{"widgets":[{"id":"note","type":"text","position":"left","text":"Note","onClick":"echo forbidden"}]}}]}"#,
            #"{"widgets":[],"templates":{"unused":{"type":"script","command":"echo forbidden"}}}"#
        ] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let index = LocalPackageIndex(fixture: fixture)
            let entry = try await index.add(id: "commands", kind: nil, configuration: configuration)
            let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
            do { _ = try await client.installWithoutReview(entry); XCTFail("Commands must require review") }
            catch { XCTAssertTrue(error is PackageStoreClientError) }
            XCTAssertTrue(try fixture.packages.list().isEmpty)
        }
    }

    func testHostsOnlyDownloadRequiresReviewBeforeInstalling() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "hosts", kind: "widgets", configuration: #"{"widgets":[]}"#,
                                        hosts: #"["example.com"]"#)
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        do { _ = try await client.installWithoutReview(entry); XCTFail("Declared hosts must require review") }
        catch PackageStoreClientError.reviewRequired {}
        XCTAssertTrue(try fixture.packages.list().isEmpty)
    }

    func testHostsOnlyInstalledVersionRequiresReviewEvenWithAPlainDownload() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "hosts", kind: "widgets", configuration: #"{"widgets":[]}"#)
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let installed = try await client.installWithoutReview(entry)
        try fixture.write(#"{"id":"hosts","name":"Hosts","version":"1","kind":"widgets","entry":"config.json","hosts":["example.com"]}"#,
                          to: installed.directory.appending(path: "package.json"))
        do { _ = try await client.installWithoutReview(entry); XCTFail("Installed hosts must require review") }
        catch PackageStoreClientError.reviewRequired {}
        XCTAssertEqual(try fixture.packages.list().count, 1)
    }

    func testBadChecksumInvalidThemeAndMisleadingKindCannotBeInstalled() async throws {
        for failure in ["checksum", "theme", "kind"] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let index = LocalPackageIndex(fixture: fixture)
            let entry = try await index.add(kind: failure == "kind" ? nil : "theme",
                configuration: failure == "theme" ? #"{"providers":{"bad":{"type":"command","command":"echo forbidden"}}}"# : #"{}"#,
                checksum: failure == "checksum" ? String(repeating: "0", count: 64) : nil,
                listedKind: failure == "kind" ? "theme" : nil)
            do {
                _ = try await PackageStoreClient(packages: fixture.packages, indexURL: index.url).installWithoutReview(entry)
                XCTFail("Invalid package must fail: \(failure)")
            } catch {}
            XCTAssertTrue(try fixture.packages.list().isEmpty)
        }
    }
    func testCachedCommandFreeInspectionCannotBypassReviewIfItsFilesChange() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "legacy", kind: nil, configuration: #"{"widgets":[]}"#)
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let cached = try await client.package(entry)
        try fixture.write(#"{"widgets":[{"id":"script","type":"script","position":"left","command":"echo forbidden"}]}"#,
                          to: cached.directory.appending(path: "config.json"))
        do { _ = try await client.installWithoutReview(entry); XCTFail("Changed commands must require review") }
        catch { XCTAssertTrue(error is PackageStoreClientError) }
        XCTAssertTrue(try fixture.packages.list().isEmpty)
    }

}
