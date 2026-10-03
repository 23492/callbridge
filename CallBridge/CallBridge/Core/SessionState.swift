import Foundation

// MARK: - Session State

/// Where a recording session stands. Persisted before each side effect, so a relaunch
/// knows what to resume (FND-04).
enum SessionStage: String, Codable, CaseIterable {
    case recording
    case awaitingDecision
    case uploading
    case transcribing
    case logging
    case loggingNNO
    case done
    case failed
    case discarded

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .discarded: return true
        default: return false
        }
    }
}

/// How a session started: a tel: call, or a file picked by hand in "Verwerken".
enum SessionSource: String, Codable {
    case call
    case manual
}

/// One recording session as stored in sessions/<id>.json. Local-only file, so the
/// JSON keys are the Swift property names.
struct SessionRecord: Codable, Equatable {
    /// Sent to the backend as client_ref.
    let id: UUID
    var stage: SessionStage
    var source: SessionSource
    var phoneNumber: String
    var recorderKind: RecorderKind?
    var resumeInfo: RecorderResumeInfo?
    var audioPath: String?
    var contactID: String?
    var contactType: String?
    var contactName: String?
    var direction: String?
    var taskID: String?
    var error: String?
    var attempts: Int
    var createdAt: Date
    var updatedAt: Date
    /// Set by the caller when the session enters loggingNNO, so a retry of a failed
    /// session goes back to the NNO path instead of a full upload.
    var wasNNO: Bool

    init(id: UUID = UUID(), source: SessionSource, phoneNumber: String, now: Date) {
        self.id = id
        self.stage = source == .call ? .recording : .awaitingDecision
        self.source = source
        self.phoneNumber = phoneNumber
        self.attempts = 0
        self.createdAt = now
        self.updatedAt = now
        self.wasNNO = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, stage, source, phoneNumber, recorderKind, resumeInfo, audioPath
        case contactID, contactType, contactName, direction, taskID, error
        case attempts, createdAt, updatedAt, wasNNO
    }

    /// Hand-written only so records saved before wasNNO existed still decode (as false).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        stage = try c.decode(SessionStage.self, forKey: .stage)
        source = try c.decode(SessionSource.self, forKey: .source)
        phoneNumber = try c.decode(String.self, forKey: .phoneNumber)
        recorderKind = try c.decodeIfPresent(RecorderKind.self, forKey: .recorderKind)
        resumeInfo = try c.decodeIfPresent(RecorderResumeInfo.self, forKey: .resumeInfo)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        contactID = try c.decodeIfPresent(String.self, forKey: .contactID)
        contactType = try c.decodeIfPresent(String.self, forKey: .contactType)
        contactName = try c.decodeIfPresent(String.self, forKey: .contactName)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        attempts = try c.decode(Int.self, forKey: .attempts)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        wasNNO = try c.decodeIfPresent(Bool.self, forKey: .wasNNO) ?? false
    }
}

// MARK: - Transitions

/// Whether a session may move from one stage to another. A same-stage write (a new step,
/// attempts += 1) is allowed for every non-terminal stage; terminal stages only leave
/// through a retry of a failed session.
func canTransition(from: SessionStage, to: SessionStage) -> Bool {
    if from == to && !from.isTerminal { return true }
    switch (from, to) {
    case (.recording, .awaitingDecision), (.recording, .failed), (.recording, .discarded),
         (.awaitingDecision, .uploading), (.awaitingDecision, .loggingNNO), (.awaitingDecision, .discarded),
         (.uploading, .transcribing), (.uploading, .done), (.uploading, .failed),
         (.transcribing, .logging), (.transcribing, .done), (.transcribing, .failed),
         (.logging, .done), (.logging, .failed),
         (.loggingNNO, .done), (.loggingNNO, .failed),
         (.failed, .uploading), (.failed, .loggingNNO):
        return true
    default:
        return false
    }
}

// MARK: - Resume

/// The longest a recording may run; matches the recorder's 2-hour timeout.
let maxRecordingDuration: TimeInterval = 2 * 3600

/// What the app does with a stored session on launch.
enum ResumeAction: Equatable {
    case none
    /// D-02: re-attach the recorder with the stored snapshot; the normal dialog follows.
    case reattachRecorder
    /// The recording finished but the user had not chosen yet: show the save dialog again.
    case showSaveDialog
    /// D-01: resend POST /process with the same client_ref, no dialog.
    case resendProcess
    /// D-01: resend POST /log-nno with the same client_ref, no dialog.
    case resendNNO
    /// The caller moves the record to discarded with this error and keeps any audio file.
    case abandon(String)
}

/// D-01 and D-02: every non-terminal session resumes automatically on launch.
/// Time is a parameter so the rule is testable.
func resumeAction(for record: SessionRecord, now: Date) -> ResumeAction {
    switch record.stage {
    case .recording:
        // App died between saving the record and starting the recorder.
        guard let info = record.resumeInfo else { return .abandon("interrupted") }
        if now.timeIntervalSince(info.startTime) > maxRecordingDuration { return .abandon("timeout") }
        return .reattachRecorder
    case .awaitingDecision: return .showSaveDialog
    case .uploading, .transcribing, .logging: return .resendProcess
    case .loggingNNO: return .resendNNO
    case .done, .failed, .discarded: return .none
    }
}

/// D-04: sessions for the "Mislukt (n)" submenu, newest first.
func failedSessions(_ records: [SessionRecord]) -> [SessionRecord] {
    records.filter { $0.stage == .failed }.sorted { $0.createdAt > $1.createdAt }
}

/// The open session that already owns a manually picked file, so "Verwerken" reuses its id.
/// A done or discarded match returns nil: a new session id lets the backend's hash+target
/// check decide (same target blocked, other target allowed).
func reusableSession(forAudioPath path: String, in records: [SessionRecord]) -> SessionRecord? {
    records
        .filter { $0.audioPath == path && $0.stage != .done && $0.stage != .discarded }
        .max { $0.createdAt < $1.createdAt }
}

/// Maps the GET /sessions/{client_ref} answer (keys `stage`, `step`) onto a local stage.
/// "unknown" (or anything unrecognised) returns nil: the backend never saw the request, so resend.
func stageForBackend(stage: String, step: String?) -> SessionStage? {
    switch stage {
    case "processing": return step == "saving_to_salesforce" ? .logging : .transcribing
    case "done": return .done
    case "failed": return .failed
    default: return nil
    }
}

/// Where "Opnieuw proberen" sends a failed session (D-04).
func retryStage(for record: SessionRecord) -> SessionStage {
    record.wasNNO ? .loggingNNO : .uploading
}

// MARK: - Retention

/// D-03: session records and their audio are kept 7 days, for succeeded and failed sessions alike.
let sessionRetention: TimeInterval = 7 * 24 * 3600

/// Terminal records (done, failed, discarded) whose last update is at least `retention` ago.
/// Non-terminal records are never returned. The caller deletes the record and moves only the
/// audio file that record references to the Trash, never other files in the folder (Pitfall 10).
func sessionsToPrune(_ records: [SessionRecord], now: Date,
                     retention: TimeInterval = sessionRetention) -> [SessionRecord] {
    records.filter { $0.stage.isTerminal && now.timeIntervalSince($0.updatedAt) >= retention }
}

/// Non-terminal sessions (other than recording, which resumeAction handles) that have not
/// moved for `retention`. They are surfaced under "Mislukt" and never deleted automatically.
func staleNonTerminal(_ records: [SessionRecord], now: Date,
                      retention: TimeInterval = sessionRetention) -> [SessionRecord] {
    records.filter {
        !$0.stage.isTerminal && $0.stage != .recording && now.timeIntervalSince($0.updatedAt) >= retention
    }
}
