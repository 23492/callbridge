// Assertions for CallBridge/CallBridge/Core/SessionStore.swift, run in a temp directory.
// Run via scripts/test-core.sh.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = SessionStore(directory: dir)

// ISO 8601 stores whole seconds, so the fixtures use whole-second dates.
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
var record = SessionRecord(source: .call, phoneNumber: "+31612345678", now: t0)
record.recorderKind = .audioHijack
record.resumeInfo = RecorderResumeInfo(startTime: t0, existingFiles: ["a.mp3", "b.mp3"])
record.contactName = "Jan Jansen"
record.updatedAt = t0.addingTimeInterval(5)

// Round trip
var saved = true
do { try store.save(record) } catch { saved = false }
check(saved, "save does not throw")
check(store.load(record.id) == record, "load returns an equal record (resumeInfo and dates included)")
check(store.list().count == 1, "list returns 1 record")

// Overwrite
record.stage = .awaitingDecision
record.audioPath = "/tmp/call.mp3"
try? store.save(record)
let jsonFiles = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
check(jsonFiles.count == 1, "saving again keeps one file")
check(store.load(record.id)?.stage == .awaitingDecision, "saving again stores the new stage")

// Permissions
let path = dir.appendingPathComponent("\(record.id.uuidString).json").path
let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? (attrs[.posixPermissions] as? Int)
check(perms == 0o600, "record file has 0600 permissions")

// Unreadable files are skipped
try? Data("{}".utf8).write(to: dir.appendingPathComponent("garbage.json"))
try? Data("{".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
let listed = store.list()
check(listed.count == 1, "garbage.json and a truncated <uuid>.json are skipped")
check(listed.first?.id == record.id, "the real record is still listed")
check(store.load(UUID()) == nil, "load of an unknown id returns nil")

// Delete
store.delete(record.id)
check(store.load(record.id) == nil, "delete removes the record")
check(store.list().isEmpty, "list is empty after delete")

try? fm.removeItem(at: dir)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
