import Foundation

// MARK: - Cockpit Protocol

/// The `error` object of the cockpit envelope. `message` is a fixed Dutch line that
/// CallBridge may show as is (D-14).
struct CockpitError: Decodable {
    let code: String
    let message: String?
}

/// The call record view of `POST calls` and `GET calls/<client_ref>`. Property names
/// equal the cockpit's camelCase JSON keys; contact and account are not decoded.
struct CockpitCall: Decodable, Equatable {
    let id: String?
    let clientRef: String?
    let status: String
    let step: String?
    let taskId: String?
    let noteId: String?
    let actionTaskIds: [String]?
    let error: String?
    let retry: Bool?
    let duplicateOf: String?
    let test: Bool?
}

/// The one-time answer of `POST pair`: the client token goes to the Keychain.
struct CockpitPairAnswer: Decodable {
    let token: String
    let clientId: String?
}

/// `GET health`: `switch` is "live" or "off", `access` "ok", "missing" or "refused".
struct CockpitHealth: Decodable {
    let version: String?
    let access: String?
    let `switch`: String?
    let test: Bool?
}

/// `GET test/echo`: which credentials and headers reached the cockpit.
struct CockpitEcho: Decodable {
    let hasOrigin: Bool
    let hasCookie: Bool
    let hasBearer: Bool
    let hasAccessToken: Bool
    let test: Bool?
}

/// The cockpit envelope `{ ok, data | error, at }` (plus `test` on the test routes).
struct CockpitEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: CockpitError?
    let test: Bool?
}

/// The `data` of an envelope with `ok: true`, or nil for anything else.
func decodeCockpitData<T: Decodable>(_ type: T.Type, from body: Data) -> T? {
    guard let env = try? JSONDecoder().decode(CockpitEnvelope<T>.self, from: body), env.ok else { return nil }
    return env.data
}

// MARK: - Response Outcome

enum DSHOutcome: Equatable {
    /// A 2xx JSON envelope with ok true; the raw body for the typed decode.
    case success(Data)
    /// Cloudflare Access let the request through without a valid sign-in: pause, "Log in bij DSH".
    case accessMissing
    /// The client token was revoked or is unknown: pause, "Koppel opnieuw".
    case unauthorized
    /// Switch `callbridge` is off in the cockpit: keep the recording, use the local pipeline.
    case switchOff
    /// Network trouble or a 5xx: try again later with the same client_ref.
    case retryable(String)
    /// The cockpit refused this request; the message is shown as is.
    case rejected(code: String, message: String)
    /// The client_ref is unknown to the cockpit.
    case notFound
    /// The request does not fit the record's state (retry on a record that did not fail).
    case conflict
    /// The cloudflared binary is not installed: no request was sent.
    case cloudflaredMissing
}

/// Shown for a Cloudflare HTML 413: the edge refused the body before the cockpit saw it.
let dshTooLargeMessage = "Opname is te groot voor DSH (max 95 MB). Zet 'Transcriberen via DSH' uit en probeer opnieuw."

/// Maps one HTTP answer (or a transport error, status nil) to an outcome. Inputs are
/// plain values so the rules run without URLSession. The order matters: 413 and 5xx
/// come before the HTML rule, so a Cloudflare error page never reads as a missing
/// sign-in and a recording is never parked behind a useless "Log in bij DSH".
func classifyDSHResponse(status: Int?, contentType: String?, location: String?, wwwAuthenticate: String?, body: Data?) -> DSHOutcome {
    guard let status = status else { return .retryable("DSH niet bereikbaar") }
    let isJSON = (contentType ?? "").lowercased().split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces) == "application/json"
    let head = body.flatMap { try? JSONDecoder().decode(EnvelopeHead.self, from: $0) }

    // 1. Too large: the cockpit's own message when it answered, else the edge page.
    if status == 413 {
        if isJSON, let error = head?.error {
            return .rejected(code: error.code, message: error.message ?? "Fout van DSH (\(error.code))")
        }
        return .rejected(code: "too_large", message: dshTooLargeMessage)
    }
    // 2. Redirects are refused by the client (D-03). Access sends a 302 to
    //    https://<team>.cloudflareaccess.com/cdn-cgi/access/login/...; this host sends
    //    no other redirect, so every 3xx means Access missing whatever `location` says.
    if (300...399).contains(status) {
        return .accessMissing
    }
    // 3. Access challenge, whatever the status.
    if let auth = wwwAuthenticate, auth.hasPrefix("Cloudflare-Access") {
        return .accessMissing
    }
    // 4. Server trouble without a cockpit answer (Cloudflare 502, 520-524 pages).
    if (500...599).contains(status), !isJSON {
        return .retryable("DSH antwoordt met \(status)")
    }
    // 5. Any other non-JSON answer is the Access login page or similar (D-03).
    if !isJSON {
        return .accessMissing
    }
    // 6. The cockpit envelope.
    guard let envelope = head else { return dshBadResponse }
    if (200...299).contains(status) {
        guard envelope.ok, let body = body else { return dshBadResponse }
        return .success(body)
    }
    guard let error = envelope.error else {
        return (500...599).contains(status) ? .retryable("DSH antwoordt met \(status)") : dshBadResponse
    }
    let message = error.message ?? "Fout van DSH (\(error.code))"
    switch status {
    case 503 where error.code == "switch_off":
        return .switchOff
    case 500...599:
        return .retryable(message)
    case 401 where error.code == "unauthorized":
        return .unauthorized
    case 404:
        return .notFound
    case 409:
        return .conflict
    case 400...499:
        return .rejected(code: error.code, message: message)
    default:
        return dshBadResponse
    }
}

/// A JSON answer that does not fit the envelope; the recording stays.
private let dshBadResponse = DSHOutcome.rejected(code: "bad_response", message: "Onverwacht antwoord van DSH")

// MARK: - Routes

/// The Cloudflare Access application; `cloudflared access token -app=` takes this URL.
/// dsh2 has a separate Access application for the CallBridge API path (aud 1576035d...),
/// apart from the one on the site root. A token for the root URL is answered with a 302
/// on these routes, so the token must be fetched for a URL under the API path.
let dshAccessApp = "https://dsh2.knoppsmart.com/cockpit/api/callbridge/v1/health"
/// Base of every CallBridge route; paths from dshRoutePath are relative to it.
let dshAPIBase = "https://dsh2.knoppsmart.com/cockpit/api/callbridge/v1/"

enum DSHRoute: Equatable {
    case pair, health, echo, upload, call(String), retry(String)
}

/// Path below dshAPIBase. Pair has no test route; echo exists only under test/ (D-26).
func dshRoutePath(_ route: DSHRoute, test: Bool) -> String {
    let prefix = test ? "test/" : ""
    switch route {
    case .pair: return "pair"
    case .echo: return "test/echo"
    case .health: return prefix + "health"
    case .upload: return prefix + "calls"
    case .call(let ref): return prefix + "calls/\(ref)"
    case .retry(let ref): return prefix + "calls/\(ref)/retry"
    }
}

/// Only `ok` and `error` of an envelope, so the head can be read whatever `data` holds.
private struct EnvelopeHead: Decodable {
    let ok: Bool
    let error: CockpitError?
}
