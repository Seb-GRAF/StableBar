import Foundation
import Testing
@testable import StableBar

/// A configuration folder reached through a symbolic link, as dotfiles setups keep `~/.config/stablebar`.
struct PackagePathTests {
    let files = FileManager.default
    let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `scratch/link` leads to `scratch/real`, which holds the configuration folder.
    func linkedConfiguration() throws -> (link: URL, real: URL) {
        let real = scratch.appending(path: "real")
        try files.createDirectory(at: real, withIntermediateDirectories: true)
        let link = scratch.appending(path: "link")
        try files.createSymbolicLink(at: link, withDestinationURL: real)
        return (link, real)
    }

    @Test func packagesInstallIntoAConfigurationFolderReachedThroughALink() throws {
        defer { try? files.removeItem(at: scratch) }
        let (link, real) = try linkedConfiguration()
        let packages = WidgetPackageStore(directory: link.appending(path: "packages"))
        let installed = try packages.install(repository.appending(path: "examples/packages/local-clock"))
        #expect(installed.manifest.id == "local-clock")
        #expect(files.fileExists(atPath: real.appending(path: "packages/local-clock/1.0.0/package.json").path))
        #expect(try packages.list().map(\.id) == ["local-clock"])
    }

    @Test func pathsThatDoNotExistYetStayInsideTheirLinkedFolder() throws {
        defer { try? files.removeItem(at: scratch) }
        let (link, _) = try linkedConfiguration()
        let packages = link.appending(path: "packages")
        try files.createDirectory(at: packages, withIntermediateDirectories: true)
        #expect(throws: Never.self) { try validatePackagePath(packages.appending(path: "clock/1.0.0"), inside: packages) }
        #expect(throws: WidgetPackageError.self) { try validatePackagePath(packages.appending(path: "../outside"), inside: packages) }
    }

    @Test func aNewVersionUnderALinkThatLeavesThePackagesFolderIsRefused() throws {
        defer { try? files.removeItem(at: scratch) }
        let packages = scratch.appending(path: "packages")
        let outside = scratch.appending(path: "outside")
        try files.createDirectory(at: packages, withIntermediateDirectories: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: packages.appending(path: "clock"), withDestinationURL: outside)
        #expect(throws: WidgetPackageError.self) { try WidgetPackageStore(directory: packages).directory(id: "clock", version: "1.0.0") }
    }
}
