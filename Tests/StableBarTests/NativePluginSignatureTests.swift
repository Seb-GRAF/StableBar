import Foundation
import Testing
@testable import StableBar

private struct NativePluginSignatureFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "native-plugin-signature-\(UUID().uuidString)", directoryHint: .isDirectory)
    var bundle: URL { directory.appending(path: "Example.bundle", directoryHint: .isDirectory) }
    var executable: URL { bundle.appending(path: "Contents/MacOS/Example") }

    func createUnsignedBundle() throws {
        let macOS = executable.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.example.NativePlugin",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "BNDL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        let source = directory.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try run("/usr/bin/clang", ["-x", "c", source.path, "-o", executable.path])
    }

    func signAdHoc() throws {
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", bundle.path])
    }

    func close() { try? FileManager.default.removeItem(at: directory) }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "NativePluginSignatureFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: output])
        }
    }
}

@Test func nativePluginSignatureRejectsUnsignedBundles() throws {
    let fixture = NativePluginSignatureFixture()
    defer { fixture.close() }
    try fixture.createUnsignedBundle()

    let error = #expect(throws: NativePluginSignatureError.self) {
        try NativePluginSignature.verify(at: fixture.bundle)
    }
    #expect(error == .invalidSignature)
}

@Test func nativePluginSignatureRejectsAdHocSignedBundles() throws {
    let fixture = NativePluginSignatureFixture()
    defer { fixture.close() }
    try fixture.createUnsignedBundle()
    try fixture.signAdHoc()

    let error = #expect(throws: NativePluginSignatureError.self) {
        try NativePluginSignature.verify(at: fixture.bundle)
    }
    #expect(error == .unsignedOrAdHoc)
}

@Test func nativePluginSignatureRejectsTamperedBundles() throws {
    let fixture = NativePluginSignatureFixture()
    defer { fixture.close() }
    try fixture.createUnsignedBundle()
    try fixture.signAdHoc()
    try Data("tampered".utf8).write(to: fixture.executable)

    let error = #expect(throws: NativePluginSignatureError.self) {
        try NativePluginSignature.verify(at: fixture.bundle)
    }
    #expect(error == .invalidSignature)
}
