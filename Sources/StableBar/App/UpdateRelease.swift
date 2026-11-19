import Foundation

struct UpdateRelease: Decodable, Sendable {
    let tagName: String
    let body: String?
    let publishedAt: Date

    static func load(after installedVersion: String, through offeredVersion: String,
                     fetch: (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }) async throws -> [UpdateRelease] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        var releases: [UpdateRelease] = []
        var page = 1
        while true {
            let url = URL(string: "https://api.github.com/repos/Seb-GRAF/StableBar/releases?per_page=100&page=\(page)")!
            let batch = try decoder.decode([UpdateRelease].self, from: await fetch(url))
            releases.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        guard let installed = releases.first(where: { $0.tagName == "v\(installedVersion)" }),
              let offered = releases.first(where: { $0.tagName == "v\(offeredVersion)" }) else {
            throw URLError(.resourceUnavailable)
        }
        return releases.filter {
            $0.tagName.hasPrefix("v") && $0.publishedAt > installed.publishedAt && $0.publishedAt <= offered.publishedAt
        }.sorted { $0.publishedAt > $1.publishedAt }
    }
}
