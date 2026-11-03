import Foundation

// MARK: - DSH Client

/// Refuses every redirect, so the Authorization and cf-access-token headers never
/// follow a 302 to cloudflareaccess.com (T-03-08). The 3xx itself reaches
/// classifyDSHResponse, which reads it as "Access missing".
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Foundation-only HTTP client for the cockpit's `callbridge/v1` routes and their
/// `test/` twins (D-01). Every answer becomes a DSHOutcome through classifyDSHResponse.
/// Completions run off the main queue; callers hop to main themselves.
final class DSHClient {
    private let cloudflared: Cloudflared
    private let apiBase: String
    private let session: URLSession

    init(cloudflared: Cloudflared, apiBase: String = dshAPIBase) {
        self.cloudflared = cloudflared
        self.apiBase = apiBase
        // One ephemeral session: no cookies sent or stored, no URL cache (D-03). Long
        // timeouts because a two-hour call is close to 95 MB on a slow uplink (D-02).
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: - Routes

    /// GET test/echo: which credentials and headers reached the cockpit (D-26).
    func echo(clientToken: String, completion: @escaping (DSHOutcome) -> Void) {
        perform(.echo, test: true, method: "GET", clientToken: clientToken,
                configure: { _ in },
                send: { request, handler in self.session.dataTask(with: request, completionHandler: handler) },
                completion: completion)
    }

    // MARK: - Request Path

    /// The one request path: Access token, headers, send, classify. The URL is
    /// apiBase + dshRoutePath with no query string; no Origin and no Cookie header is
    /// ever set (D-03). The Bearer header is set only when a client token is given.
    private func perform(_ route: DSHRoute, test: Bool, method: String, clientToken: String?,
                         configure: @escaping (inout URLRequest) -> Void,
                         send: @escaping (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionTask,
                         completion: @escaping (DSHOutcome) -> Void) {
        let name = DSHClient.routeName(route)
        cloudflared.accessToken { result in
            if let early = dshOutcome(for: result) {
                if early == .accessMissing { self.cloudflared.invalidate() }
                debugLog("DSHClient: \(name) -> no request, \(DSHClient.caseName(early))")
                completion(early)
                return
            }
            guard case .token(let accessToken) = result,
                  let url = URL(string: self.apiBase + dshRoutePath(route, test: test)) else {
                completion(.rejected(code: "bad_request", message: "Ongeldig DSH-adres"))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            request.setValue(accessToken, forHTTPHeaderField: "cf-access-token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let clientToken = clientToken {
                request.setValue("Bearer " + clientToken, forHTTPHeaderField: "Authorization")
            }
            configure(&request)

            let task = send(request) { data, response, error in
                let http = response as? HTTPURLResponse
                // A transport error (also mid-body) is "not reachable", whatever arrived.
                let status: Int? = error == nil ? http?.statusCode : nil
                let outcome = classifyDSHResponse(
                    status: status,
                    contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                    location: http?.value(forHTTPHeaderField: "Location"),
                    wwwAuthenticate: http?.value(forHTTPHeaderField: "WWW-Authenticate"),
                    body: data)
                if outcome == .accessMissing { self.cloudflared.invalidate() }
                debugLog("DSHClient: \(name) -> HTTP \(status.map(String.init) ?? "none") \(DSHClient.caseName(outcome))")
                completion(outcome)
            }
            task.resume()
        }
    }

    // MARK: - Log Names

    /// Route name for log lines; a client_ref is a session UUID, not a secret.
    private static func routeName(_ route: DSHRoute) -> String {
        switch route {
        case .pair: return "pair"
        case .health: return "health"
        case .echo: return "echo"
        case .upload: return "upload"
        case .call(let ref): return "call \(ref)"
        case .retry(let ref): return "retry \(ref)"
        }
    }

    /// Outcome case name for log lines; never the body.
    static func caseName(_ outcome: DSHOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .accessMissing: return "accessMissing"
        case .unauthorized: return "unauthorized"
        case .switchOff: return "switchOff"
        case .retryable: return "retryable"
        case .rejected(let code, _): return "rejected(\(code))"
        case .notFound: return "notFound"
        case .conflict: return "conflict"
        case .cloudflaredMissing: return "cloudflaredMissing"
        }
    }
}
