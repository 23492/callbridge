// Assertions for the response classifier and routes in CallBridge/CallBridge/Core/DSHProtocol.swift.
// Run via scripts/test-core.sh.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let json = "application/json; charset=utf-8"
let html = "text/html; charset=UTF-8"
func env(_ code: String, _ message: String? = nil) -> Data {
    let msg = message.map { ",\"message\":\"\($0)\"" } ?? ""
    return Data("{\"ok\":false,\"error\":{\"code\":\"\(code)\"\(msg)},\"at\":\"2026-11-03T10:00:00.000Z\"}".utf8)
}
func classify(_ status: Int?, _ type: String?, location: String? = nil, auth: String? = nil, body: Data? = nil) -> DSHOutcome {
    return classifyDSHResponse(status: status, contentType: type, location: location, wwwAuthenticate: auth, body: body)
}
func isRetryable(_ o: DSHOutcome) -> Bool { if case .retryable = o { return true }; return false }
let page = Data("<html><body>Cloudflare</body></html>".utf8)

// Transport error
check(isRetryable(classify(nil, nil)), "status nil -> retryable")

// 413 before the HTML rule (Cloudflare edge page)
if case .rejected(let code, let message) = classify(413, html, body: page) {
    check(code == "too_large", "413 HTML -> rejected too_large")
    check(message.contains("95 MB"), "413 HTML -> local Dutch message names 95 MB")
} else {
    check(false, "413 HTML -> rejected too_large"); check(false, "413 HTML -> local Dutch message names 95 MB")
}
let tooLarge = "Dit bestand is te groot (95,0 MB). Het maximum is 95,0 MB."
check(classify(413, json, body: env("too_large", tooLarge)) == .rejected(code: "too_large", message: tooLarge), "413 JSON -> rejected with the cockpit message")

// Access missing
check(classify(302, nil, location: "https://knoppsmart.cloudflareaccess.com/cdn-cgi/access/login/dsh2.knoppsmart.com?kid=abc") == .accessMissing, "302 to Access login -> accessMissing")
check(classify(307, nil, location: "https://example.com/elsewhere") == .accessMissing, "other 3xx -> accessMissing")
check(classify(401, html, auth: "Cloudflare-Access resource_metadata=\"https://dsh2.knoppsmart.com/.well-known\"", body: page) == .accessMissing, "401 HTML with Cloudflare-Access www-authenticate -> accessMissing")
check(classify(200, html, body: page) == .accessMissing, "200 HTML -> accessMissing")
check(classify(400, "text/plain", body: Data("nope".utf8)) == .accessMissing, "4xx non-JSON -> accessMissing")

// 5xx is retryable, HTML or JSON
check(isRetryable(classify(502, html, body: page)), "502 HTML -> retryable")
check(isRetryable(classify(503, html, body: page)), "503 HTML -> retryable")
check(isRetryable(classify(520, html, body: page)), "520 HTML -> retryable")
check(isRetryable(classify(524, html, body: page)), "524 HTML -> retryable")
check(isRetryable(classify(500, json, body: env("internal"))), "500 JSON -> retryable")
check(isRetryable(classify(503, json, body: env("salesforce", "Salesforce is niet bereikbaar."))), "503 salesforce -> retryable")
check(classify(503, json, body: env("switch_off")) == .switchOff, "503 switch_off -> switchOff")

// Cockpit JSON errors
check(classify(401, json, body: env("unauthorized")) == .unauthorized, "401 unauthorized -> unauthorized")
check(classify(404, json, body: env("not_found")) == .notFound, "404 -> notFound")
check(classify(409, json, body: env("conflict")) == .conflict, "409 -> conflict")
check(classify(400, json, body: env("bad_request", "Ongeldig verzoek.")) == .rejected(code: "bad_request", message: "Ongeldig verzoek."), "400 -> rejected with cockpit message")
let badType = "Dit bestandstype wordt niet ondersteund. Kies .m4a, .mp3, .wav, .mp4, .mov of .webm."
check(classify(415, json, body: env("bad_type", badType)) == .rejected(code: "bad_type", message: badType), "415 -> rejected with cockpit message")
check(classify(422, json, body: env("not_found", "Salesforce-record niet gevonden.")) == .rejected(code: "not_found", message: "Salesforce-record niet gevonden."), "422 -> rejected (not notFound)")
check(classify(403, json, body: env("refused")) == .rejected(code: "refused", message: "Fout van DSH (refused)"), "403 refused -> rejected with fallback message")
check(classify(403, json, body: env("pair_failed", "Koppelcode klopt niet.")) == .rejected(code: "pair_failed", message: "Koppelcode klopt niet."), "403 pair_failed -> rejected")

// Unusable JSON
let bad = DSHOutcome.rejected(code: "bad_response", message: "Onverwacht antwoord van DSH")
check(classify(200, json, body: env("weird")) == bad, "200 JSON ok false -> bad_response")
check(classify(200, json, body: Data("not json".utf8)) == bad, "200 undecodable JSON -> bad_response")
let okBody = Data("{\"ok\":true,\"data\":{\"status\":\"done\"}}".utf8)
check(classify(200, "Application/JSON", body: okBody) == .success(okBody), "200 JSON ok true -> success (media type case-insensitive)")

// Routes
check(dshRoutePath(.upload, test: false) == "calls", "upload real")
check(dshRoutePath(.upload, test: true) == "test/calls", "upload test")
check(dshRoutePath(.call("abc"), test: false) == "calls/abc", "status real")
check(dshRoutePath(.call("abc"), test: true) == "test/calls/abc", "status test")
check(dshRoutePath(.retry("abc"), test: false) == "calls/abc/retry", "retry real")
check(dshRoutePath(.retry("abc"), test: true) == "test/calls/abc/retry", "retry test")
check(dshRoutePath(.health, test: false) == "health", "health real")
check(dshRoutePath(.health, test: true) == "test/health", "health test")
check(dshRoutePath(.echo, test: false) == "test/echo" && dshRoutePath(.echo, test: true) == "test/echo", "echo is always test/echo")
check(dshRoutePath(.pair, test: false) == "pair" && dshRoutePath(.pair, test: true) == "pair", "pair is always pair")
check(dshAPIBase.hasSuffix("/cockpit/api/callbridge/v1/"), "API base is the callbridge v1 path")
// The Access token must come from the API path's own Access application, not the site root.
check(dshAccessApp.hasPrefix(dshAPIBase), "Access app URL lies under the API base")
check(cloudflaredLoginCommand == "cloudflared access login " + dshAccessApp, "login uses the same Access app URL")

// Record decodes
func call(_ data: String) -> CockpitCall? {
    return decodeCockpitData(CockpitCall.self, from: Data("{\"ok\":true,\"data\":\(data),\"at\":\"x\"}".utf8))
}
let waiting = call("{\"id\":\"trx_2\",\"clientRef\":\"r\",\"status\":\"done\",\"step\":\"waiting_for_account\",\"taskId\":null,\"noteId\":null,\"actionTaskIds\":[],\"contact\":null,\"account\":null,\"error\":null,\"retry\":false}")
check(waiting?.status == "done" && waiting?.step == "waiting_for_account" && waiting?.taskId == nil, "waiting_for_account record decodes with taskId nil")
let dup = call("{\"status\":\"duplicate\",\"duplicateOf\":\"first-ref\",\"taskId\":\"00T000000000001\"}")
check(dup?.duplicateOf == "first-ref" && dup?.taskId == "00T000000000001", "duplicate record decodes duplicateOf")
let failed = call("{\"clientRef\":\"r\",\"status\":\"failed\",\"step\":\"transcribing\",\"error\":\"Transcriptie mislukt.\",\"retry\":true,\"contact\":{\"name\":\"Test Contact\"}}")
check(failed?.status == "failed" && failed?.retry == true && failed?.error == "Transcriptie mislukt.", "failed record decodes error and retry")
let pair = decodeCockpitData(CockpitPairAnswer.self, from: Data("{\"ok\":true,\"data\":{\"token\":\"cbt_fake\",\"clientId\":\"cbc_1\"}}".utf8))
check(pair?.token == "cbt_fake" && pair?.clientId == "cbc_1", "pair answer decodes token and clientId")
let health = decodeCockpitData(CockpitHealth.self, from: Data("{\"ok\":true,\"data\":{\"version\":\"1\",\"access\":\"ok\",\"switch\":\"live\"}}".utf8))
check(health?.switch == "live" && health?.access == "ok", "health answer decodes switch live")
let echo = decodeCockpitData(CockpitEcho.self, from: Data("{\"ok\":true,\"data\":{\"method\":\"GET\",\"headers\":{},\"hasOrigin\":false,\"hasCookie\":false,\"hasBearer\":true,\"hasAccessToken\":true,\"test\":true},\"test\":true}".utf8))
check(echo?.hasBearer == true && echo?.hasOrigin == false && echo?.test == true, "echo answer decodes the flags")
check(decodeCockpitData(CockpitCall.self, from: env("not_found")) == nil, "ok false gives no data")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
