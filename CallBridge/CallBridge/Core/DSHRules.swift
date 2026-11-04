import Foundation

// MARK: - cloudflared

/// What `cloudflared access token -app=<dshAccessApp>` told us. The JWT only travels
/// inside `.token`; nothing in this file logs it.
enum CloudflaredTokenResult: Equatable {
    case token(String)
    case needsLogin
    case unreachable
    case missing
}

/// Classifies one cloudflared run. Exit code alone never decides (refines D-05):
/// an expired token is deleted and cloudflared exits 0 with empty stdout, so on exit 0
/// the trimmed stdout decides; on a non-zero exit stderr decides. Unknown stderr is
/// treated as unreachable: the queue backs off and keeps every recording, and an
/// offline Mac is never asked for a useless login.
func classifyCloudflaredToken(launched: Bool, exit: Int32, stdout: String, stderr: String, timedOut: Bool) -> CloudflaredTokenResult {
    guard launched else { return .missing }
    if timedOut { return .unreachable }
    let token = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if exit == 0 {
        return token.isEmpty ? .needsLogin : .token(token)
    }
    if stderr.contains("Unable to find token") { return .needsLogin }
    if stderr.contains("failed to get app info") || stderr.contains("failed to find Access application") {
        return .unreachable
    }
    return .unreachable
}

/// Where to look for cloudflared (D-04): the Homebrew paths first, so an earlier
/// binary named cloudflared on PATH is not preferred, then each PATH entry, deduplicated.
func cloudflaredCandidates(pathEnv: String?) -> [String] {
    var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
    for entry in (pathEnv ?? "").split(separator: ":").map(String.init) where !entry.isEmpty {
        let dir = entry.hasSuffix("/") && entry.count > 1 ? String(entry.dropLast()) : entry
        if !dirs.contains(dir) { dirs.append(dir) }
    }
    return dirs.map { $0 + "/cloudflared" }
}

/// The first executable candidate, or nil when cloudflared is not installed.
func resolveCloudflared(candidates: [String], isExecutable: (String) -> Bool) -> String? {
    return candidates.first(where: isExecutable)
}

/// Menu item "Log in bij DSH" runs this once; it opens the browser sign-in.
let cloudflaredLoginCommand = "cloudflared access login " + dshAccessApp
/// Menu item "cloudflared ontbreekt" offers this install command.
let cloudflaredInstallCommand = "brew install cloudflared"
/// How long a fetched Access token is reused before cloudflared runs again (D-05).
let dshAccessTokenCacheLifetime: TimeInterval = 60

// MARK: - Pause and Backoff

/// Why the DSH queue is paused; every recording is kept while paused.
enum DSHPauseReason: String, Equatable {
    case needsLogin, needsPairing, cloudflaredMissing, unreachable, switchOff

    /// Pauses that wait for Kiran (sign in, pair, install) do not use up attempts (D-13).
    var countsAttempt: Bool {
        switch self {
        case .needsLogin, .needsPairing, .cloudflaredMissing: return false
        case .unreachable, .switchOff: return true
        }
    }

    /// The menu line for this pause (D-11, D-21).
    var menuTitle: String {
        switch self {
        case .needsLogin: return "Log in bij DSH"
        case .needsPairing: return "Koppel opnieuw"
        case .cloudflaredMissing: return "cloudflared ontbreekt"
        case .unreachable: return "DSH niet bereikbaar"
        case .switchOff: return "DSH staat uit in de cockpit"
        }
    }
}

/// The pause an outcome causes, or nil when the outcome is final for this request.
func pauseReason(for outcome: DSHOutcome) -> DSHPauseReason? {
    switch outcome {
    case .accessMissing: return .needsLogin
    case .unauthorized: return .needsPairing
    case .cloudflaredMissing: return .cloudflaredMissing
    case .switchOff: return .switchOff
    case .retryable: return .unreachable
    case .success, .rejected, .notFound, .conflict: return nil
    }
}

/// The outcome a cloudflared result stands for when no request can be sent; nil for a token.
func dshOutcome(for token: CloudflaredTokenResult) -> DSHOutcome? {
    switch token {
    case .token: return nil
    case .needsLogin: return .accessMissing
    case .missing: return .cloudflaredMissing
    case .unreachable: return .retryable("DSH niet bereikbaar")
    }
}

/// Wait before the next try (D-13): 5 s, 30 s, then 5 minutes for every later attempt.
func dshBackoffDelay(attempt: Int) -> TimeInterval {
    switch attempt {
    case ...1: return 5
    case 2: return 30
    default: return 300
    }
}

// MARK: - Preflight

/// The cockpit's upload limit, 95 x 10^6 bytes; its own message reads "95,0 MB" (Research A5).
let dshMaxUploadBytes: Int64 = 95_000_000

enum DSHPreflight: Equatable {
    case ok(mime: String)
    case rejected(String)
}

/// Checks a recording before it leaves the Mac: type (D-15), size (Pitfall 8), empty
/// file, and a target the cockpit can match (D-25).
func dshPreflight(path: String, sizeBytes: Int64, phoneNumber: String, salesforceID: String?) -> DSHPreflight {
    guard let mime = dshMimeType(forExtension: (path as NSString).pathExtension) else {
        return .rejected("Bestandstype niet ondersteund door DSH")
    }
    if sizeBytes <= 0 {
        return .rejected("Opname is leeg of niet leesbaar")
    }
    if sizeBytes > dshMaxUploadBytes {
        // "Opname is te groot voor DSH (max 95 MB). Zet 'Transcriberen via DSH' uit en probeer opnieuw."
        return .rejected(dshTooLargeMessage)
    }
    let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let sfID = (salesforceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if phone.isEmpty && sfID.isEmpty {
        return .rejected("Kies eerst een contact")
    }
    return .ok(mime: mime)
}
