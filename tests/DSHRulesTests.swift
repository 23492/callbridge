// Assertions for CallBridge/CallBridge/Core/DSHRules.swift: cloudflared, pause, backoff, preflight.
// Run via scripts/test-core.sh.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

func cf(launched: Bool = true, exit: Int32 = 0, out: String = "", err: String = "", timedOut: Bool = false) -> CloudflaredTokenResult {
    return classifyCloudflaredToken(launched: launched, exit: exit, stdout: out, stderr: err, timedOut: timedOut)
}
let noToken = "Unable to find token for provided application. Please run login command to generate token."

// cloudflared token output (exit code alone never decides)
check(cf(launched: false) == .missing, "launch failure -> missing")
check(cf(exit: 0, timedOut: true) == .unreachable, "timeout -> unreachable")
check(cf(exit: 0, out: "eyJa.b.c\n") == .token("eyJa.b.c"), "exit 0 with JWT -> token (trimmed)")
check(cf(exit: 0, out: "", err: noToken) == .needsLogin, "exit 0, empty stdout, Unable to find token -> needsLogin")
check(cf(exit: 0, out: "  \n") == .needsLogin, "exit 0, blank stdout -> needsLogin")
check(cf(exit: 1, err: noToken) == .needsLogin, "exit 1, Unable to find token -> needsLogin")
check(cf(exit: 1, err: "failed to get app info: Head \"https://dsh2.knoppsmart.com\": dial tcp: lookup failed") == .unreachable, "exit 1, failed to get app info -> unreachable")
check(cf(exit: 1, err: "failed to find Access application at https://dsh2.knoppsmart.com") == .unreachable, "exit 1, failed to find Access application -> unreachable")
check(cf(exit: 1, err: "something new") == .unreachable, "exit 1, unknown stderr -> unreachable")

// Binary lookup (D-04)
let candidates = cloudflaredCandidates(pathEnv: "/a:/opt/homebrew/bin")
check(Array(candidates.prefix(2)) == ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"], "Homebrew paths come first")
check(candidates == ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/a/cloudflared"], "PATH entries follow without duplicates")
check(cloudflaredCandidates(pathEnv: nil) == ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"], "nil PATH gives the fixed paths")
check(resolveCloudflared(candidates: candidates, isExecutable: { $0 == "/usr/local/bin/cloudflared" }) == "/usr/local/bin/cloudflared", "resolve picks the executable one")
check(resolveCloudflared(candidates: candidates, isExecutable: { _ in false }) == nil, "none executable -> nil")

// Pause reasons
check(pauseReason(for: .accessMissing) == .needsLogin, "accessMissing -> needsLogin")
check(pauseReason(for: .unauthorized) == .needsPairing, "unauthorized -> needsPairing")
check(pauseReason(for: .cloudflaredMissing) == .cloudflaredMissing, "cloudflaredMissing -> cloudflaredMissing")
check(pauseReason(for: .switchOff) == .switchOff, "switchOff -> switchOff")
check(pauseReason(for: .retryable("x")) == .unreachable, "retryable -> unreachable")
check(pauseReason(for: .success(Data())) == nil, "success -> no pause")
check(pauseReason(for: .rejected(code: "bad_type", message: "m")) == nil, "rejected -> no pause")
check(pauseReason(for: .notFound) == nil && pauseReason(for: .conflict) == nil, "notFound and conflict -> no pause")

// Attempts (D-13)
check(!DSHPauseReason.needsLogin.countsAttempt, "needsLogin does not count an attempt")
check(!DSHPauseReason.needsPairing.countsAttempt, "needsPairing does not count an attempt")
check(!DSHPauseReason.cloudflaredMissing.countsAttempt, "cloudflaredMissing does not count an attempt")
check(DSHPauseReason.unreachable.countsAttempt, "unreachable counts an attempt")
check(DSHPauseReason.switchOff.countsAttempt, "switchOff counts an attempt")

// Menu titles
check(DSHPauseReason.needsLogin.menuTitle == "Log in bij DSH", "menu needsLogin")
check(DSHPauseReason.needsPairing.menuTitle == "Koppel opnieuw", "menu needsPairing")
check(DSHPauseReason.cloudflaredMissing.menuTitle == "cloudflared ontbreekt", "menu cloudflaredMissing")
check(DSHPauseReason.unreachable.menuTitle == "DSH niet bereikbaar", "menu unreachable")
check(DSHPauseReason.switchOff.menuTitle == "DSH staat uit in de cockpit", "menu switchOff")

// Backoff
check(dshBackoffDelay(attempt: 1) == 5, "attempt 1 -> 5 s")
check(dshBackoffDelay(attempt: 2) == 30, "attempt 2 -> 30 s")
check(dshBackoffDelay(attempt: 3) == 300, "attempt 3 -> 300 s")
check(dshBackoffDelay(attempt: 9) == 300, "attempt 9 -> 300 s")
check(dshBackoffDelay(attempt: 0) == 5, "attempt 0 -> 5 s")

// Token result to outcome
check(dshOutcome(for: .needsLogin) == .accessMissing, "needsLogin -> accessMissing")
check(dshOutcome(for: .missing) == .cloudflaredMissing, "missing -> cloudflaredMissing")
if case .retryable? = dshOutcome(for: .unreachable) { check(true, "unreachable -> retryable") } else { check(false, "unreachable -> retryable") }
check(dshOutcome(for: .token("eyJa.b.c")) == nil, "token -> no outcome")

// Preflight (D-15, D-25, Pitfall 8)
check(dshPreflight(path: "/x/a.mp3", sizeBytes: 1_000, phoneNumber: "+31612345678", salesforceID: nil) == .ok(mime: "audio/mpeg"), "mp3 with phone -> ok audio/mpeg")
check(dshPreflight(path: "/x/a.aiff", sizeBytes: 1_000, phoneNumber: "1", salesforceID: nil) == .rejected("Bestandstype niet ondersteund door DSH"), "aiff -> unsupported type")
check(dshPreflight(path: "/x/a.caf", sizeBytes: 1_000, phoneNumber: "1", salesforceID: nil) == .rejected("Bestandstype niet ondersteund door DSH"), "caf -> unsupported type")
if case .rejected(let m) = dshPreflight(path: "/x/a.m4a", sizeBytes: 95_000_001, phoneNumber: "1", salesforceID: nil) {
    check(m.contains("95 MB"), "95_000_001 bytes -> too large, message names 95 MB")
} else {
    check(false, "95_000_001 bytes -> too large, message names 95 MB")
}
check(dshPreflight(path: "/x/a.m4a", sizeBytes: dshMaxUploadBytes, phoneNumber: "1", salesforceID: nil) == .ok(mime: "audio/mp4"), "exactly 95_000_000 bytes -> ok")
check(dshPreflight(path: "/x/a.m4a", sizeBytes: 0, phoneNumber: "1", salesforceID: nil) == .rejected("Opname is leeg of niet leesbaar"), "0 bytes -> empty")
check(dshPreflight(path: "/x/a.m4a", sizeBytes: 1_000, phoneNumber: "", salesforceID: nil) == .rejected("Kies eerst een contact"), "no phone and no salesforce id -> pick a contact")
check(dshPreflight(path: "/x/a.m4a", sizeBytes: 1_000, phoneNumber: "", salesforceID: "003000000000001") == .ok(mime: "audio/mp4"), "no phone with salesforce id -> ok")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
