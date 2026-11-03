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

/// D-16: the Dutch menu label for a cockpit status and step. Unknown input reads "Bezig".
func cockpitStepLabel(status: String, step: String?) -> String {
    if step == "waiting_for_account" { return "Wacht op account" }
    switch status {
    case "uploading": return "Uploaden"
    case "transcribing": return "Transcriberen"
    case "summarizing": return "Samenvatten"
    case "writing": return "Salesforce bijwerken"
    default: return "Bezig"
    }
}

// MARK: - DSH Poll Interval

/// D-18: poll interval while an accepted DSH session is uploading, transcribing or logging.
let dshFastPollInterval: TimeInterval = 15
/// D-18: poll interval when the only accepted DSH sessions left wait for an account.
let dshSlowPollInterval: TimeInterval = 300

/// D-18: how often the DSH queue polls the cockpit, or nil when no accepted DSH session
/// needs polling. Unaccepted sessions are handled by the upload queue, not the poller.
func dshPollInterval(_ records: [SessionRecord]) -> TimeInterval? {
    let accepted = records.filter { $0.route == .dsh && $0.dshAccepted }
    if accepted.contains(where: { [SessionStage.uploading, .transcribing, .logging].contains($0.stage) }) {
        return dshFastPollInterval
    }
    if accepted.contains(where: { $0.stage == .awaitingAccount }) { return dshSlowPollInterval }
    return nil
}

// MARK: - DSH Pending Work

/// D-10, D-21, D-23: true when at least one route dsh session still waits on the cockpit,
/// that is stage uploading, transcribing, logging or awaitingAccount, accepted or not.
/// The DSH pause state (menu status line, pause notification) exists only while this is
/// true, so an unpaired Mac with the toggle off never shows "Koppel opnieuw".
func hasPendingDSHWork(_ records: [SessionRecord]) -> Bool {
    let waiting: Set<SessionStage> = [.uploading, .transcribing, .logging, .awaitingAccount]
    return records.contains { $0.route == .dsh && waiting.contains($0.stage) }
}

// MARK: - DSH Settings

/// D-06: UserDefaults key of the "Transcriberen via DSH" toggle (default on).
let dshEnabledDefaultsKey = "dshEnabled"
/// D-26: hidden debug setting that sends sessions to the cockpit test routes.
let dshUseTestRoutesDefaultsKey = "dshUseTestRoutes"
/// D-26: hidden debug setting naming the cockpit test scenario to run.
let dshTestScenarioDefaultsKey = "dshTestScenario"

/// D-06: the "Transcriberen via DSH" toggle; true when the key was never set.
func readDSHEnabled(_ defaults: UserDefaults) -> Bool {
    guard defaults.object(forKey: dshEnabledDefaultsKey) != nil else { return true }
    return defaults.bool(forKey: dshEnabledDefaultsKey)
}

/// D-08: the Keychain keys the credential gate requires. With DSH on, transcription and
/// summary run in the cockpit, so the AssemblyAI and Gemini keys are not needed.
func requiredCredentialKeys(dshEnabled: Bool) -> [String] {
    let salesforce = ["SF_USERNAME", "SF_PASSWORD", "SF_SECURITY_TOKEN", "SF_DOMAIN"]
    return dshEnabled ? salesforce : ["ASSEMBLYAI_API_KEY", "GEMINI_API_KEY"] + salesforce
}

/// D-22: the "Wacht op account" items open the cockpit so Kiran can link the account
/// in Transcriberen.
let dshCockpitURL = "https://dsh2.knoppsmart.com/cockpit/"
