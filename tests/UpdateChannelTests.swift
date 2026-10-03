// Assertions for the update-channel rules in CallBridge/CallBridge/Core/UpdateChannel.swift.
// Run via scripts/test-core.sh (or the scripts/test-update-channel.sh wrapper).
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}
func v(_ s: String) -> AppVersion { AppVersion(s)! }

// Parsing
check(AppVersion("2.0.8") != nil, "parses stable")
check(AppVersion("2.1.0-beta.3")?.beta == 3, "parses beta number")
for bad in ["2.0", "2.0.8.1", "v2.0.8", "2.0.8-rc.1", "2.0.8-beta", "2.0.8-beta.x", "", "2..8"] {
    check(AppVersion(bad) == nil, "rejects '\(bad)'")
}

// Ordering
check(v("2.1.0-beta.1") < v("2.1.0-beta.2"), "beta.1 < beta.2")
check(v("2.1.0-beta.9") < v("2.1.0-beta.10"), "numeric beta ordering")
check(v("2.1.0-beta.3") < v("2.1.0"), "beta < its final release")
check(v("2.0.8") < v("2.1.0-beta.1"), "older stable < newer beta")
check(v("2.0.10") > v("2.0.9"), "numeric patch ordering")
check(!(v("2.1.0") < v("2.1.0")), "equal is not less")

// Stable channel
check(decideUpdate(installed: "2.0.8", buildChannel: "stable", selected: .stable,
                   stableManifest: "2.0.9", betaManifest: nil) == .upgrade("2.0.9"),
      "stable: newer stable offered")
check(decideUpdate(installed: "2.0.8", buildChannel: "stable", selected: .stable,
                   stableManifest: "2.0.8", betaManifest: "2.1.0-beta.1") == .none,
      "stable: ignores beta manifest")
check(decideUpdate(installed: "2.0.8", buildChannel: "stable", selected: .stable,
                   stableManifest: "2.1.0-beta.1", betaManifest: nil) == .none,
      "stable: beta version leaked into main manifest is ignored")
check(decideUpdate(installed: "2.1.0-beta.2", buildChannel: "beta", selected: .stable,
                   stableManifest: "2.0.9", betaManifest: nil) == .returnToStable("2.0.9"),
      "stable selected on beta build: offer return to (older) stable")
check(decideUpdate(installed: "2.1.0-beta.2", buildChannel: "beta", selected: .stable,
                   stableManifest: "2.1.0", betaManifest: nil) == .upgrade("2.1.0"),
      "stable selected on beta build: newer stable is a normal upgrade")
check(decideUpdate(installed: "2.0.9", buildChannel: "stable", selected: .stable,
                   stableManifest: nil, betaManifest: nil) == .none,
      "stable: manifest unreachable -> nothing")

// Beta channel
check(decideUpdate(installed: "2.0.9", buildChannel: "stable", selected: .beta,
                   stableManifest: "2.0.9", betaManifest: "2.1.0-beta.1") == .upgrade("2.1.0-beta.1"),
      "beta: stable build switches to beta")
check(decideUpdate(installed: "2.1.0-beta.1", buildChannel: "beta", selected: .beta,
                   stableManifest: "2.0.9", betaManifest: "2.1.0-beta.2") == .upgrade("2.1.0-beta.2"),
      "beta: next beta offered")
check(decideUpdate(installed: "2.1.0-beta.2", buildChannel: "beta", selected: .beta,
                   stableManifest: "2.1.0", betaManifest: "2.1.0-beta.2") == .upgrade("2.1.0"),
      "beta: final release overtakes beta")
check(decideUpdate(installed: "2.1.0-beta.2", buildChannel: "beta", selected: .beta,
                   stableManifest: "2.0.9", betaManifest: "2.1.0-beta.2") == .none,
      "beta: up to date")
check(decideUpdate(installed: "2.1.0-beta.2", buildChannel: "beta", selected: .beta,
                   stableManifest: "2.0.9", betaManifest: nil) == .none,
      "beta: beta manifest unreachable never downgrades")
check(decideUpdate(installed: "2.0.9", buildChannel: "stable", selected: .beta,
                   stableManifest: "2.0.9", betaManifest: "2.0.8") == .none,
      "beta: beta branch still at older stable -> nothing")

// Channel default follows the build (appBuildChannel is "stable" in the extracted constants)
UserDefaults.standard.removeObject(forKey: UpdateChannel.defaultsKey)
check(UpdateChannel.current == UpdateChannel(rawValue: appBuildChannel), "default channel = build channel")
UpdateChannel.current = .beta
check(UpdateChannel.current == .beta, "stored choice wins")
check(UpdateChannel.beta.manifestURL.hasSuffix("/callbridge/beta/callbridge-update.json"), "beta manifest URL")
check(UpdateChannel.stable.manifestURL.hasSuffix("/callbridge/main/callbridge-update.json"), "stable manifest URL")
UserDefaults.standard.removeObject(forKey: UpdateChannel.defaultsKey)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
