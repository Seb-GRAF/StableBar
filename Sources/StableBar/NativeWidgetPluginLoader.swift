import AppKit
import Darwin
import Foundation
import NativeWidgetPluginABI
import CoreFoundation

@MainActor
struct NativeWidgetPluginLoader {
    nonisolated static let supportedAPIMajor = 1

    let trustStore: NativePluginTrustStore
    var signatureVerifier: (URL) throws -> NativePluginSignature = NativePluginSignature.verify
    var bundleLoader: (Bundle) throws -> Void = { try $0.loadAndReturnError() }
    var principalClassResolver: (Bundle) -> NSObject.Type? = { $0.principalClass as? NSObject.Type }

    func load(at url: URL, expectedPluginID: String, expectedVersion: String) throws -> NativeWidgetPluginInstance {
        let stagingDirectory: NativeWidgetPluginStagingDirectory
        do {
            stagingDirectory = try NativeWidgetPluginStagingDirectory(copying: url)
        } catch {
            throw NativeWidgetPluginLoaderError.stagingFailed(error.localizedDescription)
        }
        let stagedURL = stagingDirectory.bundleURL
        let metadata = try NativeWidgetPluginMetadata.read(at: stagedURL)
        guard metadata.bundleID == expectedPluginID else {
            throw NativeWidgetPluginLoaderError.pluginIDMismatch
        }
        guard metadata.version == expectedVersion else {
            throw NativeWidgetPluginLoaderError.versionMismatch
        }
        guard metadata.apiMajor == Self.supportedAPIMajor else {
            throw NativeWidgetPluginLoaderError.unsupportedAPI(metadata.apiMajor)
        }

        let signature = try signatureVerifier(stagedURL)
        guard signature.identifier == metadata.bundleID else {
            throw NativeWidgetPluginLoaderError.signatureIdentifierMismatch
        }
        guard try trustStore.isTrusted(pluginID: expectedPluginID, bundleID: metadata.bundleID,
                                       version: expectedVersion, signature: signature) else {
            throw NativeWidgetPluginLoaderError.notTrusted
        }

        guard let bundle = Bundle(url: stagedURL) else { throw NativeWidgetPluginLoaderError.invalidBundle }
        // Keep the staged files before asking Bundle to load. Initializers can run before a load error returns.
        NativeWidgetPluginStagingRegistry.shared.retain(stagingDirectory)
        do { try bundleLoader(bundle) }
        catch { throw NativeWidgetPluginLoaderError.codeLoadFailed(error.localizedDescription) }
        guard let principalClass = principalClassResolver(bundle) else {
            throw NativeWidgetPluginLoaderError.missingPrincipalClass
        }
        guard let plugin = principalClass.init() as? any StableBarNativeWidgetPlugin else {
            throw NativeWidgetPluginLoaderError.incompatiblePrincipalClass
        }
        guard plugin.apiVersion == metadata.apiMajor else {
            throw NativeWidgetPluginLoaderError.pluginAPIMismatch(plugin.apiVersion)
        }
        return NativeWidgetPluginInstance(bundle: bundle, plugin: plugin)
    }
}

final class NativeWidgetPluginStagingDirectory {
    let directoryURL: URL
    let bundleURL: URL

    init(copying source: URL) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "StableBarNativePlugin-\(UUID().uuidString)", directoryHint: .isDirectory)
        bundleURL = directoryURL.appending(path: source.lastPathComponent, directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            try FileManager.default.copyItem(at: source, to: bundleURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class NativeWidgetPluginStagingRegistry: @unchecked Sendable {
    static let shared = NativeWidgetPluginStagingRegistry()

    private let lock = NSLock()
    private var directories: [NativeWidgetPluginStagingDirectory] = []

    private init() {
        atexit { NativeWidgetPluginStagingRegistry.shared.clear() }
    }

    func retain(_ directory: NativeWidgetPluginStagingDirectory) {
        lock.lock()
        directories.append(directory)
        lock.unlock()
    }

    private func clear() {
        lock.lock()
        let retained = directories
        directories.removeAll()
        lock.unlock()
        for directory in retained { try? FileManager.default.removeItem(at: directory.directoryURL) }
    }
}

@MainActor
final class NativeWidgetPluginInstance {
    let bundle: Bundle
    private let plugin: any StableBarNativeWidgetPlugin
    private let stagingDirectory: NativeWidgetPluginStagingDirectory?
    private(set) var isStarted = false

    init(bundle: Bundle, plugin: any StableBarNativeWidgetPlugin) {
        self.bundle = bundle
        self.plugin = plugin
        stagingDirectory = nil
    }

    fileprivate init(bundle: Bundle, plugin: any StableBarNativeWidgetPlugin,
                     stagingDirectory: NativeWidgetPluginStagingDirectory) {
        self.bundle = bundle
        self.plugin = plugin
        self.stagingDirectory = stagingDirectory
    }

    func start(host: any StableBarNativeWidgetHost, settings: [String: Any]) {
        guard !isStarted else { return }
        isStarted = true
        plugin.configure?(with: host, settings: settings)
        plugin.start()
    }

    func makeWidgetView() -> NSView { plugin.makeWidgetView() }

    func makePopupView() -> NSView { plugin.makePopupView() }

    func settingsDidChange(_ settings: [String: Any]) {
        plugin.settingsDidChange?(settings)
    }

    func sendEvent(name: String, payload: [String: Any]) {
        plugin.stableBarDidReceiveEvent?(name, payload: payload)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        plugin.stop()
    }
}

struct NativeWidgetPluginMetadata {
    let bundleID: String
    let version: String
    let apiMajor: Int

    static func read(at url: URL) throws -> Self {
        guard url.pathExtension == "bundle",
              let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "BNDL",
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable == URL(filePath: executable).lastPathComponent,
              let principalClass = info["NSPrincipalClass"] as? String, !principalClass.isEmpty,
              let api = info["StableBarNativeWidgetPluginAPIMajor"] as? NSNumber,
              CFGetTypeID(api) != CFBooleanGetTypeID(),
              api.doubleValue.isFinite,
              api.doubleValue == Double(api.intValue) else {
            throw NativeWidgetPluginLoaderError.invalidMetadata
        }
        return Self(bundleID: bundleID, version: version, apiMajor: api.intValue)
    }
}

enum NativeWidgetPluginLoaderError: LocalizedError, Equatable {
    case invalidMetadata
    case stagingFailed(String)
    case pluginIDMismatch
    case versionMismatch
    case unsupportedAPI(Int)
    case signatureIdentifierMismatch
    case notTrusted
    case invalidBundle
    case codeLoadFailed(String)
    case missingPrincipalClass
    case incompatiblePrincipalClass
    case pluginAPIMismatch(Int)

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "The native plugin metadata is missing or invalid."
        case let .stagingFailed(reason): "The native plugin bundle could not be staged: \(reason)"
        case .pluginIDMismatch: "The native plugin bundle ID does not match the package ID."
        case .versionMismatch: "The native plugin bundle version does not match the package version."
        case let .unsupportedAPI(version): "The native plugin requires unsupported API major version \(version)."
        case .signatureIdentifierMismatch: "The native plugin signature does not match its bundle ID."
        case .notTrusted: "This native plugin version has not been explicitly trusted."
        case .invalidBundle: "The native plugin bundle could not be opened."
        case let .codeLoadFailed(reason): "The native plugin could not be loaded: \(reason)"
        case .missingPrincipalClass: "The native plugin principal class is missing."
        case .incompatiblePrincipalClass: "The native plugin principal class does not implement the StableBar plugin API."
        case let .pluginAPIMismatch(version): "The native plugin reports unsupported API major version \(version)."
        }
    }
}
