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

// Phase 3 DSH fields survive a round trip
var dshRecord = SessionRecord(source: .call, phoneNumber: "+31687654321", now: t0)
dshRecord.stage = .awaitingAccount
dshRecord.route = .dsh
dshRecord.dshAccepted = true
dshRecord.dshTest = true
dshRecord.nextAttemptAt = t0.addingTimeInterval(60)
dshRecord.duplicateOf = "11111111-2222-3333-4444-555555555555"
dshRecord.cockpitStep = "waiting_for_account"
try? store.save(dshRecord)
let dshLoaded = store.load(dshRecord.id)
check(dshLoaded == dshRecord, "a route dsh record with all queue fields round-trips equal")
check(dshLoaded?.route == .dsh && dshLoaded?.dshAccepted == true && dshLoaded?.dshTest == true,
      "route, dshAccepted and dshTest are stored")
check(dshLoaded?.nextAttemptAt == t0.addingTimeInterval(60), "nextAttemptAt is stored")

// A record written before Phase 3 (no DSH keys) decodes with the defaults
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
var legacy = (try? JSONSerialization.jsonObject(with: try! encoder.encode(dshRecord))) as? [String: Any] ?? [:]
for key in ["route", "dshAccepted", "dshTest", "nextAttemptAt", "duplicateOf", "cockpitStep"] {
    legacy.removeValue(forKey: key)
}
let legacyRecord = try? decoder.decode(SessionRecord.self, from: try! JSONSerialization.data(withJSONObject: legacy))
check(legacyRecord != nil, "a record without the DSH keys still decodes")
check(legacyRecord?.route == .local, "a record without route decodes as route local")
check(legacyRecord?.dshAccepted == false && legacyRecord?.dshTest == false,
      "a record without dshAccepted/dshTest decodes with both false")
check(legacyRecord?.nextAttemptAt == nil && legacyRecord?.duplicateOf == nil && legacyRecord?.cockpitStep == nil,
      "a record without the optional DSH keys decodes them as nil")
store.delete(dshRecord.id)

try? fm.removeItem(at: dir)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
