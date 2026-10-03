// Assertions for the session rules in CallBridge/CallBridge/Core/SessionState.swift.
// Run via scripts/test-core.sh.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let now = Date(timeIntervalSince1970: 1_790_000_000)
func rec(_ stage: SessionStage, created: TimeInterval = 0, updated: TimeInterval = 0,
         audio: String? = nil) -> SessionRecord {
    var r = SessionRecord(source: .call, phoneNumber: "+31612345678", now: now.addingTimeInterval(created))
    r.stage = stage
    r.updatedAt = now.addingTimeInterval(updated)
    r.audioPath = audio
    return r
}
func recording(startedSecondsAgo s: TimeInterval) -> SessionRecord {
    var r = rec(.recording)
    r.resumeInfo = RecorderResumeInfo(startTime: now.addingTimeInterval(-s), existingFiles: [])
    return r
}

// Allowed transitions
check(canTransition(from: .recording, to: .awaitingDecision), "recording -> awaitingDecision")
check(canTransition(from: .recording, to: .failed), "recording -> failed")
check(canTransition(from: .recording, to: .discarded), "recording -> discarded (abandoned by a new tel: link)")
check(canTransition(from: .awaitingDecision, to: .uploading), "awaitingDecision -> uploading")
check(canTransition(from: .awaitingDecision, to: .loggingNNO), "awaitingDecision -> loggingNNO")
check(canTransition(from: .awaitingDecision, to: .discarded), "awaitingDecision -> discarded")
check(canTransition(from: .uploading, to: .transcribing), "uploading -> transcribing")
check(canTransition(from: .uploading, to: .done), "uploading -> done")
check(canTransition(from: .uploading, to: .failed), "uploading -> failed")
check(canTransition(from: .transcribing, to: .logging), "transcribing -> logging")
check(canTransition(from: .transcribing, to: .done), "transcribing -> done")
check(canTransition(from: .transcribing, to: .failed), "transcribing -> failed")
check(canTransition(from: .logging, to: .done), "logging -> done")
check(canTransition(from: .logging, to: .failed), "logging -> failed")
check(canTransition(from: .loggingNNO, to: .done), "loggingNNO -> done")
check(canTransition(from: .loggingNNO, to: .failed), "loggingNNO -> failed")
check(canTransition(from: .failed, to: .uploading), "failed -> uploading (retry)")
check(canTransition(from: .failed, to: .loggingNNO), "failed -> loggingNNO (retry NNO)")

// Same-stage progress updates on non-terminal stages
check(canTransition(from: .recording, to: .recording), "recording -> recording")
check(canTransition(from: .awaitingDecision, to: .awaitingDecision), "awaitingDecision -> awaitingDecision")
check(canTransition(from: .uploading, to: .uploading), "canTransition(from: .uploading, to: .uploading)")
check(canTransition(from: .transcribing, to: .transcribing), "transcribing -> transcribing")
check(canTransition(from: .logging, to: .logging), "logging -> logging")
check(canTransition(from: .loggingNNO, to: .loggingNNO), "loggingNNO -> loggingNNO")

// Forbidden transitions
check(!canTransition(from: .done, to: .uploading), "done -/-> uploading")
check(!canTransition(from: .discarded, to: .uploading), "discarded -/-> uploading")
check(!canTransition(from: .recording, to: .uploading), "recording -/-> uploading")
check(!canTransition(from: .done, to: .failed), "done -/-> failed")
check(!canTransition(from: .done, to: .done), "done -/-> done")
check(!canTransition(from: .failed, to: .failed), "failed -/-> failed")
check(!canTransition(from: .discarded, to: .discarded), "discarded -/-> discarded")

// Resume actions (D-01, D-02)
check(resumeAction(for: recording(startedSecondsAgo: 60), now: now) == .reattachRecorder, "resume recording -> reattachRecorder")
check(resumeAction(for: rec(.awaitingDecision), now: now) == .showSaveDialog, "resume awaitingDecision -> showSaveDialog")
check(resumeAction(for: rec(.uploading), now: now) == .resendProcess, "resume uploading -> resendProcess")
check(resumeAction(for: rec(.transcribing), now: now) == .resendProcess, "resume transcribing -> resendProcess")
check(resumeAction(for: rec(.logging), now: now) == .resendProcess, "resume logging -> resendProcess")
check(resumeAction(for: rec(.loggingNNO), now: now) == .resendNNO, "resume loggingNNO -> resendNNO")
check(resumeAction(for: rec(.done), now: now) == ResumeAction.none, "resume done -> none")
check(resumeAction(for: rec(.failed), now: now) == ResumeAction.none, "resume failed -> none")
check(resumeAction(for: rec(.discarded), now: now) == ResumeAction.none, "resume discarded -> none")
check(resumeAction(for: recording(startedSecondsAgo: 7199), now: now) == .reattachRecorder, "recording 7199 seconds old -> reattachRecorder")
check(resumeAction(for: recording(startedSecondsAgo: 7201), now: now) == .abandon("timeout"), "recording 7201 seconds old -> abandon(timeout)")
check(resumeAction(for: rec(.recording), now: now) == .abandon("interrupted"), "recording without resumeInfo -> abandon(interrupted)")

// Failed list (D-04), newest first
let f1 = rec(.failed, created: -300, updated: -200)
let f2 = rec(.failed, created: -100, updated: -50)
let failedList = failedSessions([f1, rec(.done), f2, rec(.uploading)])
check(failedList.map { $0.id } == [f2.id, f1.id], "failedSessions returns failed records, newest first")
check(failedSessions([rec(.done), rec(.discarded)]).isEmpty, "failedSessions is empty without failed records")

// Reusing a session for a manually picked file
let older = rec(.failed, created: -500, audio: "/rec/a.mp3")
let newer = rec(.awaitingDecision, created: -100, audio: "/rec/a.mp3")
check(reusableSession(forAudioPath: "/rec/a.mp3", in: [older, newer])?.id == newer.id, "reusableSession picks the newest open record for the file")
check(reusableSession(forAudioPath: "/rec/a.mp3", in: [rec(.done, audio: "/rec/a.mp3")]) == nil, "reusableSession ignores a done record")
check(reusableSession(forAudioPath: "/rec/a.mp3", in: [rec(.discarded, audio: "/rec/a.mp3")]) == nil, "reusableSession ignores a discarded record")
check(reusableSession(forAudioPath: "/rec/b.mp3", in: [older, newer]) == nil, "reusableSession needs the same audioPath")

// Backend stage mapping (GET /sessions/{client_ref})
check(stageForBackend(stage: "unknown", step: nil) == nil, "backend unknown -> nil")
check(stageForBackend(stage: "processing", step: "saving_to_salesforce") == .logging, "backend processing/saving_to_salesforce -> logging")
check(stageForBackend(stage: "processing", step: "transcribing") == .transcribing, "backend processing/transcribing -> transcribing")
check(stageForBackend(stage: "processing", step: nil) == .transcribing, "backend processing without step -> transcribing")
check(stageForBackend(stage: "done", step: nil) == .done, "backend done -> done")
check(stageForBackend(stage: "failed", step: "transcribing") == .failed, "backend failed -> failed")

// Stage after POST /process or POST /log-nno answered
check(stageAfterSubmit(httpStatus: 200, bodyStatus: "duplicate", nno: false) == .done, "process 200/duplicate -> done")
check(stageAfterSubmit(httpStatus: 200, bodyStatus: "processing", nno: false) == .transcribing, "process 200/processing -> transcribing")
check(stageAfterSubmit(httpStatus: 500, bodyStatus: nil, nno: false) == .failed, "process 500 -> failed")
check(stageAfterSubmit(httpStatus: 409, bodyStatus: nil, nno: false) == .failed, "process 409 -> failed")
check(stageAfterSubmit(httpStatus: nil, bodyStatus: nil, nno: false) == .failed, "process transport error (nil) -> failed")
check(stageAfterSubmit(httpStatus: 200, bodyStatus: "ok", nno: true) == .done, "NNO 200 -> done")
check(stageAfterSubmit(httpStatus: 409, bodyStatus: nil, nno: true) == .loggingNNO, "NNO 409 -> loggingNNO (still running on the backend)")
check(stageAfterSubmit(httpStatus: 500, bodyStatus: nil, nno: true) == .failed, "NNO 500 -> failed")
check(stageAfterSubmit(httpStatus: nil, bodyStatus: nil, nno: true) == .failed, "NNO transport error (nil) -> failed")

// Retry stage and the wasNNO field
var nno = rec(.failed)
nno.wasNNO = true
check(retryStage(for: nno) == .loggingNNO, "retryStage for a failed NNO -> loggingNNO")
check(retryStage(for: rec(.failed)) == .uploading, "retryStage for a failed call -> uploading")
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
var legacy = (try? JSONSerialization.jsonObject(with: try! encoder.encode(rec(.done)))) as? [String: Any] ?? [:]
legacy.removeValue(forKey: "wasNNO")
let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
check((try? decoder.decode(SessionRecord.self, from: legacyData))?.wasNNO == false, "record without wasNNO decodes with wasNNO false")

// Retention (D-03)
let week: TimeInterval = 7 * 24 * 3600
check(sessionRetention == week, "retention is 7 days")
let doneOld = rec(.done, updated: -(week + 1))
let doneNew = rec(.done, updated: -(week - 1))
check(sessionsToPrune([doneOld], now: now).count == 1, "done updated 7 days + 1 s ago is pruned")
check(sessionsToPrune([doneNew], now: now).isEmpty, "done updated 7 days - 1 s ago is kept")
check(sessionsToPrune([rec(.failed, updated: -(week + 1))], now: now).count == 1, "failed past 7 days is pruned")
check(sessionsToPrune([rec(.failed, updated: -(week - 1))], now: now).isEmpty, "failed within 7 days is kept")
check(sessionsToPrune([rec(.discarded, updated: -(week + 1))], now: now).count == 1, "discarded past 7 days is pruned")
check(sessionsToPrune([rec(.discarded, updated: -(week - 1))], now: now).isEmpty, "discarded within 7 days is kept")
let month: TimeInterval = 30 * 24 * 3600
let stuckRecording = rec(.recording, updated: -month)
let stuckUpload = rec(.uploading, updated: -month)
check(sessionsToPrune([stuckRecording, stuckUpload], now: now).isEmpty, "recording/uploading 30 days old is never pruned")
check(staleNonTerminal([stuckUpload], now: now).map { $0.id } == [stuckUpload.id], "uploading 30 days old is reported as stale")
check(staleNonTerminal([stuckRecording], now: now).isEmpty, "a stale recording is left to resumeAction, not reported")
check(staleNonTerminal([rec(.uploading, updated: -(week - 1))], now: now).isEmpty, "uploading within 7 days is not stale")
check(staleNonTerminal([doneOld], now: now).isEmpty, "terminal records are never stale")

// Resume notification text (D-01)
var named = rec(.uploading)
named.contactName = "Jan Jansen"
check(resumeNotificationText(for: named) == "Gesprek met Jan Jansen wordt alsnog verwerkt", "resumeNotificationText uses the contact name")
var unnamed = rec(.uploading)
unnamed.contactName = ""
check(resumeNotificationText(for: unnamed) == "Gesprek met +31612345678 wordt alsnog verwerkt", "resumeNotificationText falls back to the phone number")
var nnoResume = rec(.loggingNNO)
nnoResume.wasNNO = true
nnoResume.contactName = "Jan Jansen"
check(resumeNotificationText(for: nnoResume) == "NNO voor Jan Jansen wordt alsnog gelogd", "resumeNotificationText for an NNO session")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
