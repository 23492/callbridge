// Assertions for the DSH session rules in CallBridge/CallBridge/Core/DSHSession.swift.
// Run via scripts/test-core.sh.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let now = Date(timeIntervalSince1970: 1_790_000_000)
func rec(_ stage: SessionStage, route: SessionRoute = .local, accepted: Bool = false) -> SessionRecord {
    var r = SessionRecord(source: .call, phoneNumber: "+31612345678", now: now)
    r.stage = stage
    r.route = route
    r.dshAccepted = accepted
    return r
}

// Route choice (D-10, D-12)
check(chooseRoute(for: rec(.awaitingDecision, accepted: true), dshEnabled: false) == .dsh, "chooseRoute accepted + toggle off -> dsh")
check(chooseRoute(for: rec(.awaitingDecision), dshEnabled: true) == .dsh, "chooseRoute not accepted + toggle on -> dsh")
check(chooseRoute(for: rec(.awaitingDecision), dshEnabled: false) == .local, "chooseRoute not accepted + toggle off -> local")

// Cockpit status mapping (D-16)
check(stageForCockpit(status: "uploading", step: nil, taskId: nil) == .uploading, "cockpit uploading -> uploading")
check(stageForCockpit(status: "transcribing", step: nil, taskId: nil) == .transcribing, "cockpit transcribing -> transcribing")
check(stageForCockpit(status: "summarizing", step: nil, taskId: nil) == .transcribing, "cockpit summarizing -> transcribing")
check(stageForCockpit(status: "writing", step: nil, taskId: nil) == .logging, "cockpit writing -> logging")
check(stageForCockpit(status: "done", step: "done", taskId: "00T000000000001") == .done, "cockpit done + taskId -> done")
check(stageForCockpit(status: "done", step: "waiting_for_account", taskId: nil) == .awaitingAccount, "cockpit done/waiting_for_account/nil -> awaitingAccount")
check(stageForCockpit(status: "done", step: "waiting_for_account", taskId: "") == .awaitingAccount, "cockpit done/waiting_for_account/\"\" -> awaitingAccount")
check(stageForCockpit(status: "done", step: "done", taskId: "") == .awaitingAccount, "cockpit done/done/\"\" -> awaitingAccount")
check(stageForCockpit(status: "failed", step: "transcribing", taskId: nil) == .failed, "cockpit failed -> failed")
check(stageForCockpit(status: "duplicate", step: nil, taskId: "00T000000000001") == .done, "cockpit duplicate + taskId -> done")
check(stageForCockpit(status: "duplicate", step: nil, taskId: nil) == nil, "cockpit duplicate without taskId -> nil (stays polled)")
check(stageForCockpit(status: "duplicate", step: nil, taskId: "") == nil, "cockpit duplicate with empty taskId -> nil")
check(stageForCockpit(status: "bogus", step: nil, taskId: "00T000000000001") == nil, "cockpit unknown status -> nil")

// Delete rule (D-19, TRX-06)
check(shouldTrashRecording(status: "done", taskId: "00T000000000001"), "trash done + taskId")
check(shouldTrashRecording(status: "duplicate", taskId: "00T000000000001"), "trash duplicate + taskId")
check(!shouldTrashRecording(status: "done", taskId: nil), "no trash done + nil taskId")
check(!shouldTrashRecording(status: "done", taskId: ""), "no trash done + empty taskId")
check(!shouldTrashRecording(status: "failed", taskId: "00T000000000001"), "no trash failed + taskId")
check(!shouldTrashRecording(status: "transcribing", taskId: "00T000000000001"), "no trash transcribing + taskId")

// Dutch step labels (D-16)
check(cockpitStepLabel(status: "uploading", step: nil) == "Uploaden", "label uploading -> Uploaden")
check(cockpitStepLabel(status: "transcribing", step: nil) == "Transcriberen", "label transcribing -> Transcriberen")
check(cockpitStepLabel(status: "summarizing", step: nil) == "Samenvatten", "label summarizing -> Samenvatten")
check(cockpitStepLabel(status: "writing", step: nil) == "Salesforce bijwerken", "label writing -> Salesforce bijwerken")
check(cockpitStepLabel(status: "done", step: "waiting_for_account") == "Wacht op account", "label done/waiting_for_account -> Wacht op account")
check(cockpitStepLabel(status: "bogus", step: nil) == "Bezig", "label unknown -> Bezig")

// Poll interval (D-18)
check(dshFastPollInterval == 15 && dshSlowPollInterval == 300, "poll intervals are 15 s and 300 s")
check(dshPollInterval([rec(.transcribing, route: .dsh, accepted: true), rec(.awaitingAccount, route: .dsh, accepted: true)]) == 15, "poll 15 s with an active accepted dsh session")
check(dshPollInterval([rec(.uploading, route: .dsh, accepted: true)]) == 15, "poll 15 s for an accepted dsh upload")
check(dshPollInterval([rec(.logging, route: .dsh, accepted: true)]) == 15, "poll 15 s for an accepted dsh logging session")
check(dshPollInterval([rec(.awaitingAccount, route: .dsh, accepted: true)]) == 300, "poll 300 s when only awaitingAccount remains")
check(dshPollInterval([]) == nil, "no poll without records")
check(dshPollInterval([rec(.transcribing, route: .local)]) == nil, "no poll for local sessions")
check(dshPollInterval([rec(.uploading, route: .dsh, accepted: false)]) == nil, "no poll for an unaccepted dsh upload")
check(dshPollInterval([rec(.done, route: .dsh, accepted: true)]) == nil, "no poll for a done dsh session")

// Pending DSH work gates the pause state (D-10, D-21, D-23)
check(hasPendingDSHWork([]) == false, "no pending dsh work in an empty store")
check(hasPendingDSHWork([rec(.uploading, route: .local)]) == false, "a local upload is no dsh work")
check(hasPendingDSHWork([rec(.done, route: .dsh, accepted: true)]) == false, "a done dsh session is no pending work")
check(hasPendingDSHWork([rec(.failed, route: .dsh, accepted: true)]) == false, "a failed dsh session is no pending work")
check(hasPendingDSHWork([rec(.discarded, route: .dsh)]) == false, "a discarded dsh session is no pending work")
check(hasPendingDSHWork([rec(.uploading, route: .dsh, accepted: false)]) == true, "an unaccepted dsh upload is pending work")
check(hasPendingDSHWork([rec(.transcribing, route: .dsh, accepted: true)]) == true, "an accepted dsh transcription is pending work")
check(hasPendingDSHWork([rec(.awaitingAccount, route: .dsh, accepted: true)]) == true, "a dsh session awaiting an account is pending work")
check(hasPendingDSHWork([rec(.logging, route: .dsh, accepted: true), rec(.uploading, route: .local)]) == true, "pending dsh work among local sessions")

// Credential keys (D-08)
check(requiredCredentialKeys(dshEnabled: true) == ["SF_USERNAME", "SF_PASSWORD", "SF_SECURITY_TOKEN", "SF_DOMAIN"], "DSH on needs only the four SF keys")
check(requiredCredentialKeys(dshEnabled: false) == ["ASSEMBLYAI_API_KEY", "GEMINI_API_KEY", "SF_USERNAME", "SF_PASSWORD", "SF_SECURITY_TOKEN", "SF_DOMAIN"], "DSH off needs all six keys in the current order")

// Settings keys and the DSH toggle (D-06, D-26)
check(dshEnabledDefaultsKey == "dshEnabled", "dshEnabled defaults key")
check(dshUseTestRoutesDefaultsKey == "dshUseTestRoutes", "dshUseTestRoutes defaults key")
check(dshTestScenarioDefaultsKey == "dshTestScenario", "dshTestScenario defaults key")
let suiteName = "callbridge-tests-\(UUID().uuidString)"
if let suite = UserDefaults(suiteName: suiteName) {
    check(readDSHEnabled(suite) == true, "readDSHEnabled on a fresh suite -> true")
    suite.set(false, forKey: dshEnabledDefaultsKey)
    check(readDSHEnabled(suite) == false, "readDSHEnabled after setting false -> false")
    suite.removePersistentDomain(forName: suiteName)
} else {
    check(false, "UserDefaults(suiteName:) returned nil")
}
check(dshCockpitURL == "https://dsh2.knoppsmart.com/cockpit/", "cockpit URL")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
