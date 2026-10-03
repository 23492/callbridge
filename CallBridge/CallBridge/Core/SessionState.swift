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

    init(id: UUID = UUID(), source: SessionSource, phoneNumber: String, now: Date) {
        self.id = id
        self.stage = source == .call ? .recording : .awaitingDecision
        self.source = source
        self.phoneNumber = phoneNumber
        self.attempts = 0
        self.createdAt = now
        self.updatedAt = now
    }
}
