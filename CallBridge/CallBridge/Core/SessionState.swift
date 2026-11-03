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
    /// D-20: the cockpit finished the transcript but has no account to log it on yet.
    /// Non-terminal: it waits until Kiran links the account in Transcriberen.
    case awaitingAccount
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

/// Which pipeline handles a session. D-09: chosen once when the session leaves
/// awaitingDecision and persisted, so resume and retry never switch pipelines.
enum SessionRoute: String, Codable {
    case dsh
    case local
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
    /// D-09: the pipeline this session uses; local for records written before Phase 3.
    var route: SessionRoute
    /// D-12: true once the cockpit answered 202 or 200 for this client_ref. An accepted
    /// session never leaves the DSH route.
    var dshAccepted: Bool
    /// D-26: true when the session was sent to the cockpit test routes, so a test session
    /// never reaches the real routes later.
    var dshTest: Bool
    /// D-13: earliest moment the DSH queue may try this session again (backoff).
    var nextAttemptAt: Date?
    /// D-16b: the client_ref the cockpit reported this session duplicates.
    var duplicateOf: String?
    /// Last cockpit step, used for the menu label.
    var cockpitStep: String?

    init(id: UUID = UUID(), source: SessionSource, phoneNumber: String, now: Date) {
        self.id = id
        self.stage = source == .call ? .recording : .awaitingDecision
        self.source = source
        self.phoneNumber = phoneNumber
        self.attempts = 0
        self.createdAt = now
        self.updatedAt = now
        self.wasNNO = false
        self.route = .local
        self.dshAccepted = false
        self.dshTest = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, stage, source, phoneNumber, recorderKind, resumeInfo, audioPath
        case contactID, contactType, contactName, direction, taskID, error
        case attempts, createdAt, updatedAt, wasNNO
        case route, dshAccepted, dshTest, nextAttemptAt, duplicateOf, cockpitStep
    }

    /// Hand-written only so older records still decode: without wasNNO (as false), and
    /// without the Phase 3 fields route, dshAccepted, dshTest, nextAttemptAt, duplicateOf and
    /// cockpitStep (as route local, not accepted, not a test, and nil).
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
        route = try c.decodeIfPresent(SessionRoute.self, forKey: .route) ?? .local
        dshAccepted = try c.decodeIfPresent(Bool.self, forKey: .dshAccepted) ?? false
        dshTest = try c.decodeIfPresent(Bool.self, forKey: .dshTest) ?? false
        nextAttemptAt = try c.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        duplicateOf = try c.decodeIfPresent(String.self, forKey: .duplicateOf)
        cockpitStep = try c.decodeIfPresent(String.self, forKey: .cockpitStep)
    }
}

// MARK: - Transitions

/// Whether a session may move from one stage to another. A same-stage write (a new step,
/// attempts += 1) is allowed for every non-terminal stage; terminal stages only leave
/// through a retry of a failed session.
/// DSH route pairs: awaitingDecision->failed is the D-15 preflight; transcribing/logging->
/// uploading is the D-17b re-upload after a 404; failed->transcribing is a cockpit POST retry;
/// awaitingAccount->transcribing/logging is the cockpit moving on once Kiran links the account;
/// failed->logging/awaitingAccount is a retry answer that is already further along. Together
/// they make every stage stageForCockpit returns reachable from every stage it is applied to.
func canTransition(from: SessionStage, to: SessionStage) -> Bool {
    if from == to && !from.isTerminal { return true }
    switch (from, to) {
    case (.recording, .awaitingDecision), (.recording, .failed), (.recording, .discarded),
         (.awaitingDecision, .uploading), (.awaitingDecision, .loggingNNO), (.awaitingDecision, .discarded),
         (.uploading, .transcribing), (.uploading, .done), (.uploading, .failed),
         (.transcribing, .logging), (.transcribing, .done), (.transcribing, .failed),
         (.logging, .done), (.logging, .failed),
         (.loggingNNO, .done), (.loggingNNO, .failed),
         (.failed, .uploading), (.failed, .loggingNNO),
         (.awaitingDecision, .failed),
         (.uploading, .awaitingAccount), (.transcribing, .awaitingAccount), (.logging, .awaitingAccount),
         (.awaitingAccount, .done), (.awaitingAccount, .failed),
         (.uploading, .logging), (.transcribing, .uploading), (.logging, .uploading),
         (.failed, .transcribing),
         (.awaitingAccount, .transcribing), (.awaitingAccount, .logging),
         (.failed, .logging), (.failed, .awaitingAccount):
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
    /// D-09: a DSH session resumes through the DSH queue (poll, or re-upload with the same client_ref), never through POST /process.
    case resumeDSH
    /// The caller moves the record to discarded with this error and keeps any audio file.
    case abandon(String)
}

/// D-01 and D-02: every non-terminal session resumes automatically on launch.
/// D-09: route dsh sessions resume through the DSH queue, never through POST /process.
/// Time is a parameter so the rule is testable.
func resumeAction(for record: SessionRecord, now: Date) -> ResumeAction {
    switch record.stage {
    case .recording:
        // App died between saving the record and starting the recorder.
        guard let info = record.resumeInfo else { return .abandon("interrupted") }
        if now.timeIntervalSince(info.startTime) > maxRecordingDuration { return .abandon("timeout") }
        return .reattachRecorder
    case .awaitingDecision: return .showSaveDialog
    case .uploading, .transcribing, .logging:
        return record.route == .dsh ? .resumeDSH : .resendProcess
    case .awaitingAccount:
        // Only the DSH route reaches awaitingAccount.
        return record.route == .dsh ? .resumeDSH : .none
    case .loggingNNO: return .resendNNO
    case .done, .failed, .discarded: return .none
    }
}

/// D-01: the notification shown when a session is resent on relaunch. Uses the contact
/// name when known, the phone number otherwise.
func resumeNotificationText(for record: SessionRecord) -> String {
    let who: String
    if let name = record.contactName, !name.isEmpty {
        who = name
    } else {
        who = record.phoneNumber
    }
    if record.wasNNO { return "NNO voor \(who) wordt alsnog gelogd" }
    return "Gesprek met \(who) wordt alsnog verwerkt"
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

/// The stage a session moves to once POST /process (`nno: false`) or POST /log-nno
/// (`nno: true`) has answered. `httpStatus` is nil on a transport error; `bodyStatus` is the
/// response's "status" key. A 409 on /log-nno means the backend is still logging that NNO,
/// so the session stays in loggingNNO and the poller resolves it.
func stageAfterSubmit(httpStatus: Int?, bodyStatus: String?, nno: Bool) -> SessionStage {
    guard let code = httpStatus else { return .failed }
    if nno && code == 409 { return .loggingNNO }
    guard (200...299).contains(code) else { return .failed }
    if nno { return .done }
    return bodyStatus == "duplicate" ? .done : .transcribing
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

/// Non-terminal sessions that have not moved for `retention`. They are surfaced under
/// "Mislukt" and never deleted automatically. Left out: recording (resumeAction handles it),
/// awaitingAccount (D-20: waits for Kiran to link the account, however long that takes) and
/// route dsh uploads the cockpit has not accepted yet (queued behind a pause, shown under
/// "Wachtrij").
func staleNonTerminal(_ records: [SessionRecord], now: Date,
                      retention: TimeInterval = sessionRetention) -> [SessionRecord] {
    records.filter {
        if $0.stage.isTerminal || $0.stage == .recording || $0.stage == .awaitingAccount { return false }
        if $0.route == .dsh && $0.stage == .uploading && !$0.dshAccepted { return false }
        return now.timeIntervalSince($0.updatedAt) >= retention
    }
}
