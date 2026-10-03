import Cocoa
import Foundation

// MARK: - Backend Supervisor

class BackendSupervisor {
    // All mutable state below is owned by `queue`. Entry points hop onto it, so the
    // termination handler, restart timers, health polls and menu-triggered self-heal
    // can no longer race each other (which used to double-spawn backends and make
    // them kill each other's port in a loop).
    private let queue = DispatchQueue(label: "com.welisa.CallBridge.supervisor")
    private var process: Process?
    private var generation = 0            // bumped per spawn; stale callbacks compare against it
    private var restartCount: Int = 0
    private var isStopping: Bool = false  // sticky once the app quits
    private var hasStarted: Bool = false  // start() was called (credential gate passed)
    private var reloadRequested = false
    private var pendingRestart: DispatchWorkItem?
    private var spawnTime: Date = Date()
    private var healthFailures = 0
    private var healthCheckInFlight = false
    private var portConflictNotified = false
    private var generationBecameHealthy = false
    private let supportDir: String
    private let logsDir: String
    private let binaryName: String = "callbridge-server"

    init() {
        supportDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/com.welisa.CallBridge")
        logsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/CallBridge")
        createDirectories()
    }

    private func createDirectories() {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        debugLog("BackendSupervisor: Directories ready — support: \(supportDir), logs: \(logsDir)")
    }

    /// PyInstaller --onedir nests the executable in a folder named <binaryName>,
    /// i.e. <Resources>/callbridge-server/callbridge-server — exec the file, not the folder.
    private var binaryPath: String {
        let resourcePath = Bundle.main.resourcePath ?? ""
        return ((resourcePath as NSString).appendingPathComponent(binaryName) as NSString).appendingPathComponent(binaryName)
    }

    func start() {
        queue.async {
            guard !self.isStopping else { return }
            guard FileManager.default.isExecutableFile(atPath: self.binaryPath) else {
                debugLog("BackendSupervisor: No executable backend at \(self.binaryPath)")
                return
            }
            self.hasStarted = true
            self.spawnLocked()
        }
    }

    /// Restart the running backend so it re-reads credentials from the Keychain on
    /// spawn (used after Settings saves new creds); starts it if not yet running.
    func reloadCredentials() {
        queue.async {
            guard !self.isStopping else { return }
            if let proc = self.process, proc.isRunning {
                debugLog("BackendSupervisor: credentials changed — restarting backend")
                self.reloadRequested = true
                proc.terminate()   // termination handler respawns promptly (reloadRequested)
            } else {
                self.hasStarted = true
                self.restartCount = 0
                self.spawnLocked()
            }
        }
    }

    private func spawnLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopping else { return }
        pendingRestart?.cancel()
        pendingRestart = nil
        if let p = process, p.isRunning { return }   // never run two backends
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            debugLog("BackendSupervisor: No executable backend at \(binaryPath) — not spawning")
            return
        }
        reloadRequested = false

        generation += 1
        generationBecameHealthy = false
        let gen = generation
        spawnTime = Date()
        healthFailures = 0

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: supportDir)

        var env = ProcessInfo.processInfo.environment
        let credentialKeys = ["ASSEMBLYAI_API_KEY", "GEMINI_API_KEY",
                              "SF_USERNAME", "SF_PASSWORD", "SF_SECURITY_TOKEN", "SF_DOMAIN"]
        for key in credentialKeys {
            if let value = KeychainHelper.read(key: key) {
                env[key] = value
            }
        }
        proc.environment = env

        // Backend output goes to a log file. It used to go to Pipe()s that nobody
        // read: after ~64 KB of uvicorn access/log lines the pipe filled up, the
        // backend blocked on its next write and every endpoint hung.
        let outHandle = openBackendLog()
        proc.standardOutput = outHandle ?? FileHandle.nullDevice
        proc.standardError = outHandle ?? FileHandle.nullDevice

        proc.terminationHandler = { [weak self] terminated in
            guard let self = self else { return }
            let status = terminated.terminationStatus
            self.queue.async {
                debugLog("BackendSupervisor: Process (gen \(gen)) exited with status \(status)")
                guard gen == self.generation else { return }   // an older process — ignore
                self.process = nil
                if self.isStopping { return }

                if self.reloadRequested {
                    self.reloadRequested = false
                    self.restartCount = 0
                    self.scheduleRestartLocked(after: 0.5)
                    return
                }

                // Exiting before ever answering /health itself usually means something
                // already holds :8765 — typically an orphaned backend of ours.
                if !self.generationBecameHealthy {
                    self.reclaimPortLocked()
                }
                self.scheduleRestartLocked(after: nil)
            }
        }

        process = proc
        do {
            try proc.run()
            debugLog("BackendSupervisor: Spawned backend gen \(gen) (restart #\(restartCount))")
            pollHealth(gen: gen, attempt: 0, maxAttempts: 45)
        } catch {
            debugLog("BackendSupervisor: Failed to launch: \(error)")
            process = nil
            scheduleRestartLocked(after: nil)
        }
    }

    private func openBackendLog() -> FileHandle? {
        let path = (logsDir as NSString).appendingPathComponent("backend.log")
        let fm = FileManager.default
        // Keep it bounded: rotate once it passes 10 MB.
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64, size > 10_000_000 {
            let old = path + ".1"
            try? fm.removeItem(atPath: old)
            try? fm.moveItem(atPath: path, toPath: old)
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    private func pollHealth(gen: Int, attempt: Int, maxAttempts: Int) {
        healthCheck(timeout: 1.0) { [weak self] ok, pids in
            guard let self = self else { return }
            self.queue.async {
                guard gen == self.generation, let p = self.process, p.isRunning else { return }
                // Only *our* process counts: an orphan on :8765 also answers /health.
                let ours = pids.isEmpty || pids.contains(p.processIdentifier)
                if ok && !ours {
                    debugLog("BackendSupervisor: /health answered by another process \(pids) — not ours")
                }
                if ok && ours {
                    self.generationBecameHealthy = true
                    debugLog("BackendSupervisor: Health check OK on attempt \(attempt)")
                    self.restartCount = 0
                    self.portConflictNotified = false
                    DispatchQueue.main.async {
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.serverReachable = true
                            appDelegate.rebuildMenu()
                            appDelegate.backendBecameHealthy()
                        }
                    }
                } else if attempt < maxAttempts {
                    self.queue.asyncAfter(deadline: .now() + 1.0) {
                        self.pollHealth(gen: gen, attempt: attempt + 1, maxAttempts: maxAttempts)
                    }
                } else {
                    debugLog("BackendSupervisor: Health check timed out after \(maxAttempts)s")
                    DispatchQueue.main.async {
                        self.showNotification(title: "CallBridge", message: "Server kon niet starten")
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.serverReachable = false
                            appDelegate.rebuildMenu()
                        }
                    }
                }
            }
        }
    }

    private func scheduleRestartLocked(after fixedDelay: TimeInterval?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopping else { return }
        pendingRestart?.cancel()
        let delay = fixedDelay ?? min(3.0 * pow(2.0, Double(restartCount)), 30.0)
        restartCount += 1
        debugLog("BackendSupervisor: restart \(restartCount) scheduled in \(delay)s")
        let item = DispatchWorkItem { [weak self] in self?.spawnLocked() }
        pendingRestart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Quit: stop the backend and wait (bounded) so it doesn't outlive the app.
    /// Called on the main thread from applicationWillTerminate.
    func stop() {
        let proc: Process? = queue.sync {
            isStopping = true
            pendingRestart?.cancel()
            pendingRestart = nil
            return process
        }
        guard let proc = proc, proc.isRunning else { return }
        proc.terminate()
        debugLog("BackendSupervisor: Sent SIGTERM to backend")
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            debugLog("BackendSupervisor: Sent SIGKILL to backend (still running after 3s)")
        }
    }

    /// Self-heal, triggered when the menu can't reach the backend. Conservative on
    /// purpose — a busy or still-starting backend is never killed:
    ///  - nothing running (crashed, restart pending): spawn now;
    ///  - running: only after 3 consecutive failed health checks, and only once it
    ///    has been up for 60s, is it considered hung and restarted.
    /// Does nothing before the credential gate has started the backend. Safe from any thread.
    func ensureRunning() {
        queue.async {
            guard self.hasStarted, !self.isStopping else { return }
            guard let p = self.process, p.isRunning else {
                debugLog("BackendSupervisor: ensureRunning — no backend running, spawning now")
                self.restartCount = 0
                self.spawnLocked()
                return
            }
            guard !self.healthCheckInFlight else { return }
            self.healthCheckInFlight = true
            let gen = self.generation
            self.healthCheck(timeout: 3.0) { ok, _ in
                self.queue.async {
                    self.healthCheckInFlight = false
                    guard gen == self.generation, let p = self.process, p.isRunning else { return }
                    if ok { self.healthFailures = 0; return }
                    self.healthFailures += 1
                    let uptime = Date().timeIntervalSince(self.spawnTime)
                    debugLog("BackendSupervisor: ensureRunning — health failed (\(self.healthFailures)x, up \(Int(uptime))s)")
                    if self.healthFailures >= 3 && uptime > 60 {
                        debugLog("BackendSupervisor: backend hung — restarting")
                        self.healthFailures = 0
                        p.terminate()
                        let victim = p
                        self.queue.asyncAfter(deadline: .now() + 5) {
                            if victim.isRunning { kill(victim.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        }
    }

    /// Kill an orphaned CallBridge backend LISTENING on :8765. Only processes whose
    /// executable is a `callbridge-server` are touched — never an unrelated server
    /// (e.g. a dev uvicorn), and never the GUI's own client connection.
    private func reclaimPortLocked() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            rc=1
            for pid in $(/usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN -t); do
              case "$(/bin/ps -o comm= -p "$pid")" in
                *callbridge-server*) kill -9 "$pid" && rc=0 ;;
                *) echo "foreign listener $pid" ;;
              esac
            done
            exit $rc
            """]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        debugLog("BackendSupervisor: reclaimPort — exit \(p.terminationStatus) \(text)")
        if text.contains("foreign listener") && !portConflictNotified {
            portConflictNotified = true
            DispatchQueue.main.async {
                self.showNotification(title: "CallBridge", message: "Poort 8765 is bezet door een ander programma")
            }
        }
    }

    /// Completion: (healthy, pid/ppid reported by the responder — empty if unknown).
    private func healthCheck(timeout: TimeInterval, completion: @escaping (Bool, [Int32]) -> Void) {
        guard let url = URL(string: "http://localhost:8765/health") else { completion(false, []); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            var pids: [Int32] = []
            if ok, let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // ppid too, in case the PyInstaller bootloader runs Python as a child.
                for key in ["pid", "ppid"] { if let n = json[key] as? Int { pids.append(Int32(n)) } }
            }
            completion(ok, pids)
        }.resume()
    }

    private func showNotification(title: String, message: String) {
        let safeTitle   = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let safeMessage = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(safeMessage)\" with title \"\(safeTitle)\""
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script])
    }
}
