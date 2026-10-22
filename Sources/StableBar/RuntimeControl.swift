import Foundation
import CryptoKit

struct RuntimeRequest: Codable {
    enum Action: String, Codable { case query, batch, reset, refresh, popup, trigger, reload, customize, uninstallPackage }
    let action: Action
    var id: String?
    var version: String?
    var edits: [ConfigurationEdit]?
    var persist = false
    var environment: [String: String]?
}

struct RuntimeResponse: Codable {
    var result: ConfigurationValue?
    var error: String?
}

@MainActor
final class RuntimeControl {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    let handle: (RuntimeRequest) throws -> ConfigurationValue

    init(handle: @escaping (RuntimeRequest) throws -> ConfigurationValue) { self.handle = handle }

    func start(url: URL) throws {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, Self.name(url) as CFString, { _, _, data, info in
            let input = data! as Data
            let output = MainActor.assumeIsolated {
                let control = Unmanaged<RuntimeControl>.fromOpaque(info!).takeUnretainedValue()
                let response: RuntimeResponse
                do {
                    let request = try JSONDecoder().decode(RuntimeRequest.self, from: input)
                    response = RuntimeResponse(result: try control.handle(request))
                } catch {
                    response = RuntimeResponse(error: errorMessage(error))
                }
                return try! JSONEncoder().encode(response)
            }
            return Unmanaged.passRetained(output as CFData)
        }, &context, nil)
        guard let port else { throw CommandFailure(message: "Another StableBar instance already controls this configuration.") }
        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
    }

    static func send(_ request: RuntimeRequest, url: URL) throws -> ConfigurationValue {
        guard let remote = CFMessagePortCreateRemote(nil, name(url) as CFString) else {
            throw CommandFailure(message: "StableBar is not running with configuration \(url.path).")
        }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 1, try JSONEncoder().encode(request) as CFData,
                                             5, 10, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let reply else {
            throw CommandFailure(message: "StableBar control request failed (\(status)).")
        }
        let response = try JSONDecoder().decode(RuntimeResponse.self, from: reply.takeRetainedValue() as Data)
        if let error = response.error { throw CommandFailure(message: error) }
        return response.result!
    }

    private static func name(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "com.stablebar.control.\(getuid()).\(hash)"
    }
}
