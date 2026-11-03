import Cocoa

// MARK: - DSH Queue

/// Sends route dsh sessions to the cockpit and follows them until the cockpit reports a
/// task id (TRX-01, TRX-04). Main-thread only: every session write goes through
/// AppDelegate.updateSession, network completions hop back to the main queue, and a stale
/// completion is dropped by re-loading the record and checking route and stage first.
/// Never calls the local pipeline (POST /process, /log-nno) for any session (T-03-13).
final class DSHQueue {
    weak var app: AppDelegate?
    let cloudflared = Cloudflared()
    lazy var client = DSHClient(cloudflared: cloudflared)

    /// The paired client token (Keychain DSH_CLIENT_TOKEN), cached in memory. Never logged.
    private var clientToken: String?
    private var tokenLoaded = false
    /// Sessions with an upload on the wire; kick() skips them.
    private var inFlight: Set<UUID> = []
    private var pollTimer: Timer?
    /// The interval pollTimer runs at, so schedulePolling can switch between 15 s and 300 s.
    private var pollTimerInterval: TimeInterval?
    private var pollInFlight = false

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
                debugLog("DSHQueue: client token \(token == nil ? "absent" : "present")")
                then?()
            }
        }
    }

    // MARK: - Upload

    /// Uploads every route dsh session the cockpit has not accepted yet.
    func kick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app else { return }
        guard tokenLoaded else {
            reloadToken { [weak self] in self?.kick() }
            return
        }
        for record in app.sessionStore.list()
        where record.route == .dsh && record.stage == .uploading && !record.dshAccepted && !inFlight.contains(record.id) {
            upload(record)
        }
    }

    private func upload(_ record: SessionRecord) {
        guard let path = record.audioPath, let mime = dshMimeType(forExtension: (path as NSString).pathExtension) else {
            return
        }
        guard let token = clientToken else {
            // Not paired: the session waits in the queue; 03-05 shows "Koppel opnieuw".
            debugLog("DSHQueue: \(record.id) waits, not paired")
            return
        }
        let id = record.id
        inFlight.insert(id)
        let fields = dshUploadFields(
            clientRef: id.uuidString,
            phoneNumber: record.phoneNumber,
            direction: record.direction ?? "Outbound",
            startedAt: iso8601WithOffset(record.resumeInfo?.startTime ?? record.createdAt, timeZone: .current),
            salesforceID: record.contactID,
            salesforceType: record.contactType,
            scenario: record.dshTest ? UserDefaults.standard.string(forKey: dshTestScenarioDefaultsKey) : nil)
        debugLog("DSHQueue: upload \(id) test=\(record.dshTest)")
        client.upload(clientToken: token, test: record.dshTest, fields: fields, audioPath: path, mime: mime) { [weak self] outcome in
            DispatchQueue.main.async { self?.handleUpload(outcome, for: id) }
        }
    }

    private func handleUpload(_ outcome: DSHOutcome, for id: UUID) {
        inFlight.remove(id)
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, !current.stage.isTerminal else { return }
        switch outcome {
        case .success(let data):
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
        default:
            debugLog("DSHQueue: upload \(id) -> \(DSHClient.caseName(outcome))")
        }
    }

    // MARK: - Cockpit Status

    /// Applies one cockpit record to the session: step, duplicate ref, task id, error and
    /// the mapped stage. A done or duplicate answer with a task id moves the session's own
    /// recording to the Trash, then marks it done (D-19, TRX-06).
    func apply(_ call: CockpitCall, to id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, !current.stage.isTerminal else { return }
        let mapped = stageForCockpit(status: call.status, step: call.step, taskId: call.taskId)
        let trash = shouldTrashRecording(status: call.status, taskId: call.taskId)
        app.updateSession(id) {
            $0.cockpitStep = call.step ?? call.status
            if let dup = call.duplicateOf, !dup.isEmpty { $0.duplicateOf = dup }
            if let task = call.taskId, !task.isEmpty { $0.taskID = task }
            $0.error = call.error
            if let mapped = mapped, !trash { $0.stage = mapped }
        }
        if trash, let record = app.sessionStore.load(id) {
            app.trashOwnRecording(of: record)
            app.updateSession(id) { $0.stage = .done }
            debugLog("DSHQueue: \(id) done, recording to the Trash")
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

    /// Asks GET calls/<client_ref> about every accepted route dsh session in a polled stage.
    func poll() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !pollInFlight, let app = app else { return }
        guard tokenLoaded else {
            reloadToken { [weak self] in self?.poll() }
            return
        }
        guard let token = clientToken else { return }
        let records = app.sessionStore.list().filter {
            $0.route == .dsh && $0.dshAccepted && DSHQueue.polledStages.contains($0.stage)
        }
        guard !records.isEmpty else {
            schedulePolling()
            return
        }
        pollInFlight = true
        let group = DispatchGroup()
        for record in records {
            let id = record.id
            group.enter()
            client.call(clientRef: id.uuidString, clientToken: token, test: record.dshTest) { [weak self] outcome in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    self?.handlePoll(outcome, for: id)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.pollInFlight = false
        }
    }

    private func handlePoll(_ outcome: DSHOutcome, for id: UUID) {
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, current.dshAccepted, !current.stage.isTerminal else { return }
        switch outcome {
        case .success(let data):
            if let call = decodeCockpitData(CockpitCall.self, from: data) {
                apply(call, to: id)
            }
        default:
            debugLog("DSHQueue: poll \(id) -> \(DSHClient.caseName(outcome))")
        }
    }
}
