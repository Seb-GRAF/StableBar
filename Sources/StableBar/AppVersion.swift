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

    /// The development build the docs images and scenes show, whichever commit draws them.
    static let sample = AppVersion(version: "0.0.0-dev", build: nil, development: true)

    var channel: Channel {
        guard !development, let version else { return .development }
        let release = version.prefix { $0 != "+" }
        guard let separator = release.firstIndex(of: "-") else { return .stable }
        let prerelease = release[release.index(after: separator)...]
        return prerelease == "beta" || prerelease.hasPrefix("beta.") ? .beta : .prerelease
    }

    /// The release that stamps the configuration files it saves and reads newer ones leniently. Development
    /// builds and tests have none: their version names the last stable release, not what they can read.
    static let release: String? = {
        let app = AppVersion()
        return Bundle.main.bundleIdentifier == "org.stablebar.app" && app.channel != .development ? app.version : nil
    }()
}

/// Orders release versions as Semantic Versioning does: a beta comes before its release, and build metadata is ignored.
func compareReleases(_ first: String, _ second: String) -> ComparisonResult {
    func parts(_ version: String) -> (core: [Int], prerelease: [Substring]?) {
        let release = version.prefix { $0 != "+" }
        let separator = release.firstIndex(of: "-")
        let core = release[..<(separator ?? release.endIndex)].split(separator: ".").map { Int($0) ?? 0 }
        return (core, separator.map { release[release.index(after: $0)...].split(separator: ".") })
    }
    let (first, second) = (parts(first), parts(second))
    for index in 0..<max(first.core.count, second.core.count) {
        let (a, b) = (index < first.core.count ? first.core[index] : 0, index < second.core.count ? second.core[index] : 0)
        if a != b { return a < b ? .orderedAscending : .orderedDescending }
    }
    switch (first.prerelease, second.prerelease) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case let (a?, b?):
        for (x, y) in zip(a, b) where x != y {
            if let x = Int(x), let y = Int(y) { return x < y ? .orderedAscending : .orderedDescending }
            return x.compare(y, options: .numeric)
        }
        return a.count == b.count ? .orderedSame : a.count < b.count ? .orderedAscending : .orderedDescending
    }
}
