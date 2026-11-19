import Foundation

/// Scheme, host and effective port decide whether two URLs share an origin.
func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    func origin(_ url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        guard let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) else { return nil }
        return (scheme, host, port)
    }
    guard let a = origin(a), let b = origin(b) else { return false }
    return a == b
}

/// A request for `url` that carries the source's token only when `url` is on the source's own origin.
func sourceRequest(for url: URL, source: PackageSource, token: String?) -> URLRequest {
    var request = URLRequest(url: url)
    guard let token, !token.isEmpty, sameOrigin(url, source.url) else { return request }
    if url.path.hasPrefix("/api/v4/") {
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
    } else {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
}

/// The request to follow after a redirect: the token headers stay only on the origin the request started on.
func redirectRequest(_ request: URLRequest, from original: URL?) -> URLRequest {
    var request = request
    if let original, let target = request.url, sameOrigin(original, target) { return request }
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(nil, forHTTPHeaderField: "PRIVATE-TOKEN")
    return request
}

final class SourceRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// The only hosts a redirect may reach, or nil for any.
    let hosts: [String]?

    init(hosts: [String]? = nil) {
        self.hosts = hosts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let hosts, !hosts.contains(where: { $0 == request.url?.host() }) { return completionHandler(nil) }
        completionHandler(redirectRequest(request, from: task.originalRequest?.url))
    }
}

extension URLSession {
    /// The session for requests that may carry a source token. Ephemeral and uncached, so no request,
    /// with its token header, is written to the disk cache, cookies or credentials that package commands could read.
    static let packageSources: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: SourceRedirectGuard(), delegateQueue: nil)
    }()
}

/// Defaults to the redirect-guarded session, so a token can't follow a redirect to another origin.
func fetch(_ request: URLRequest, session: URLSession = .packageSources) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    if let response = response as? HTTPURLResponse, response.statusCode != 200 {
        throw WidgetPackageError.downloadFailed(request.url?.absoluteString ?? "", response.statusCode)
    }
    return data
}
