import Foundation
import Security

struct NativePluginSignature: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
    let cdhash: String

    static func verify(at bundle: URL) throws -> Self {
        guard bundle.pathExtension == "bundle",
              (try? bundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw NativePluginSignatureError.notBundle
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw NativePluginSignatureError.invalidBundle
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw NativePluginSignatureError.invalidSignature
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              let cdhash = information[kSecCodeInfoUnique as String] as? Data,
              information[kSecCodeInfoCMS as String] != nil,
              !identifier.isEmpty, !teamIdentifier.isEmpty, !cdhash.isEmpty else {
            throw NativePluginSignatureError.unsignedOrAdHoc
        }

        return Self(identifier: identifier, teamIdentifier: teamIdentifier,
                    cdhash: cdhash.map { String(format: "%02x", $0) }.joined())
    }
}

enum NativePluginSignatureError: LocalizedError, Equatable {
    case notBundle
    case invalidBundle
    case invalidSignature
    case unsignedOrAdHoc

    var errorDescription: String? {
        switch self {
        case .notBundle: "The native plugin is not a bundle."
        case .invalidBundle: "The native plugin bundle could not be read."
        case .invalidSignature: "The native plugin signature is invalid."
        case .unsignedOrAdHoc: "The native plugin needs a non-ad-hoc code signature with a Team ID."
        }
    }
}
