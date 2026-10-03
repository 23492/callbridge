import Foundation

// MARK: - Call State Machine

enum CallState {
    case idle
    case recording(phoneNumber: String, startTime: Date, sessionID: UUID)
    case showingDialog(phoneNumber: String, audioPath: String)
    case processing
}
