import Foundation

/// A `stablebar://package/<id>` link: what someone sends to point to one package in the Store or a private source.
/// Opening one only shows the package in Settings › Store; adding it still takes the usual review.
struct PackageLink: Equatable, Sendable {
    var id: String
    /// The source that lists the package; nil for the Store, or the first source that lists it.
    var sourceID: String?

    init(id: String, sourceID: String?) {
        self.id = id
        self.sourceID = sourceID
    }

    /// Nil unless the link is `stablebar://package/<id>` with a valid package id, and a valid source id when it has one.
    /// Every other query item is ignored.
    init?(url link: URL) {
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "stablebar", components.host?.lowercased() == "package" else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.count == 1, (try? validatePackageComponent(path[0])) != nil else { return nil }
        let sourceID = components.queryItems?.first { $0.name == "source" }.map { $0.value ?? "" }
        if let sourceID {
            guard (try? validatePackageComponent(sourceID)) != nil, sourceID != PackageSource.localID else { return nil }
        }
        self.init(id: path[0], sourceID: sourceID)
    }

    /// `stablebar://package/<id>`, with `?source=<id>` when it names a source.
    var link: URL {
        var components = URLComponents()
        components.scheme = "stablebar"
        components.host = "package"
        components.path = "/" + id
        if let sourceID { components.queryItems = [URLQueryItem(name: "source", value: sourceID)] }
        return components.url!
    }
}
