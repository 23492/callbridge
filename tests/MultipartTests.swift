// Assertions for CallBridge/CallBridge/Core/Multipart.swift and the success path of
// CallBridge/CallBridge/Core/DSHProtocol.swift, run in a temp directory.
// Run via scripts/test-core.sh.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

// A 3 MiB fixture of known bytes, larger than one 1 MiB copy chunk.
var fixture = Data(count: 3 * 1024 * 1024)
for i in 0..<fixture.count { fixture[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
let audio = dir.appendingPathComponent("call \"one\".mp3")
try? fixture.write(to: audio)

let boundary = "TESTBOUNDARY1234"
let ref = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
let fields = dshUploadFields(clientRef: ref, phoneNumber: "+31 6 1234 5678", direction: "Outbound",
                             startedAt: "2026-01-15T10:00:00+01:00", salesforceID: "003000000000001",
                             salesforceType: "Contact", scenario: "ok")
let bodyURL = dir.appendingPathComponent("body.multipart")
var written: Int64 = -1
do { written = try writeMultipartBody(fields: fields, audioPath: audio.path, mime: "audio/mpeg", boundary: boundary, to: bodyURL) }
catch { print("writeMultipartBody threw: \(error)") }
let body = (try? Data(contentsOf: bodyURL)) ?? Data()

func ranges(of needle: String, in data: Data) -> [Int] {
    let n = Data(needle.utf8)
    var out: [Int] = []
    var start = data.startIndex
    while let r = data.range(of: n, in: start..<data.endIndex) {
        out.append(r.lowerBound)
        start = r.upperBound
    }
    return out
}

// Field order and framing
check(body.starts(with: multipartFieldData(name: "client_ref", value: ref, boundary: boundary)), "body starts with the client_ref part")
let names = ["client_ref", "phone_number", "direction", "started_at", "salesforce_id", "salesforce_type", "scenario", "audio"]
let positions = names.map { ranges(of: "name=\"\($0)\"", in: body).first ?? -1 }
check(!positions.contains(-1), "every field name occurs in the body")
check(positions == positions.sorted(), "field order is client_ref .. scenario, then audio")
// Count Content-Disposition headers, not `name="`: that substring also ends `filename="`.
check(ranges(of: "Content-Disposition: form-data; name=\"", in: body).count == names.count, "exactly one part per field")

// File bytes, size, permissions
let header = multipartFileHeader(name: "audio", filename: audio.lastPathComponent, mime: "audio/mpeg", boundary: boundary)
let trailer = multipartTrailer(boundary: boundary)
let headerRange = body.range(of: header)
check(headerRange != nil, "audio header present with Content-Type audio/mpeg")
check(ranges(of: "filename=\"call _one_.mp3\"", in: body).count == 1, "quotes in the file name become _")
if let h = headerRange {
    let fileBytes = body.subdata(in: h.upperBound..<(body.endIndex - trailer.count))
    check(fileBytes == fixture, "bytes between audio header and trailer equal the fixture")
} else {
    check(false, "bytes between audio header and trailer equal the fixture")
}
check(body.suffix(trailer.count) == trailer, "body ends with the trailer")
check(written == Int64(body.count), "returned byte count equals the file size")
let attrs = (try? fm.attributesOfItem(atPath: bodyURL.path)) ?? [:]
let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? (attrs[.posixPermissions] as? Int)
check(perms == 0o600, "body file has 0600 permissions")

// Missing recording removes the partial file and throws
let missingURL = dir.appendingPathComponent("missing.multipart")
var threw = false
do { _ = try writeMultipartBody(fields: fields, audioPath: dir.appendingPathComponent("nope.mp3").path, mime: "audio/mpeg", boundary: boundary, to: missingURL) }
catch { threw = true }
check(threw, "a missing recording throws")
check(!fm.fileExists(atPath: missingURL.path), "a failed write leaves no partial body file")

// Optional fields
let bare = dshUploadFields(clientRef: ref, phoneNumber: "0612345678", direction: "Inbound", startedAt: "x",
                           salesforceID: nil, salesforceType: "Contact", scenario: nil)
check(bare.map { $0.0 } == ["client_ref", "phone_number", "direction", "started_at"], "salesforce and scenario left out when nil")
let noType = dshUploadFields(clientRef: ref, phoneNumber: "", direction: "Outbound", startedAt: "x",
                             salesforceID: "003000000000001", salesforceType: nil, scenario: nil)
check(!noType.contains { $0.0 == "salesforce_id" }, "salesforce_id is only sent together with salesforce_type")
let withScenario = dshUploadFields(clientRef: ref, phoneNumber: "1", direction: "Outbound", startedAt: "x",
                                   salesforceID: nil, salesforceType: nil, scenario: "failed")
check(withScenario.last.map { $0.0 == "scenario" && $0.1 == "failed" } ?? false, "scenario sent when set")

// Field framing is byte-identical to the old AppDelegate.multipartField
check(multipartFieldData(name: "a", value: "b", boundary: "X") == Data("--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nb\r\n".utf8), "field framing unchanged")
check(trailer == Data("\r\n--\(boundary)--\r\n".utf8), "trailer is CRLF then closing boundary")

// MIME map (D-15)
check(dshMimeType(forExtension: "m4a") == "audio/mp4", "m4a -> audio/mp4")
check(dshMimeType(forExtension: "MP3") == "audio/mpeg", "MP3 -> audio/mpeg (case-insensitive)")
check(dshMimeType(forExtension: "wav") == "audio/wav", "wav -> audio/wav")
check(dshMimeType(forExtension: "mp4") == "video/mp4", "mp4 -> video/mp4")
check(dshMimeType(forExtension: "mov") == "video/quicktime", "mov -> video/quicktime")
check(dshMimeType(forExtension: "webm") == "audio/webm", "webm -> audio/webm")
check(dshMimeType(forExtension: "aiff") == nil, "aiff -> nil")
check(dshMimeType(forExtension: "caf") == nil, "caf -> nil")

// started_at with offset (D-24)
let ams = TimeZone(identifier: "Europe/Amsterdam")!
let january = Date(timeIntervalSince1970: 1_768_471_200) // 2026-01-15T10:00:00Z
let july = Date(timeIntervalSince1970: 1_784_109_600)    // 2026-07-15T10:00:00Z
let jan = iso8601WithOffset(january, timeZone: ams)
let jul = iso8601WithOffset(july, timeZone: ams)
check(jan.hasSuffix("+01:00"), "January in Amsterdam ends with +01:00 (\(jan))")
check(jul.hasSuffix("+02:00"), "July in Amsterdam ends with +02:00 (\(jul))")
check(!jan.contains("Z") && !jul.contains("Z"), "no Z for a non-UTC zone")
check(jan == "2026-01-15T11:00:00+01:00", "January local time is shifted by the offset")

// A 202 answer decodes to a cockpit record
let accepted = Data("{\"ok\":true,\"data\":{\"id\":\"trx_1\",\"clientRef\":\"\(ref)\",\"status\":\"uploading\"},\"at\":\"2026-11-03T10:00:00.000Z\"}".utf8)
let call = decodeCockpitData(CockpitCall.self, from: accepted)
check(call?.status == "uploading", "202 record decodes with status uploading")
check(call?.clientRef == ref && call?.id == "trx_1", "202 record keeps id and clientRef")
check(classifyDSHResponse(status: 202, contentType: "application/json; charset=utf-8", location: nil, wwwAuthenticate: nil, body: accepted) == .success(accepted), "202 JSON ok -> success")

try? fm.removeItem(at: dir)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
