import Foundation
import Testing
import XCTest
@testable import StableBar

private func sources(_ json: String) throws -> [PackageSource] {
    try JSONDecoder().decode([PackageSource].self, from: Data(json.utf8))
}

@Test func packageSourcesDecodeAndRejectUnsafeValues() throws {
    let url = "https://gitlab.example.com/api/v4/projects/1/packages/generic/stablebar/store/index.json"
    #expect(try sources(#"[{"id":"acme","name":"Acme","url":"\#(url)"}]"#) == [PackageSource(id: "acme", name: "Acme", url: URL(string: url)!)])
    for bad in [
        #"[{"id":"acme","name":"Acme","url":"http://x.example/index.json"}]"#,
        #"[{"id":"acme","name":"Acme","url":"https://x.example/index.json?ref=main"}]"#,
        #"[{"id":"stablebar","name":"Mine","url":"https://x.example/index.json"}]"#,
        #"[{"id":"local","name":"Mine","url":"https://x.example/index.json"}]"#,
        #"[{"id":"a b","name":"Mine","url":"https://x.example/index.json"}]"#,
        #"[{"id":"acme","name":"  ","url":"https://x.example/index.json"}]"#,
        #"[{"id":"acme","name":"Acme","url":"https://x.example/index.json","token":"x"}]"#
    ] {
        #expect(throws: (any Error).self) { try sources(bad) }
    }
}

@Test func onlyThePublicStoreIsNamedStableBarStore() throws {
    // The last name ends in a newline, escaped for JSON.
    for name in ["StableBar Store", "stablebar store", "  STABLEBAR STORE\\n"] {
        #expect(throws: PackageSourceError.reservedName("acme")) {
            try sources(#"[{"id":"acme","name":"\#(name)","url":"https://x.example/index.json"}]"#)
        }
    }
    #expect(PackageSourceError.reservedName("acme").localizedDescription
        == "Package source acme can’t be named StableBar Store. Choose another name.")
    #expect(try sources(#"[{"id":"acme","name":"StableBar Store Acme","url":"https://x.example/index.json"}]"#).count == 1)
    let url = "https%3A%2F%2Fx.example%2Findex.json"
    #expect(PackageSourceLink(url: URL(string: "stablebar://add-source?name=StableBar%20Store&url=\(url)")!) == nil)
    #expect(PackageSourceLink(url: URL(string: "stablebar://add-source?name=%20stablebar%20STORE&url=\(url)&id=acme")!) == nil)
    #expect(PackageSourceLink(url: URL(string: "stablebar://add-source?name=Acme&url=\(url)")!) != nil)
}

@Test func packageSourcesMergeByIDAndStayOutOfPackagesAndProfiles() throws {
    let fixture = try ThemeGalleryFixture(#"{"includes":["team.json"],"widgets":[],"packageSources":[{"id":"acme","name":"Acme","url":"https://b.example/index.json"}]}"#)
    defer { fixture.close() }
    try fixture.write(#"{"packageSources":[{"id":"acme","name":"Acme","url":"https://a.example/index.json"},{"id":"team","name":"Team","url":"https://t.example/index.json"}]}"#,
                      to: fixture.directory.appending(path: "team.json"))
    var loader = ConfigurationLoader()
    _ = try loader.load(fixture.url)
    let configured = try PackageSource.configured(in: loader.document)
    #expect(configured.map(\.id) == ["stablebar", "acme", "team"])
    #expect(configured[1].url.absoluteString == "https://b.example/index.json")
    #expect(try PackageSource.configured(at: fixture.url) == configured)

    try fixture.write(#"{"widgets":[],"packageSources":[{"id":"x","name":"X","url":"https://x.example/i.json"},{"id":"x","name":"Y","url":"https://y.example/i.json"}]}"#, to: fixture.url)
    #expect(throws: PackageSourceError.duplicateID("x")) { var l = ConfigurationLoader(); _ = try l.load(fixture.url) }

    try fixture.write(#"{"widgets":[],"profiles":[{"name":"night","configuration":{"packageSources":[]}}]}"#, to: fixture.url)
    #expect(throws: PackageSourceError.inProfile("night")) { var l = ConfigurationLoader(); _ = try l.load(fixture.url) }

    let package = fixture.directory.appending(path: "sources/sneaky")
    try fixture.write(#"{"id":"sneaky","name":"Sneaky","version":"1","kind":"widgets","entry":"config.json"}"#, to: package.appending(path: "package.json"))
    try fixture.write(#"{"widgets":[],"packageSources":[]}"#, to: package.appending(path: "config.json"))
    #expect(throws: PackageSourceError.inPackage) { _ = try fixture.packages.inspect(package) }
}

@Test func sourceRequestsCarryTheTokenOnlyToTheirOwnOrigin() {
    let gitlab = PackageSource(id: "acme", name: "Acme", url: URL(string: "https://gitlab.example.com/api/v4/projects/1/packages/generic/stablebar/store/index.json")!)
    let github = PackageSource(id: "team", name: "Team", url: URL(string: "https://raw.githubusercontent.com/team/bar/store/index.json")!)
    let gitlabRequest = sourceRequest(for: gitlab.url, source: gitlab, token: "t1")
    #expect(gitlabRequest.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "t1")
    #expect(gitlabRequest.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(sourceRequest(for: github.url.deletingLastPathComponent().appending(path: "clock-1.tar.gz"), source: github, token: "t2")
        .value(forHTTPHeaderField: "Authorization") == "Bearer t2")
    for url in ["https://cdn.example.com/shot.png", "https://raw.githubusercontent.com:8443/x", "http://raw.githubusercontent.com/x"] {
        #expect(sourceRequest(for: URL(string: url)!, source: github, token: "t2").allHTTPHeaderFields?.isEmpty ?? true)
    }
    #expect(sourceRequest(for: github.url, source: github, token: "").value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func redirectsToAnotherOriginDropTheToken() {
    func request(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        request.setValue("t", forHTTPHeaderField: "PRIVATE-TOKEN")
        return request
    }
    let origin = URL(string: "https://raw.githubusercontent.com/a")!
    let away = redirectRequest(request("https://objects.githubusercontent.com/x"), from: origin)
    #expect(away.value(forHTTPHeaderField: "Authorization") == nil && away.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    #expect(redirectRequest(request("https://raw.githubusercontent.com/b"), from: origin).value(forHTTPHeaderField: "Authorization") == "Bearer t")
    #expect(URLSession.packageSources.delegate is SourceRedirectGuard)
}

/// A source token goes out in request headers, and a disk cache would keep those headers in Cache.db.
@Test func sourceRequestsKeepNothingOnDisk() {
    let configuration = URLSession.packageSources.configuration
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    #expect(configuration.urlCredentialStorage !== URLCredentialStorage.shared)
    #expect(URLSession.packageSources.delegate is SourceRedirectGuard)
}

@Test func originsComparePortsAndSchemesWithDefaults() {
    func same(_ a: String, _ b: String) -> Bool { sameOrigin(URL(string: a)!, URL(string: b)!) }
    #expect(same("https://Example.com/a", "https://example.com:443/b"))
    #expect(same("http://example.com/a", "http://example.com:80/b"))
    #expect(!same("https://example.com/a", "http://example.com/a"))
    #expect(!same("https://example.com/a", "https://example.com:8443/a"))
    #expect(!same("https://example.com/a", "https://example.org/a"))
}

@Test func configurationCannotReadASourceToken() async {
    let environment = await ScriptEvent(sender: "test").commandEnvironment(["T": "@secret.source:acme", "P": "@secret.pkg/token"]) { "value-for-\($0)" }
    #expect(environment["T"] == "")
    #expect(environment["P"] == "value-for-pkg/token")
}

@Test func realRedirectsDropTheTokenOnlyWhenTheyLeaveTheOrigin() async throws {
    let source = PackageSource(id: "redirect", name: "Redirect", url: URL(string: "https://a.redirect-test.example/index.json")!)
    let away = URL(string: "https://b.redirect-test.example/index.json")!
    StubURLProtocol.redirect(source.url, to: away)
    StubURLProtocol.serve(Data("moved".utf8), at: away)

    let data = try await fetch(sourceRequest(for: source.url, source: source, token: "secret"), session: StubURLProtocol.session())
    #expect(String(decoding: data, as: UTF8.self) == "moved")
    let requests = StubURLProtocol.requests
    let first = requests.first { $0.url == source.url }
    #expect(first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let followed = requests.filter { $0.url?.host() == "b.redirect-test.example" }
    #expect(followed.count == 1)
    #expect(followed.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil })

    let same = PackageSource(id: "same", name: "Same", url: URL(string: "https://a.same-origin-test.example/index.json")!)
    let old = URL(string: "https://a.same-origin-test.example/old.json")!
    StubURLProtocol.redirect(old, to: same.url)
    StubURLProtocol.serve(Data("index".utf8), at: same.url)

    let index = try await fetch(sourceRequest(for: old, source: same, token: "secret"), session: StubURLProtocol.session())
    #expect(String(decoding: index, as: UTF8.self) == "index")
    let kept = StubURLProtocol.requests.filter { $0.url == same.url }
    #expect(kept.count == 1)
    #expect(kept.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
}

final class PackageInstallRecordTests: XCTestCase {
    private func clockFolder(_ fixture: ThemeGalleryFixture, _ version: String) throws -> URL {
        let url = fixture.directory.appending(path: "sources/clock-\(version)")
        try fixture.write(#"{"id":"clock","name":"Clock","version":"\#(version)","kind":"widgets","entry":"config.json"}"#, to: url.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[]}"#, to: url.appending(path: "config.json"))
        return url
    }

    func testInstallRecordsFollowTheClaimingRules() throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        func folder(_ version: String) throws -> URL { try clockFolder(fixture, version) }
        let acme = PackageInstallRecord(PackageSource(id: "acme", name: "Acme", url: URL(string: "https://a.example/index.json")!))
        let team = PackageInstallRecord(PackageSource(id: "team", name: "Team", url: URL(string: "https://t.example/index.json")!))
        _ = try fixture.packages.install(folder("1"))
        XCTAssertEqual(try fixture.packages.record(id: "clock"), .local)
        // Acme claims the ID with version 2; the folder's version 1 stays the folder's.
        _ = try fixture.packages.install(folder("2"), record: acme, requestedName: "Acme")
        var withFolderVersion = acme
        withFolderVersion.localVersions = ["1"]
        XCTAssertEqual(try fixture.packages.record(id: "clock"), withFolderVersion)
        _ = try fixture.packages.install(folder("3"))
        withFolderVersion.localVersions = ["1", "3"]
        XCTAssertEqual(try fixture.packages.record(id: "clock"), withFolderVersion)
        XCTAssertThrowsError(try fixture.packages.install(folder("4"), record: team, requestedName: "Team")) {
            XCTAssertEqual(errorMessage($0), "Clock is installed from Acme. Uninstall it before getting it from Team.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "packages/clock/4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "packages/clock/\(PackageInstallRecord.fileName)").path))
        XCTAssertEqual(try fixture.packages.list().map(\.version), ["1", "2", "3"])
        XCTAssertEqual(try fixture.packages.records(), ["clock": withFolderVersion])
    }

    /// Versions installed before StableBar recorded sources are of unknown origin: a source claiming the ID doesn't take them.
    func testClaimingALegacyIDLeavesItsOtherVersionsLocal() throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        let acme = PackageInstallRecord(PackageSource(id: "acme", name: "Acme", url: URL(string: "https://a.example/index.json")!))
        _ = try fixture.packages.install(clockFolder(fixture, "1"))
        _ = try fixture.packages.install(clockFolder(fixture, "10"))
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "packages/clock/\(PackageInstallRecord.fileName)"))
        _ = try fixture.packages.install(clockFolder(fixture, "2"), record: acme, requestedName: "Acme")
        var owned = acme
        owned.localVersions = ["1", "10"]
        XCTAssertEqual(try fixture.packages.record(id: "clock"), owned)
    }

    /// A folder version of an ID a source owns keeps the owner and is remembered as the folder's until it's uninstalled.
    @MainActor func testFolderVersionsOfASourcesIDAreRecordedUntilUninstalled() async throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        let acme = PackageInstallRecord(PackageSource(id: "acme", name: "Acme", url: URL(string: "https://a.example/index.json")!))
        let recordFile = fixture.directory.appending(path: "packages/clock/\(PackageInstallRecord.fileName)")
        _ = try fixture.packages.install(clockFolder(fixture, "1"), record: acme, requestedName: "Acme")
        XCTAssertFalse(try String(contentsOf: recordFile, encoding: .utf8).contains("localVersions"))
        _ = try fixture.packages.install(clockFolder(fixture, "2"))
        var owned = acme
        owned.localVersions = ["2"]
        XCTAssertEqual(try fixture.packages.record(id: "clock"), owned)
        XCTAssertTrue(owned.isLocal(version: "2"))
        XCTAssertFalse(owned.isLocal(version: "1"))
        let store = try fixture.store()
        try store.configurationStore.uninstallPackage(id: "clock", version: "2")
        XCTAssertEqual(try fixture.packages.record(id: "clock"), acme)
        XCTAssertFalse(try String(contentsOf: recordFile, encoding: .utf8).contains("localVersions"))
        // A record written before local versions existed still reads.
        try #"{"name":"Acme","source":"acme","url":"https://a.example/index.json"}"#.write(to: recordFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), acme)
    }

    @MainActor func testUninstallingTheLastVersionReleasesTheID() async throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        let acme = PackageInstallRecord(PackageSource(id: "acme", name: "Acme", url: URL(string: "https://a.example/index.json")!))
        _ = try fixture.packages.install(clockFolder(fixture, "1"), record: acme, requestedName: "Acme")
        _ = try fixture.packages.install(clockFolder(fixture, "2"), record: acme, requestedName: "Acme")
        let store = try fixture.store()
        try store.configurationStore.uninstallPackage(id: "clock", version: "1")
        XCTAssertEqual(try fixture.packages.record(id: "clock"), acme)
        try store.configurationStore.uninstallPackage(id: "clock", version: "2")
        XCTAssertNil(try fixture.packages.record(id: "clock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "packages/clock").path))
        let team = PackageInstallRecord(PackageSource(id: "team", name: "Team", url: URL(string: "https://t.example/index.json")!))
        _ = try fixture.packages.install(clockFolder(fixture, "3"), record: team, requestedName: "Team")
        XCTAssertEqual(try fixture.packages.record(id: "clock"), team)
    }

    @MainActor func testLocalInstallsRecordWhyTheyCameFromNoSource() async throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "index.json"))
        let recordFile = fixture.directory.appending(path: "packages/test-theme/\(PackageInstallRecord.fileName)")
        _ = try await client.install(fixture.theme("{}", install: false).directory, from: nil, origin: .barLink)
        var shared = PackageInstallRecord.local
        shared.origin = .barLink
        XCTAssertEqual(try fixture.packages.record(id: "test-theme"), shared)
        XCTAssertEqual(PackageOrigin.installed(record: shared, version: "1", listedInStore: false, sources: [.store]), .barLink)
        // A record written before origins existed reads as a folder, and a folder's record is still written without one.
        try #"{"source":"local"}"#.write(to: recordFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.packages.record(id: "test-theme"), .local)
        XCTAssertEqual(PackageOrigin.installed(record: try fixture.packages.record(id: "test-theme"), version: "1", listedInStore: false,
                                               sources: [.store]), .local)
        _ = try await client.install(fixture.theme("{}", version: "2", install: false).directory, from: nil)
        XCTAssertFalse(try String(contentsOf: recordFile, encoding: .utf8).contains("origin"))
    }

    @MainActor func testUninstallingAThemeRemovesEveryVersionAndItsRecord() async throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "index.json"))
        for version in ["1.0.0", "1.0.1"] {
            _ = try await client.install(fixture.theme("{}", id: "my-theme", version: version, install: false).directory, from: nil, origin: .saved)
        }
        _ = try fixture.theme("{}", id: "other-theme")
        let store = try fixture.store()
        defer { store.stop() }
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        try await library.uninstallTheme(id: "my-theme")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "packages/my-theme").path))
        XCTAssertNil(try fixture.packages.record(id: "my-theme"))
        XCTAssertEqual(library.installed.map(\.id), ["other-theme"])
    }

    func testStoreInstallsRecordTheirSource() async throws {
        let fixture = try ThemeGalleryFixture(); defer { fixture.close() }
        let store = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        _ = try await store.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        let client = PackageStoreClient(packages: fixture.packages, indexURL: store.url)
        await client.setPrivateSources([PackageSource(id: "acme", name: "Acme", url: acme.url)])
        let entries = await client.catalog().entries
        let storeEntry = try XCTUnwrap(entries.first { $0.sourceID == PackageSource.storeID })
        let acmeEntry = try XCTUnwrap(entries.first { $0.sourceID == "acme" })

        _ = try await client.installWithoutReview(acmeEntry)
        XCTAssertEqual(try fixture.packages.record(id: "clock")?.source, "acme")
        XCTAssertEqual(try fixture.packages.record(id: "clock")?.name, "Acme")
        do {
            _ = try await client.installWithoutReview(storeEntry)
            XCTFail("Another source claimed clock")
        } catch {
            XCTAssertEqual(errorMessage(error), "Clock is installed from Acme. Uninstall it before getting it from StableBar Store.")
        }
        XCTAssertEqual(try fixture.packages.record(id: "clock")?.source, "acme")
        let records = try await client.records()
        XCTAssertEqual(records["clock"]?.source, "acme")

        // A version installed before records existed is unclaimed: the first source to install it claims it.
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "packages/clock/\(PackageInstallRecord.fileName)"))
        XCTAssertNil(try fixture.packages.record(id: "clock"))
        _ = try await client.installWithoutReview(storeEntry)
        XCTAssertEqual(try fixture.packages.record(id: "clock")?.source, PackageSource.storeID)
        XCTAssertEqual(try fixture.packages.list().map(\.version), ["1"])
    }
}

@MainActor @Test func sourceDraftsDeriveUniqueIDsAndValidateURLs() {
    let acme = PackageSource(id: "acme", name: "Acme", url: URL(string: "https://a.example/index.json")!)
    let draft = PackageSourceDraft(existing: [.store, acme])
    draft.name = "Acme"; #expect(draft.id == "acme-2")
    draft.name = "Tonhalle Line!"; #expect(draft.id == "tonhalle-line")
    draft.urlText = "http://a.example/index.json"; #expect(draft.source == nil)
    draft.urlText = "https://b.example/index.json"; #expect(draft.source != nil && !draft.canSave)
}

@Test func slugsKeepEmptyNamesEmptyAndSourceIDsFallBack() {
    #expect(packageSlug("Tonhalle Line!") == "tonhalle-line")
    #expect(packageSlug("日本") == "")
    #expect(PackageSource.newID(for: "日本", taken: []) == "source")
    #expect(PackageSource.newID(for: "", taken: ["source"]) == "source-2")
    #expect(PackageSource.newID(for: "Local", taken: []) == "local-2")
}

@Test func sourceCountsUseTheSingularForOne() {
    #expect(PackageSourceDraft.State.found(widgets: 2, themes: 1).summary == "Found 3 packages: 2 widgets, 1 theme")
    #expect(PackageSourceDraft.State.found(widgets: 1, themes: 2).summary == "Found 3 packages: 1 widget, 2 themes")
    #expect(PackageSourceDraft.State.found(widgets: 1, themes: 0).summary == "Found 1 package: 1 widget")
    #expect(PackageSourceDraft.State.found(widgets: 0, themes: 4).summary == "Found 4 packages: 4 themes")
    #expect(PackageSourceDraft.State.found(widgets: 0, themes: 0).summary == "Found no packages")
    #expect(PackageSourceDraft.State.idle.summary == nil)
    #expect(counted(1, "package") == "1 package")
    #expect(counted(0, "package") == "0 packages")
    #expect(counted(12, "package") == "12 packages")
}
