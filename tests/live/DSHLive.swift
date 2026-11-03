// Live checks of the DSH client against the cockpit test routes (D-26).
// Run via scripts/test-dsh-live.sh on the Mac; never part of scripts/test-core.sh
// (tests/live/ is outside the tests/*Tests.swift glob). Prints only route names,
// statuses and booleans, never a token.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
let clientToken = ProcessInfo.processInfo.environment["DSH_CLIENT_TOKEN"] ?? ""
let client = DSHClient(cloudflared: Cloudflared())

/// Waits for one client completion, at most 60 s; a timeout is a FAIL and gives nil.
func waitFor(_ label: String, _ start: (@escaping (DSHOutcome) -> Void) -> Void) -> DSHOutcome? {
    let done = DispatchSemaphore(value: 0)
    var result: DSHOutcome?
    start { outcome in
        result = outcome
        done.signal()
    }
    if done.wait(timeout: .now() + 60) == .timedOut {
        check(false, "\(label): answer within 60 s")
        return nil
    }
    return result
}

func successBody(_ outcome: DSHOutcome?) -> Data? {
    if case .success(let body)? = outcome { return body }
    return nil
}

// MARK: - Echo

func runEcho() {
    print("== echo")
    let outcome = waitFor("echo") { client.echo(clientToken: clientToken, completion: $0) }
    let body = successBody(outcome)
    check(body != nil, "echo: success")
    let echo = body.flatMap { decodeCockpitData(CockpitEcho.self, from: $0) }
    check(echo?.hasBearer == true, "echo: hasBearer true")
    check(echo?.hasAccessToken == true, "echo: hasAccessToken true")
    check(echo?.hasOrigin == false, "echo: hasOrigin false")
    check(echo?.hasCookie == false, "echo: hasCookie false")
    let envelopeTest = body.flatMap { try? JSONDecoder().decode(CockpitEnvelope<CockpitEcho>.self, from: $0) }?.test
    check(envelopeTest == true, "echo: envelope test true")
}

// MARK: - Fixtures and Helpers

/// A small .m4a-named file: fixed bytes plus 32 random trailing bytes, so no run hits
/// the cockpit's 24-hour sha256 duplicate rule (D-26). The test route only hashes it.
func makeFixture() -> String {
    var bytes = [UInt8](repeating: 0, count: 4096)
    for i in 0..<bytes.count { bytes[i] = UInt8(i % 251) }
    for _ in 0..<32 { bytes.append(UInt8.random(in: 0...255)) }
    let path = NSTemporaryDirectory() + "callbridge-live-\(UUID().uuidString).m4a"
    FileManager.default.createFile(atPath: path, contents: Data(bytes))
    return path
}

/// Uploads a fresh fixture to test/calls; the fixture is removed afterwards.
func upload(scenario: String, clientRef: String = UUID().uuidString) -> DSHOutcome? {
    let path = makeFixture()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let mime = dshMimeType(forExtension: (path as NSString).pathExtension) ?? "audio/mp4"
    let fields = dshUploadFields(clientRef: clientRef, phoneNumber: "+31 6 1234 5678", direction: "Outbound",
                                 startedAt: iso8601WithOffset(Date(), timeZone: .current),
                                 salesforceID: nil, salesforceType: nil, scenario: scenario)
    return waitFor("upload \(scenario)") {
        client.upload(clientToken: clientToken, test: true, fields: fields, audioPath: path, mime: mime, completion: $0)
    }
}

func record(_ outcome: DSHOutcome?) -> CockpitCall? {
    successBody(outcome).flatMap { decodeCockpitData(CockpitCall.self, from: $0) }
}

/// Calls test/calls/<ref> every 3 s, up to 45 s, until `until` holds. Returns the last
/// outcome seen (a non-success outcome ends the poll at once).
func poll(_ ref: String, until: (CockpitCall) -> Bool) -> DSHOutcome? {
    let deadline = Date().addingTimeInterval(45)
    var last: DSHOutcome?
    while Date() < deadline {
        last = waitFor("poll \(ref)") { client.call(clientRef: ref, clientToken: clientToken, test: true, completion: $0) }
        guard let call = record(last) else { return last }
        if until(call) { return last }
        Thread.sleep(forTimeInterval: 3)
    }
    return last
}

func retry(_ ref: String) -> DSHOutcome? {
    waitFor("retry \(ref)") { client.retry(clientRef: ref, clientToken: clientToken, test: true, completion: $0) }
}

/// The local stage for a record, nil when there is no record or no stage change.
func stage(_ call: CockpitCall?) -> SessionStage? {
    guard let c = call else { return nil }
    return stageForCockpit(status: c.status, step: c.step, taskId: c.taskId)
}

func isRejected(_ outcome: DSHOutcome?, code: String) -> (Bool, String) {
    if case .rejected(let c, let message)? = outcome, c == code { return (true, message) }
    return (false, "")
}

// MARK: - Scenarios

func runScenarios() {
    print("== scenarios")

    // ok: the default timeline to done with a test task id.
    let okRef = UUID().uuidString
    let okUp = record(upload(scenario: "ok", clientRef: okRef))
    check(okUp?.status == "uploading", "ok: upload success, status uploading")
    let okDone = record(poll(okRef) { $0.status == "done" || $0.status == "failed" })
    check(okDone?.status == "done", "ok: reaches done")
    check(okDone?.taskId?.hasPrefix("00T_TEST") == true, "ok: taskId starts 00T_TEST")
    check(stage(okDone) == .done, "ok: stageForCockpit done")
    check(okDone.map { shouldTrashRecording(status: $0.status, taskId: $0.taskId) } == true, "ok: shouldTrashRecording true")

    // waiting_for_account: done without a task, the recording stays.
    let wRef = UUID().uuidString
    check(record(upload(scenario: "waiting_for_account", clientRef: wRef)) != nil, "waiting_for_account: upload success")
    let wDone = record(poll(wRef) { $0.status == "done" || $0.status == "failed" })
    check(wDone?.status == "done", "waiting_for_account: reaches done")
    check(wDone?.step == "waiting_for_account", "waiting_for_account: step waiting_for_account")
    check(wDone != nil && wDone?.taskId == nil, "waiting_for_account: taskId nil")
    check(stage(wDone) == .awaitingAccount,
          "waiting_for_account: stageForCockpit awaitingAccount")
    check(wDone.map { shouldTrashRecording(status: $0.status, taskId: $0.taskId) } == false,
          "waiting_for_account: shouldTrashRecording false")

    // failed: retry resumes at transcribing and runs on to done; a second retry is 409.
    let fRef = UUID().uuidString
    check(record(upload(scenario: "failed", clientRef: fRef)) != nil, "failed: upload success")
    let fFailed = record(poll(fRef) { $0.status == "failed" || $0.status == "done" })
    check(fFailed?.status == "failed", "failed: reaches failed")
    check(fFailed?.retry == true, "failed: retry true")
    check(stage(fFailed) == .failed,
          "failed: stageForCockpit failed")
    let fRetry = record(retry(fRef))
    check(fRetry?.status == "transcribing", "failed: retry success with status transcribing")
    let fDone = record(poll(fRef) { $0.status == "done" || $0.status == "failed" })
    check(fDone?.status == "done", "failed: reaches done after retry")
    check(retry(fRef) == .conflict, "failed: retry on a non-failed record is conflict (409)")

    // salesforce_503: fails at the writing step, retry finishes it.
    let sRef = UUID().uuidString
    check(record(upload(scenario: "salesforce_503", clientRef: sRef)) != nil, "salesforce_503: upload success")
    let sFailed = record(poll(sRef) { $0.status == "failed" || $0.status == "done" })
    check(sFailed?.status == "failed", "salesforce_503: reaches failed")
    check(sFailed?.step == "writing", "salesforce_503: step writing")
    check(record(retry(sRef)) != nil, "salesforce_503: retry success")
    let sDone = record(poll(sRef) { $0.status == "done" || $0.status == "failed" })
    check(sDone?.status == "done", "salesforce_503: reaches done after retry")

    // duplicate: answered at once, no task id, stays polled (D-16b).
    let dUp = record(upload(scenario: "duplicate"))
    check(dUp?.status == "duplicate", "duplicate: upload success with status duplicate")
    check(dUp?.duplicateOf?.isEmpty == false, "duplicate: duplicateOf set")
    check(dUp != nil && stage(dUp) == nil,
          "duplicate: stageForCockpit nil")

    // too_large and bad_type: refused with the cockpit's own message.
    let tooLarge = isRejected(upload(scenario: "too_large"), code: "too_large")
    check(tooLarge.0, "too_large: rejected too_large")
    check(tooLarge.1.contains("95,0 MB"), "too_large: message names 95,0 MB")
    check(isRejected(upload(scenario: "bad_type"), code: "bad_type").0, "bad_type: rejected bad_type")

    // not_found: accepted, then unknown on every GET (the D-17b re-upload trigger).
    let nRef = UUID().uuidString
    check(record(upload(scenario: "not_found", clientRef: nRef)) != nil, "not_found: upload success")
    let nGet = waitFor("not_found get") { client.call(clientRef: nRef, clientToken: clientToken, test: true, completion: $0) }
    check(nGet == .notFound, "not_found: call gives notFound")
}

// MARK: - Resend

func runResend() {
    print("== resend")
    let ref = UUID().uuidString
    let first = record(upload(scenario: "ok", clientRef: ref))
    check(first?.id?.isEmpty == false, "resend: first upload success with an id")
    // Same client_ref, different random tail: the cockpit answers the known record (200, TRX-05).
    let second = record(upload(scenario: "ok", clientRef: ref))
    check(second != nil, "resend: second upload success")
    check(first?.id != nil && second?.id == first?.id, "resend: same record id, never a second record")
}

// MARK: - Main

switch mode {
case "echo":
    runEcho()
case "scenarios":
    runScenarios()
case "resend":
    runResend()
case "all":
    runEcho()
    runScenarios()
    runResend()
default:
    print("FAIL unknown mode \(mode)")
    failures += 1
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
