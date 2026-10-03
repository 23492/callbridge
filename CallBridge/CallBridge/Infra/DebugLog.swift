import Foundation

// MARK: - Debug Logging

let debugLogPath = "/tmp/callbridge_debug.log"

func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: debugLogPath) {
        FileManager.default.createFile(atPath: debugLogPath, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) else { return }
    handle.seekToEndOfFile()
    handle.write(data)
    try? handle.close()
}

/// Escape a value for an XML text node (SOAP login body). Passwords with & or <
/// otherwise produced malformed XML and every login check failed.
func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}
