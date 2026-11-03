import Cocoa

// MARK: - DSH Queue

/// File-scope wrapper: inside DSHQueue the `pauseReason` property shadows the global
/// pauseReason(for:) from Core/DSHRules.swift.
private func queuePauseReason(for outcome: DSHOutcome) -> DSHPauseReason? {
    pauseReason(for: outcome)
}

/// Sends route dsh sessions to the cockpit and follows them until the cockpit reports a
/// task id (TRX-01, TRX-04). Main-thread only: every session write goes through
/// AppDelegate.updateSession, network completions hop back to the main queue, and a stale
/// completion is dropped by re-loading the record and checking route and stage first.
/// Never calls the local pipeline (POST /process, /log-nno) for any session (T-03-13),
/// also not when the cockpit is down (D-11).
final class DSHQueue {
    weak var app: AppDelegate?
    let cloudflared = Cloudflared()
    lazy var client = DSHClient(cloudflared: cloudflared)

    /// Why the queue waits, or nil. Every recording is kept while paused; 03-05 renders it.
    private(set) var pauseReason: DSHPauseReason? {
        didSet {
            guard pauseReason != oldValue else { return }
            debugLog("DSHQueue: pause \(pauseReason?.rawValue ?? "cleared")")
            onPauseChange?(pauseReason)
        }
    }
    /// Called on the main queue whenever pauseReason changes.
    var onPauseChange: ((DSHPauseReason?) -> Void)?

    /// The paired client token (Keychain DSH_CLIENT_TOKEN), cached in memory. Never logged.
    private var clientToken: String?
    private var tokenLoaded = false
    /// Sessions with a preflight or upload on the way; kick() skips them.
    private var inFlight: Set<UUID> = []
    private var pollTimer: Timer?
    /// The interval pollTimer runs at, so schedulePolling can switch between 15 s and 300 s.
    private var pollTimerInterval: TimeInterval?
    private var pollInFlight = false
    /// One-shot timer for the earliest nextAttemptAt (D-13 backoff).
    private var retryTimer: Timer?
    /// When each awaitingAccount session was last asked, so the 15 s timer leaves them on
    /// the slow interval (D-20).
    private var lastSlowPoll: [UUID: Date] = [:]
    /// Sessions whose failure was already shown, so later polls do not repeat it (D-23).
    private var notifiedFailures: Set<UUID> = []

    /// Stages the poller asks the cockpit about, for accepted sessions only.
    private static let polledStages: Set<SessionStage> = [.uploading, .transcribing, .logging, .awaitingAccount]

    /// Loads the client token off the main thread (Keychain reads can block on a prompt),
    /// then runs `then` on the main queue.
    func reloadToken(then: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let token = KeychainHelper.read(key: "DSH_CLIENT_TOKEN")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.clientToken = token
                self.tokenLoaded = true
                if token != nil, self.pauseReason == .needsPairing { self.pauseReason = nil }
                debugLog("DSHQueue: client token \(token == nil ? "absent" : "present")")
                then?()
            }
        }
    }

    // MARK: - Upload

    /// Uploads every route dsh session the cockpit has not accepted yet and whose backoff
    /// has passed; schedules a one-shot timer for the earliest one still waiting.
    func kick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app else { return }
        guard tokenLoaded else {
            reloadToken { [weak self] in self?.kick() }
            return
        }
        let now = Date()
        var earliest: Date?
        for record in app.sessionStore.list()
        where record.route == .dsh && record.stage == .uploading && !record.dshAccepted && !inFlight.contains(record.id) {
            if let next = record.nextAttemptAt, next > now {
                earliest = min(earliest ?? next, next)
                continue
            }
            upload(record)
        }
        retryTimer?.invalidate()
        retryTimer = nil
        if let earliest = earliest {
            retryTimer = Timer.scheduledTimer(withTimeInterval: max(1, earliest.timeIntervalSince(now)), repeats: false) { [weak self] _ in
                self?.retryTimer = nil
                self?.kick()
            }
        }
    }

    private func upload(_ record: SessionRecord) {
        let id = record.id
        guard let path = record.audioPath else {
            fail(id, message: "opname niet gevonden")
            return
        }
        guard let token = clientToken else {
            // Not paired: the session waits in the queue with its recording (D-06).
            pauseReason = .needsPairing
            debugLog("DSHQueue: \(id) waits, not paired")
            return
        }
        inFlight.insert(id)
        // D-15, D-25, Pitfall 8: type, size, empty file and target are checked before the
        // body is written. The size comes from the file system, off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: path)
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            let check = dshPreflight(path: path, sizeBytes: size, phoneNumber: record.phoneNumber,
                                     salesforceID: record.contactID)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard exists else {
                    self.inFlight.remove(id)
                    self.fail(id, message: "opname niet gevonden")
                    return
                }
                switch check {
                case .rejected(let message):
                    self.inFlight.remove(id)
                    self.fail(id, message: message)
                case .ok(let mime):
                    self.send(id: id, token: token, path: path, mime: mime)
                }
            }
        }
    }

    private func send(id: UUID, token: String, path: String, mime: String) {
        guard let app = app, let record = app.sessionStore.load(id),
              record.route == .dsh, record.stage == .uploading, !record.dshAccepted else {
            inFlight.remove(id)
            return
        }
        let fields = dshUploadFields(
            clientRef: id.uuidString,
            phoneNumber: record.phoneNumber,
            direction: record.direction ?? "Outbound",
            startedAt: iso8601WithOffset(record.resumeInfo?.startTime ?? record.createdAt, timeZone: .current),
            salesforceID: record.contactID,
            salesforceType: record.contactType,
            scenario: record.dshTest ? UserDefaults.standard.string(forKey: dshTestScenarioDefaultsKey) : nil)
        debugLog("DSHQueue: upload \(id) test=\(record.dshTest) attempt=\(record.attempts)")
        client.upload(clientToken: token, test: record.dshTest, fields: fields, audioPath: path, mime: mime) { [weak self] outcome in
            DispatchQueue.main.async { self?.handleUpload(outcome, for: id) }
        }
    }

    private func handleUpload(_ outcome: DSHOutcome, for id: UUID) {
        inFlight.remove(id)
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, !current.stage.isTerminal else { return }
        debugLog("DSHQueue: upload \(id) -> \(DSHClient.caseName(outcome))")
        switch outcome {
        case .success(let data):
            pauseReason = nil
            // D-12: from here on this session never leaves the DSH route.
            app.updateSession(id) {
                $0.dshAccepted = true
                $0.nextAttemptAt = nil
                $0.error = nil
            }
            if let call = decodeCockpitData(CockpitCall.self, from: data) {
                apply(call, to: id)
            }
            schedulePolling()
        case .rejected(_, let message):
            // D-14, D-23: the cockpit's own Dutch line, shown as is; the recording stays.
            fail(id, message: message)
        case .retryable, .switchOff, .conflict, .notFound:
            // D-11, D-13: same client_ref later, never the local route.
            if let reason = queuePauseReason(for: outcome) { pauseReason = reason }
            backOff(id)
        case .accessMissing, .unauthorized, .cloudflaredMissing:
            // Waits for Kiran (sign in, pair, install): no attempt is counted (D-13).
            pauseReason = queuePauseReason(for: outcome)
        }
    }

    /// attempts += 1 and the next try after 5 s, 30 s, then 5 min (D-13).
    private func backOff(_ id: UUID) {
        guard let app = app else { return }
        app.updateSession(id) {
            $0.attempts += 1
            $0.nextAttemptAt = Date().addingTimeInterval(dshBackoffDelay(attempt: $0.attempts))
        }
        kick()
    }

    /// Moves the session to failed with a Dutch message and keeps the recording (D-14, D-15).
    private func fail(_ id: UUID, message: String) {
        guard let app = app else { return }
        app.updateSession(id) {
            $0.stage = .failed
            $0.error = message
            $0.nextAttemptAt = nil
        }
        notifyFailureOnce(id, message: message)
    }

    private func notifyFailureOnce(_ id: UUID, message: String) {
        guard !notifiedFailures.contains(id) else { return }
        notifiedFailures.insert(id)
        app?.showNotification(title: "CallBridge", message: "Fout: \(message) (opname bewaard)")
    }

    // MARK: - Cockpit Status

    /// Applies one cockpit record to the session: step, duplicate ref, task id, error and
    /// the mapped stage. A done or duplicate answer with a task id moves the session's own
    /// recording to the Trash, then marks it done (D-19, TRX-06); done without a task id
    /// keeps it as awaitingAccount (D-20). `viaDuplicate` is true when the record is the
    /// one this session duplicates (D-16b): its own duplicateOf is then left alone.
    func apply(_ call: CockpitCall, to id: UUID, viaDuplicate: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, !current.stage.isTerminal else { return }
        let mapped = stageForCockpit(status: call.status, step: call.step, taskId: call.taskId)
        let trash = shouldTrashRecording(status: call.status, taskId: call.taskId)
        app.updateSession(id) {
            $0.cockpitStep = call.step ?? call.status
            if !viaDuplicate, let dup = call.duplicateOf, !dup.isEmpty { $0.duplicateOf = dup }
            if let task = call.taskId, !task.isEmpty { $0.taskID = task }
            $0.error = call.error
            if let mapped = mapped, !trash {
                $0.stage = mapped
                if mapped == .failed && ($0.error ?? "").isEmpty { $0.error = "Verwerking in DSH mislukt" }
            }
        }
        if trash, let record = app.sessionStore.load(id) {
            app.trashOwnRecording(of: record)
            app.updateSession(id) { $0.stage = .done }
            lastSlowPoll[id] = nil
            debugLog("DSHQueue: \(id) done, recording to the Trash")
        } else if mapped == .failed {
            // D-23: the cockpit's error, once per session.
            notifyFailureOnce(id, message: app.sessionStore.load(id)?.error ?? "Verwerking in DSH mislukt")
        }
    }

    // MARK: - Polling

    /// D-18: 15 s while an accepted session is uploading, transcribing or logging, 300 s
    /// when only awaitingAccount sessions are left, no timer otherwise. Re-creates the
    /// timer whenever the interval changes, so a new session moves a 300 s queue to 15 s.
    func schedulePolling() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app else { return }
        guard let interval = dshPollInterval(app.sessionStore.list()) else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerInterval = nil
            return
        }
        if interval == pollTimerInterval, let timer = pollTimer, timer.isValid { return }
        pollTimer?.invalidate()
        pollTimerInterval = interval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        debugLog("DSHQueue: polling every \(Int(interval)) s")
    }

    /// D-18: one poll when the menu opens. Returns at once; answers update the records later.
    func pollNow() {
        dispatchPrecondition(condition: .onQueue(.main))
        runPoll(force: true)
    }

    /// Timer tick: one poll round on the regular interval.
    func poll() {
        runPoll(force: false)
    }

    /// Asks GET calls/<client_ref> about every accepted route dsh session in a polled stage,
    /// or GET calls/<duplicateOf> for a duplicate without a task id (D-16b). awaitingAccount
    /// sessions are asked at most every 300 s unless `force` (menu open).
    private func runPoll(force: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !pollInFlight, let app = app else { return }
        guard tokenLoaded else {
            reloadToken { [weak self] in self?.runPoll(force: force) }
            return
        }
        guard let token = clientToken else { return }
        let now = Date()
        let records = app.sessionStore.list().filter { record in
            guard record.route == .dsh, record.dshAccepted, DSHQueue.polledStages.contains(record.stage) else { return false }
            if record.stage == .awaitingAccount && !force,
               let last = lastSlowPoll[record.id], now.timeIntervalSince(last) < dshSlowPollInterval - 1 {
                return false
            }
            return true
        }
        guard !records.isEmpty else {
            schedulePolling()
            return
        }
        pollInFlight = true
        let group = DispatchGroup()
        for record in records {
            let id = record.id
            if record.stage == .awaitingAccount { lastSlowPoll[id] = now }
            // D-16b: a duplicate without its own task id follows the record it duplicates.
            let followRef: String? = (record.duplicateOf?.isEmpty == false && (record.taskID ?? "").isEmpty)
                ? record.duplicateOf : nil
            group.enter()
            client.call(clientRef: followRef ?? id.uuidString, clientToken: token, test: record.dshTest) { [weak self] outcome in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    self?.handlePoll(outcome, for: id, viaDuplicate: followRef != nil)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.pollInFlight = false
        }
    }

    private func handlePoll(_ outcome: DSHOutcome, for id: UUID, viaDuplicate: Bool) {
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, current.dshAccepted, !current.stage.isTerminal else { return }
        switch outcome {
        case .success(let data):
            pauseReason = nil
            if let call = decodeCockpitData(CockpitCall.self, from: data) {
                apply(call, to: id, viaDuplicate: viaDuplicate)
            }
        case .notFound:
            if viaDuplicate {
                fail(id, message: "Dubbele opname niet gevonden in DSH")
                return
            }
            // D-17b: the cockpit lost the record; upload again with the same client_ref.
            debugLog("DSHQueue: poll \(id) -> notFound, re-uploading")
            app.updateSession(id) {
                $0.dshAccepted = false
                $0.stage = .uploading
                $0.nextAttemptAt = nil
            }
            kick()
        case .accessMissing, .unauthorized, .cloudflaredMissing, .switchOff, .retryable:
            debugLog("DSHQueue: poll \(id) -> \(DSHClient.caseName(outcome))")
            pauseReason = queuePauseReason(for: outcome)
        case .rejected, .conflict:
            debugLog("DSHQueue: poll \(id) -> \(DSHClient.caseName(outcome))")
        }
    }
}
