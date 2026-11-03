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
func wait(_ label: String, _ start: (@escaping (DSHOutcome) -> Void) -> Void) -> DSHOutcome? {
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
    let outcome = wait("echo") { client.echo(clientToken: clientToken, completion: $0) }
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

// MARK: - Main

switch mode {
case "echo":
    runEcho()
case "all":
    runEcho()
default:
    print("FAIL unknown mode \(mode)")
    failures += 1
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
