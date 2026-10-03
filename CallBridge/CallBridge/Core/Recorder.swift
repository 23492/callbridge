import Foundation

// MARK: - Recorder

/// Which recorder captured a session. Persisted in the session record so a relaunch
/// re-attaches with the same implementation.
enum RecorderKind: String, Codable {
    case audioHijack
}

/// Why a recording ended without a usable file.
enum RecorderError: Error, Equatable {
    /// The recording ran past the 2-hour limit.
    case timeout
    /// The call ended but no new recording file appeared.
    case noFile
    case startFailed(String)
}

/// Everything a recorder needs to re-attach after a crash (D-02).
/// The folder snapshot is taken once, at start, and never re-taken on resume: by then the
/// in-progress file already exists, and a fresh snapshot would hide it (Pitfall 6).
struct RecorderResumeInfo: Codable, Equatable {
    var startTime: Date
    var existingFiles: Set<String>
}

/// A source of call recordings. Audio Hijack is the only implementation in Phase 1;
/// native capture slots in behind the same interface later.
protocol Recorder: AnyObject {
    var kind: RecorderKind { get }
    /// Starts capture and returns what must be persisted for a later resume.
    func start(session: UUID) -> RecorderResumeInfo
    /// Re-attaches to a capture that was running when the app died. Must not start a new capture.
    func resume(session: UUID, info: RecorderResumeInfo)
    /// Stops capture for this session. Idempotent: a second call, or a call for a session
    /// that is not running, does nothing.
    func stop(session: UUID)
    /// Called once per session with the finished file or the reason there is none.
    var onFinished: ((UUID, Result<URL, RecorderError>) -> Void)? { get set }
}
