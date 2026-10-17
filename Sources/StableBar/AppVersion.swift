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

    init(bundle: Bundle = .main) {
        self.init(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    init(version: String?, build: String?) {
        self.version = version.flatMap { $0.isEmpty ? nil : $0 }
        self.build = build.flatMap { $0.isEmpty ? nil : $0 }
    }

    var channel: Channel {
        guard let version else { return .development }
        let release = version.prefix { $0 != "+" }
        guard let separator = release.firstIndex(of: "-") else { return .stable }
        let prerelease = release[release.index(after: separator)...]
        return prerelease == "beta" || prerelease.hasPrefix("beta.") ? .beta : .prerelease
    }
}
