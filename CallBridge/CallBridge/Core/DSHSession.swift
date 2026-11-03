import Foundation

// MARK: - DSH Session Rules

/// D-09, D-10, D-12: the route a session takes when it leaves awaitingDecision.
/// A session the cockpit already accepted stays on the DSH route whatever the toggle says,
/// so a toggle flip never sends it through the local pipeline for a second call Task.
/// Otherwise the "Transcriberen via DSH" toggle decides at send time; there is no
/// automatic switching on cockpit health.
func chooseRoute(for record: SessionRecord, dshEnabled: Bool) -> SessionRoute {
    if record.dshAccepted { return .dsh }
    return dshEnabled ? .dsh : .local
}

/// True when the string is present and not empty.
private func hasValue(_ s: String?) -> Bool {
    guard let s = s else { return false }
    return !s.isEmpty
}

/// D-16: maps a cockpit status answer onto a local stage. nil means "no change, keep polling".
/// A "done" without a task id maps to awaitingAccount: nothing was logged yet, so there is
/// nothing to delete. A "duplicate" without a task id stays polled (D-16b).
func stageForCockpit(status: String, step: String?, taskId: String?) -> SessionStage? {
    switch status {
    case "uploading": return .uploading
    case "transcribing", "summarizing": return .transcribing
    case "writing": return .logging
    case "done": return hasValue(taskId) ? .done : .awaitingAccount
    case "failed": return .failed
    case "duplicate": return hasValue(taskId) ? .done : nil
    default: return nil
    }
}

/// D-19, TRX-06: the recording may go to the Trash only once the cockpit reports the call
/// logged, that is status done or duplicate with a non-empty task id.
func shouldTrashRecording(status: String, taskId: String?) -> Bool {
    (status == "done" || status == "duplicate") && hasValue(taskId)
}
