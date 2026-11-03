import Foundation

// MARK: - cloudflared

/// Runs the cloudflared binary for the Cloudflare Access token in front of the DSH
/// cockpit (D-04, D-05). The token lives only in memory, at most
/// dshAccessTokenCacheLifetime seconds, and is never logged, never passed as a process
/// argument and never put in another process's environment (D-06).
final class Cloudflared {
    /// How long one `cloudflared access token` run may take before it is terminated.
    static let tokenDeadline: TimeInterval = 20

    private let queue = DispatchQueue(label: "com.welisa.CallBridge.cloudflared")
    private let lock = NSLock()
    private var cachedToken: String?
    private var fetchedAt: Date?
    private var loginCompletions: [(Bool) -> Void] = []
    private var loginInFlight = false

    /// The cloudflared binary, Homebrew paths first, then PATH (D-04); nil when not installed.
    static func locate() -> String? {
        return resolveCloudflared(
            candidates: cloudflaredCandidates(pathEnv: ProcessInfo.processInfo.environment["PATH"]),
            isExecutable: FileManager.default.isExecutableFile(atPath:))
    }

    /// The Access token for dshAccessApp. A token younger than 60 s comes from memory;
    /// otherwise cloudflared runs off the main thread with a 20 s deadline. Only a
    /// `.token` result is cached. The completion runs on a private queue.
    func accessToken(completion: @escaping (CloudflaredTokenResult) -> Void) {
        lock.lock()
        if let token = cachedToken, let at = fetchedAt, Date().timeIntervalSince(at) < dshAccessTokenCacheLifetime {
            lock.unlock()
            queue.async { completion(.token(token)) }
            return
        }
        lock.unlock()

        queue.async {
            let result = self.runTokenCommand()
            if case .token(let token) = result {
                self.lock.lock()
                self.cachedToken = token
                self.fetchedAt = Date()
                self.lock.unlock()
            }
            debugLog("Cloudflared: token result \(Cloudflared.caseName(result))")
            completion(result)
        }
    }

    /// Drops the cached token, after an "Access missing" answer and after a login.
    func invalidate() {
        lock.lock()
        cachedToken = nil
        fetchedAt = nil
        lock.unlock()
    }

    /// Runs `cloudflared access login <dshAccessApp>`; cloudflared opens the browser itself.
    /// At most one login runs: a call while one is in flight only adds its completion.
    /// Reports true for exit 0. Completions run on a private queue.
    func login(completion: @escaping (Bool) -> Void) {
        lock.lock()
        loginCompletions.append(completion)
        if loginInFlight {
            lock.unlock()
            return
        }
        loginInFlight = true
        lock.unlock()

        let finish: (Bool) -> Void = { ok in
            self.invalidate()
            self.lock.lock()
            let waiting = self.loginCompletions
            self.loginCompletions = []
            self.loginInFlight = false
            self.lock.unlock()
            for c in waiting { c(ok) }
        }

        guard let binary = Cloudflared.locate() else {
            debugLog("Cloudflared: login skipped, binary missing")
            queue.async { finish(false) }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["access", "login", dshAccessApp]
        // cloudflared prints the sign-in URL and status; nothing of it is a secret we need.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            debugLog("Cloudflared: login exit \(status)")
            self.queue.async { finish(status == 0) }
        }
        do {
            try p.run()
        } catch {
            debugLog("Cloudflared: login could not start")
            queue.async { finish(false) }
        }
    }

    // MARK: - Private

    /// One run of `cloudflared access token -app=<dshAccessApp>`, classified. Runs the
    /// binary directly (no /bin/sh); stdout holds the JWT and is never logged.
    private func runTokenCommand() -> CloudflaredTokenResult {
        guard let binary = Cloudflared.locate() else { return .missing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["access", "token", "-app=" + dshAccessApp]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do {
            try p.run()
        } catch {
            return .missing
        }

        // Drain both pipes while the process runs, so a full pipe can never block it.
        let readers = DispatchGroup()
        let outBox = PipeBox()
        let errBox = PipeBox()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(out.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + Cloudflared.tokenDeadline) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = readers.wait(timeout: .now() + 2)

        let exitCode = timedOut ? Int32(-1) : p.terminationStatus
        debugLog("Cloudflared: token exit \(exitCode)\(timedOut ? " (timeout)" : "")")
        return classifyCloudflaredToken(
            launched: true,
            exit: exitCode,
            stdout: String(data: outBox.get(), encoding: .utf8) ?? "",
            stderr: String(data: errBox.get(), encoding: .utf8) ?? "",
            timedOut: timedOut)
    }

    /// The case name only; the token itself never reaches a log line.
    static func caseName(_ result: CloudflaredTokenResult) -> String {
        switch result {
        case .token: return "token"
        case .needsLogin: return "needsLogin"
        case .unreachable: return "unreachable"
        case .missing: return "missing"
        }
    }
}

/// Bytes read from one pipe on a reader thread, handed over under a lock.
private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
