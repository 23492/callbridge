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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
