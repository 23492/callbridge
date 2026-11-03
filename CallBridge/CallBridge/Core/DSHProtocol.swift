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

/// Maps one HTTP answer (or a transport error, status nil) to an outcome. Inputs are
/// plain values so the rules run without URLSession.
func classifyDSHResponse(status: Int?, contentType: String?, location: String?, wwwAuthenticate: String?, body: Data?) -> DSHOutcome {
    guard let status = status else { return .retryable("onbekend antwoord") }
    let isJSON = (contentType ?? "").lowercased().split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces) == "application/json"
    if (200...299).contains(status), isJSON, let body = body,
       let head = try? JSONDecoder().decode(EnvelopeHead.self, from: body), head.ok {
        return .success(body)
    }
    return .retryable("onbekend antwoord")
}

/// Only `ok` and `error` of an envelope, so the head can be read whatever `data` holds.
private struct EnvelopeHead: Decodable {
    let ok: Bool
    let error: CockpitError?
}
