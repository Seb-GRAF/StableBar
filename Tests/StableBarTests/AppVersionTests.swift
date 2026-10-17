import Testing
@testable import StableBar

@Test func appVersionReadsStableReleaseAndDottedBuild() {
    let version = AppVersion(version: "0.4.0", build: "0.4.0")
    #expect(version.channel == .stable)
    #expect(version.version == "0.4.0")
    #expect(version.build == "0.4.0")
}

@Test func appVersionKeepsBetaVersionAndBuildNumberSeparate() {
    let version = AppVersion(version: "1.2.3-beta.4", build: "57")
    #expect(version.channel == .beta)
    #expect(version.version == "1.2.3-beta.4")
    #expect(version.build == "57")
}

@Test func appVersionDoesNotCallOtherPrereleasesStable() {
    #expect(AppVersion(version: "1.2.3-rc.1", build: nil).channel == .prerelease)
}

@Test func appVersionDistinguishesBuildMetadataFromPrerelease() {
    #expect(AppVersion(version: "1.2.3+beta.4", build: nil).channel == .stable)
    #expect(AppVersion(version: "1.2.3-beta.4+local", build: nil).channel == .beta)
}

@Test(arguments: [nil, ""] as [String?])
func appVersionHandlesMissingBundleMetadata(value: String?) {
    let version = AppVersion(version: value, build: value)
    #expect(version.channel == .development)
    #expect(version.version == nil)
    #expect(version.build == nil)
}

@Test func appVersionDoesNotRequireABuildNumber() {
    let version = AppVersion(version: "1.2.3", build: nil)
    #expect(version.channel == .stable)
    #expect(version.version == "1.2.3")
    #expect(version.build == nil)
}
