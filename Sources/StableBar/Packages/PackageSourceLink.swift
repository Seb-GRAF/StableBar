import Foundation

/// A `stablebar://add-source` link: what a team sends so a member can join a private package source.
/// It carries a name, an index URL and optionally an id, never a token. Opening one only fills in the Add source form.
struct PackageSourceLink: Equatable, Sendable {
    var id: String?
    var name: String
    var url: URL

    init(id: String?, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

    /// Nil unless the link is `stablebar://add-source` with a valid name and https index URL, and a valid id when it has one.
    /// Every other query item, including `token`, is ignored.
    init?(url link: URL) {
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "stablebar", components.host?.lowercased() == "add-source" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let name = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let text = value("url")?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text) else { return nil }
        let id = value("id")
        guard (try? PackageSource.validated(id: id ?? "source", name: name, url: url)) != nil else { return nil }
        self.init(id: id, name: name, url: url)
    }

    init(source: PackageSource) {
        self.init(id: source.id, name: source.name, url: source.url)
    }

    /// `stablebar://add-source?name=…&url=…&id=…`
    var link: URL {
        var components = URLComponents()
        components.scheme = "stablebar"
        components.host = "add-source"
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "url", value: url.absoluteString)]
            + (id.map { [URLQueryItem(name: "id", value: $0)] } ?? [])
        return components.url!
    }
}
