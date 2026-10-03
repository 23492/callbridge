import Foundation

// MARK: - Session Store

/// Keeps one JSON file per session in a directory the caller chooses
/// (the app passes ~/Library/Application Support/com.welisa.CallBridge/sessions,
/// tests pass a temp dir). Records hold phone numbers and contact names, so the
/// directory is 0700 and every file 0600. File names are built only from
/// UUID.uuidString, never from other input.
final class SessionStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes the record atomically, replacing any earlier version of the same session.
    func save(_ record: SessionRecord) throws {
        let data = try Self.makeEncoder().encode(record)
        let url = fileURL(for: record.id)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(_ id: UUID) -> SessionRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.makeDecoder().decode(SessionRecord.self, from: data)
    }

    /// Every readable record, oldest first. Files whose name is not a UUID are ignored;
    /// files that do not decode are skipped and logged, never fatal.
    func list() -> [SessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = Self.makeDecoder()
        var records: [SessionRecord] = []
        for name in names where name.hasSuffix(".json") {
            let base = String(name.dropLast(".json".count))
            guard UUID(uuidString: base) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(SessionRecord.self, from: data) else {
                debugLog("SessionStore: skipping unreadable \(name)")
                continue
            }
            records.append(record)
        }
        return records.sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes the record file only. Audio files are the caller's business (Trash, D-03).
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}
