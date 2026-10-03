import Cocoa
import Foundation

// MARK: - Audio Hijack Recorder

/// Records calls through Audio Hijack's "Voice Chat" session. The control, detection and
/// polling logic moved here unchanged from AppDelegate (FND-03): same 3 s poll, 10 s grace,
/// 2 s stability check, 5 s idle, 5 s no-file wait, 2 h timeout and .ahcommand files.
/// AppDelegate only sees the Recorder protocol and learns the outcome through onFinished.
final class AudioHijackRecorder: Recorder {

    let kind: RecorderKind = .audioHijack
    var onFinished: ((UUID, Result<URL, RecorderError>) -> Void)?

    let audioHijackSessionName = "Voice Chat"
    let recordingsDir: String
    var pollTimer: Timer?
    var stabilityCheckInFlight = false
    var noFileCheckScheduled = false
    let ahStatePath = NSTemporaryDirectory() + "callbridge_ah_state.json"

    /// The session being recorded. Every async completion of the call-end detection
    /// checks it, so a stopped or finished session can never be reported twice or by a
    /// stale callback.
    private var currentSession: UUID?
    private var startTime: Date?
    private var existingFiles: Set<String> = []

    init(recordingsDir: String) {
        self.recordingsDir = recordingsDir
    }

    // MARK: - Recorder

    func start(session: UUID) -> RecorderResumeInfo {
        // A state file from the previous call says running=false and would be read
        // on this call's first poll, ending it immediately.
        try? FileManager.default.removeItem(atPath: ahStatePath)

        let existingFiles = snapshotRecordingsFolder()
        startAudioHijack()

        let startTime = Date()
        currentSession = session
        self.startTime = startTime
        self.existingFiles = existingFiles
        stabilityCheckInFlight = false
        startPolling()
        return RecorderResumeInfo(startTime: startTime, existingFiles: existingFiles)
    }

    /// Re-attaches to a recording that was running when the app died (D-02). Uses the
    /// persisted start time and folder snapshot only: it never removes the Audio Hijack
    /// state file, never re-snapshots the folder (the in-progress file already exists and
    /// a fresh snapshot would hide it, Pitfall 6) and never starts Audio Hijack again.
    func resume(session: UUID, info: RecorderResumeInfo) {
        currentSession = session
        startTime = info.startTime
        existingFiles = info.existingFiles
        stabilityCheckInFlight = false
        startPolling()
    }

    /// Abandons the recording for this session. Idempotent: does nothing when the
    /// session is not the one being recorded.
    func stop(session: UUID) {
        guard currentSession == session else { return }
        stopPolling()
        currentSession = nil
        stopAudioHijack()
    }

    // MARK: - Audio Hijack Control

    func startAudioHijack() {
        runAudioHijackScript("app.sessionWithName(\"\(audioHijackSessionName)\").start();")
    }

    func stopAudioHijack() {
        runAudioHijackScript("app.sessionWithName(\"\(audioHijackSessionName)\").stop();")
    }

    func runAudioHijackScript(_ script: String) {
        // Unique file per command: with one shared path, a quick stop→start (or a
        // state query right after a stop) overwrote the file before Audio Hijack read
        // it, silently dropping a command.
        let tmpPath = NSTemporaryDirectory() + "callbridge_cmd_\(UUID().uuidString).ahcommand"
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            if let ahURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.rogueamoeba.audiohijack") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: tmpPath)],
                    withApplicationAt: ahURL,
                    configuration: config
                )
            }
        } catch {
            NSLog("CallBridge: Failed to run AH script: %@", error.localizedDescription)
        }
    }

    func queryAudioHijackState() {
        let script = """
        let s = app.sessionWithName("\(audioHijackSessionName)");
        let data = JSON.stringify({running: s.running, recordingCount: s.recordings.length});
        app.runShellCommand('/bin/echo \\'' + data + '\\' > \(ahStatePath)');
        """
        runAudioHijackScript(script)
    }

    // MARK: - Recording Detection

    func snapshotRecordingsFolder() -> Set<String> {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: recordingsDir)) ?? []
        return Set(files)
    }

    func findNewRecording(existingFiles: Set<String>, since startTime: Date? = nil) -> String? {
        let fm = FileManager.default
        let currentFiles = (try? fm.contentsOfDirectory(atPath: recordingsDir)) ?? []
        let extensions = ["mp3", "wav", "m4a", "aiff", "caf"]

        for file in currentFiles.sorted() {
            guard !existingFiles.contains(file) else { continue }
            let ext = (file as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            let fullPath = (recordingsDir as NSString).appendingPathComponent(file)
            // After a restart the abandoned call's file can still be finalised after
            // the snapshot; never attribute a file created before this call started.
            if let startTime = startTime,
               let created = (try? fm.attributesOfItem(atPath: fullPath))?[.creationDate] as? Date,
               created < startTime.addingTimeInterval(-2) {
                continue
            }
            return fullPath
        }
        return nil
    }

    func isFileSizeStable(_ path: String) -> Bool {
        let fm = FileManager.default
        guard let attrs1 = try? fm.attributesOfItem(atPath: path),
              let size1 = attrs1[.size] as? UInt64 else { return false }
        if size1 == 0 { return false }

        Thread.sleep(forTimeInterval: 2.0)

        guard let attrs2 = try? fm.attributesOfItem(atPath: path),
              let size2 = attrs2[.size] as? UInt64 else { return false }

        return size1 == size2
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollForCallEnd()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func pollForCallEnd() {
        guard let callID = currentSession,
              let startTime = startTime else {
            stopPolling()
            return
        }
        let existingFiles = self.existingFiles

        // Timeout after 2 hours
        if Date().timeIntervalSince(startTime) > 7200 {
            NSLog("CallBridge: Recording timeout (2h), stopping")
            stopAudioHijack()
            stopPolling()
            currentSession = nil
            onFinished?(callID, .failure(.timeout))
            return
        }

        let newFile = findNewRecording(existingFiles: existingFiles, since: startTime)

        // Audio Hijack state from the previous cycle's query. Ignored during a short
        // grace period: a cold-launching Audio Hijack can still report running=false
        // for a session it is about to start.
        var ahStopped = false
        if Date().timeIntervalSince(startTime) > 10,
           let data = FileManager.default.contents(atPath: ahStatePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let running = json["running"] as? Bool {
            ahStopped = !running
        }

        if let newFile = newFile {
            // One stability check at a time (it takes 2s, off the main thread). The
            // timer keeps running so a still-growing file is simply re-checked on the
            // next cycle; completion is guarded by callID so it can fire only once.
            if !stabilityCheckInFlight {
                stabilityCheckInFlight = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    let stable = self.isFileSizeStable(newFile)
                    DispatchQueue.main.async {
                        guard self.currentSession == callID else { return }   // call restarted/ended meanwhile
                        self.stabilityCheckInFlight = false
                        guard stable else { return }
                        // A size that holds still for 2s while Audio Hijack still reports
                        // running can be a silent stretch mid-call — only finish when the
                        // session stopped, or the file has been idle long enough.
                        if !ahStopped && !self.fileIdle(newFile, seconds: 5) { return }
                        if !ahStopped { self.stopAudioHijack() }
                        self.stopPolling()
                        self.currentSession = nil
                        debugLog("AudioHijackRecorder: recording finished for \(callID): \(newFile)")
                        self.onFinished?(callID, .success(URL(fileURLWithPath: newFile)))
                    }
                }
            }
        } else if ahStopped {
            // Session stopped but no new file yet — give Audio Hijack a moment to
            // finalise, then give up if there still is nothing.
            NSLog("CallBridge: Audio Hijack session stopped, no file yet")
            if !noFileCheckScheduled {
                noFileCheckScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self = self else { return }
                    self.noFileCheckScheduled = false
                    guard self.currentSession == callID else { return }
                    if self.findNewRecording(existingFiles: existingFiles, since: startTime) != nil {
                        return  // the regular poll will pick it up and check stability
                    }
                    NSLog("CallBridge: No recording file found after session stop")
                    self.stopPolling()
                    self.currentSession = nil
                    debugLog("AudioHijackRecorder: no recording file for \(callID)")
                    self.onFinished?(callID, .failure(.noFile))
                }
            }
        }

        // Query for next poll cycle
        queryAudioHijackState()
    }

    /// True when the file has not been modified for `seconds`.
    private func fileIdle(_ path: String, seconds: TimeInterval) -> Bool {
        guard let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mod) >= seconds
    }
}
