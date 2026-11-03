import Foundation

// MARK: - Multipart Framing

/// One text part of a multipart/form-data body. Byte-identical to the framing
/// AppDelegate used for the local /process upload.
func multipartFieldData(name: String, value: String, boundary: String) -> Data {
    var d = Data()
    d.append(Data("--\(boundary)\r\n".utf8))
    d.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
    d.append(Data("\(value)\r\n".utf8))
    return d
}

/// The header of the file part. A `"` in the file name would end the quoted value
/// early, so it becomes `_` (as the local upload did).
func multipartFileHeader(name: String, filename: String, mime: String, boundary: String) -> Data {
    let safe = filename.replacingOccurrences(of: "\"", with: "_")
    var d = Data()
    d.append(Data("--\(boundary)\r\n".utf8))
    d.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(safe)\"\r\n".utf8))
    d.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
    return d
}

/// The CRLF that ends the file bytes, then the closing boundary.
func multipartTrailer(boundary: String) -> Data {
    return Data("\r\n--\(boundary)--\r\n".utf8)
}

// MARK: - DSH Upload Fields

/// The text fields of `POST calls` in contract order. The cockpit decides on
/// client_ref before it reads the audio, so client_ref comes first and the audio
/// part always last. salesforce_id and salesforce_type travel together or not at
/// all (D-24); scenario only exists on the test routes (D-26).
func dshUploadFields(clientRef: String, phoneNumber: String, direction: String, startedAt: String,
                     salesforceID: String?, salesforceType: String?, scenario: String?) -> [(String, String)] {
    var fields: [(String, String)] = [
        ("client_ref", clientRef),
        ("phone_number", phoneNumber),
        ("direction", direction),
        ("started_at", startedAt),
    ]
    if let id = salesforceID, !id.isEmpty, let type = salesforceType, !type.isEmpty {
        fields.append(("salesforce_id", id))
        fields.append(("salesforce_type", type))
    }
    if let scenario = scenario {
        fields.append(("scenario", scenario))
    }
    return fields
}

// MARK: - Streamed Body Writer

/// Chunk size for copying the recording into the body file. A 2-hour call is close
/// to 100 MB, so the recording is never read into memory as a whole (D-02).
private let multipartCopyChunk = 1 << 20

/// Writes the complete multipart body to `destination` (created with 0600, because it
/// holds a copy of a customer conversation) and returns its size in bytes. The text
/// fields go first, the recording last. On any error the partial file is removed and
/// the error rethrown.
func writeMultipartBody(fields: [(String, String)], audioPath: String, mime: String, boundary: String, to destination: URL) throws -> Int64 {
    let fm = FileManager.default
    try? fm.removeItem(at: destination)
    guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    do {
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: audioPath))
        defer { try? input.close() }

        var total: Int64 = 0
        func emit(_ data: Data) throws {
            try out.write(contentsOf: data)
            total += Int64(data.count)
        }
        for (name, value) in fields {
            try emit(multipartFieldData(name: name, value: value, boundary: boundary))
        }
        let filename = (audioPath as NSString).lastPathComponent
        try emit(multipartFileHeader(name: "audio", filename: filename, mime: mime, boundary: boundary))
        while let chunk = try input.read(upToCount: multipartCopyChunk), !chunk.isEmpty {
            try emit(chunk)
        }
        try emit(multipartTrailer(boundary: boundary))
        try out.synchronize()
        return total
    } catch {
        try? fm.removeItem(at: destination)
        throw error
    }
}

// MARK: - MIME and Dates

/// MIME type for the audio types the cockpit accepts (.m4a .mp3 .wav .mp4 .mov .webm).
/// Anything else (aiff, caf, ...) is nil: such a file never leaves the Mac (D-15).
func dshMimeType(forExtension ext: String) -> String? {
    switch ext.lowercased() {
    case "m4a": return "audio/mp4"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "mp4": return "video/mp4"
    case "mov": return "video/quicktime"
    case "webm": return "audio/webm"
    default: return nil
    }
}

/// ISO 8601 with a numeric offset in the given zone, e.g. "2026-01-15T10:00:00+01:00"
/// for Europe/Amsterdam (D-24). Only a UTC zone gives "Z".
func iso8601WithOffset(_ date: Date, timeZone: TimeZone) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = timeZone
    return f.string(from: date)
}
