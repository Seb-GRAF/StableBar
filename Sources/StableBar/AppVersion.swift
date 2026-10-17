import Foundation

struct AppVersion {
    enum Channel: String {
        case stable = "Stable"
        case beta = "Beta"
        case prerelease = "Pre-release"
        case development = "Development"
    }

    let version: String?
    let build: String?
    private let development: Bool

    init(bundle: Bundle = .main) {
        let development = bundle.object(forInfoDictionaryKey: "StableBarDevelopmentBuild") as? Bool == true
        let release = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let revision = bundle.object(forInfoDictionaryKey: "StableBarSourceRevision") as? String
        self.init(version: development ? revision : release,
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  development: development)
    }

    init(version: String?, build: String?, development: Bool = false) {
        self.version = version.flatMap { $0.isEmpty ? nil : $0 }
        self.build = development ? nil : build.flatMap { $0.isEmpty ? nil : $0 }
        self.development = development
    }

    var channel: Channel {
        guard !development, let version else { return .development }
        let release = version.prefix { $0 != "+" }
        guard let separator = release.firstIndex(of: "-") else { return .stable }
        let prerelease = release[release.index(after: separator)...]
        return prerelease == "beta" || prerelease.hasPrefix("beta.") ? .beta : .prerelease
    }
}
