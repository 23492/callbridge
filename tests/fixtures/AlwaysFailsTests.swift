// Negative control: exists only to prove that scripts/test-core.sh and CI fail on a failing
// assertion. Kept in tests/fixtures/ on purpose, outside the default tests/*Tests.swift glob.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

check(false, "negative control: must fail")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
