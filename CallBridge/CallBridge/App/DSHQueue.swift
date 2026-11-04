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

    /// Why the queue waits, or nil. Every recording is kept while paused; the menu shows
    /// pauseReason.menuTitle as one clickable line (D-21). Clearing it resets
    /// notifiedPause, so the next pause notifies once again (D-23).
    private(set) var pauseReason: DSHPauseReason? {
        didSet {
            guard pauseReason != oldValue else { return }
            debugLog("DSHQueue: pause \(pauseReason?.rawValue ?? "cleared")")
            if let reason = pauseReason {
                notifyPauseOnce(reason)
            } else {
                notifiedPause = nil
                unauthorizedToken = nil
            }
            updateHealthTimer()
            onPauseChange?(pauseReason)
        }
    }
    /// The pause reason already announced by a notification (D-23: one per pause, not one per call).
    private var notifiedPause: DSHPauseReason?
    /// The token the cockpit answered unauthorized for, kept in memory only and never
    /// logged. needsPairing clears once the Keychain holds a different token, so a revoked
    /// token does not resend on every menu open.
    private var unauthorizedToken: String?
    /// When kick() last asked cloudflared whether a needsLogin pause is still real.
    private var lastLoginCheck: Date?
    private var loginCheckInFlight = false
    /// True while "Log in bij DSH" runs cloudflared access login; a second click adds nothing.
    private var loginRunning = false
    /// GET health every 300 s, only while paused for unreachable or switchOff (D-11, D-21).
    private var healthTimer: Timer?
    private var healthInFlight = false
    static let healthProbeInterval: TimeInterval = 300
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
                if token != nil, token != self.unauthorizedToken, self.pauseReason == .needsPairing { self.pauseReason = nil }
                debugLog("DSHQueue: client token \(token == nil ? "absent" : "present")")
                then?()
            }
        }
    }

    // MARK: - Pause

    /// D-23: exactly one notification when the queue pauses for sign-in or pairing, not one
    /// per call. The other pauses only show in the menu.
    private func notifyPauseOnce(_ reason: DSHPauseReason) {
        guard reason != notifiedPause else { return }
        let message: String
        switch reason {
        case .needsLogin: message = "DSH: log in om de wachtrij te versturen"
        case .needsPairing: message = "DSH: koppel CallBridge opnieuw in Instellingen"
        case .cloudflaredMissing, .unreachable, .switchOff: return
        }
        notifiedPause = reason
        app?.showNotification(title: "CallBridge", message: message)
    }

    /// Sets the pause an outcome causes. An unauthorized answer remembers the refused token
    /// so needsPairing only clears once a new token is stored (D-07).
    private func setPause(for outcome: DSHOutcome, token: String?) {
        guard let reason = queuePauseReason(for: outcome) else { return }
        if reason == .needsPairing { unauthorizedToken = token }
        pauseReason = reason
    }

    /// While paused for needsLogin: asks cloudflared once (after invalidate) at most every
    /// 60 s whether a token is available again; a token clears the pause and resumes, so a
    /// login done in Terminal also restarts the queue.
    private func recheckLogin() {
        guard !loginCheckInFlight, !loginRunning else { return }
        let now = Date()
        if let last = lastLoginCheck, now.timeIntervalSince(last) < dshAccessTokenCacheLifetime { return }
        lastLoginCheck = now
        loginCheckInFlight = true
        cloudflared.invalidate()
        cloudflared.accessToken { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loginCheckInFlight = false
                guard case .token = result, self.pauseReason == .needsLogin else { return }
                debugLog("DSHQueue: Access token available again, resuming")
                self.pauseReason = nil
                self.kick()
                self.pollNow()
            }
        }
    }

    // MARK: - Health Probe

    /// Runs the 300 s health timer only while the queue waits on the cockpit itself
    /// (unreachable or switchOff) and stops it for every other state.
    private func updateHealthTimer() {
        let probing = pauseReason == .unreachable || pauseReason == .switchOff
        if probing {
            guard healthTimer == nil else { return }
            healthTimer = Timer.scheduledTimer(withTimeInterval: DSHQueue.healthProbeInterval, repeats: true) { [weak self] _ in
                self?.probeHealth()
            }
            debugLog("DSHQueue: health probe every \(Int(DSHQueue.healthProbeInterval)) s")
        } else if let timer = healthTimer {
            timer.invalidate()
            healthTimer = nil
        }
    }

    /// GET health while the cockpit is unreachable or switched off (D-11, D-21). A live
    /// switch clears the pause and resumes; "off" keeps switchOff; other outcomes map
    /// through pauseReason(for:). Without DSH work it clears those pauses and sends nothing.
    /// On route dsh nothing ever falls back to the local route, whatever the answer (D-11).
    func probeHealth() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app else { return }
        let records = app.sessionStore.list()
        guard hasPendingDSHWork(records) else {
            if pauseReason == .unreachable || pauseReason == .switchOff { pauseReason = nil }
            healthTimer?.invalidate()
            healthTimer = nil
            return
        }
        guard !healthInFlight, tokenLoaded, let token = clientToken else { return }
        // Ask the same target the waiting sessions use: test routes only when all of them do.
        let pending = records.filter { $0.route == .dsh && !$0.stage.isTerminal }
        let test = !pending.isEmpty && pending.allSatisfy { $0.dshTest }
        healthInFlight = true
        client.health(clientToken: token, test: test) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.healthInFlight = false
                debugLog("DSHQueue: health -> \(DSHClient.caseName(outcome))")
                switch outcome {
                case .success(let data):
                    let health = decodeCockpitData(CockpitHealth.self, from: data)
                    if health?.switch == "off" {
                        self.pauseReason = .switchOff
                    } else if health?.switch == "live" {
                        if self.pauseReason == .unreachable || self.pauseReason == .switchOff { self.pauseReason = nil }
                        self.kick()
                        self.pollNow()
                    }
                default:
                    if outcome == .accessMissing { self.lastLoginCheck = Date() }
                    self.setPause(for: outcome, token: token)
                }
            }
        }
    }

    /// "Log in bij DSH": runs `cloudflared access login` once (cloudflared opens the
    /// browser). On success the pause clears and the queue resumes by itself (D-05); a
    /// second click while a login runs does nothing extra.
    func login() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !loginRunning else { return }
        loginRunning = true
        debugLog("DSHQueue: login started")
        cloudflared.login { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loginRunning = false
                debugLog("DSHQueue: login \(ok ? "succeeded" : "failed")")
                guard ok else { return }
                self.cloudflared.invalidate()
                if self.pauseReason == .needsLogin { self.pauseReason = nil }
                self.lastLoginCheck = nil
                self.kick()
                self.pollNow()
            }
        }
    }

    // MARK: - Upload

    /// Uploads every route dsh session the cockpit has not accepted yet and whose backoff
    /// has passed; schedules a one-shot timer for the earliest one still waiting.
    /// Every local pause reason is re-checked first, so fixing its cause resumes the queue
    /// without a relaunch (D-07, D-13). Runs at launch, on pairing changes, on every menu
    /// open and after the "cloudflared ontbreekt" item; it only reads cached state and
    /// starts work async, so the menu never blocks.
    func kick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app else { return }
        // 0. No DSH work waiting (toggle off, or only local and finished sessions): no pause
        //    state and no notification, whatever pairing or cloudflared look like (D-10, D-21, D-23).
        guard hasPendingDSHWork(app.sessionStore.list()) else {
            if pauseReason != nil { pauseReason = nil }
            notifiedPause = nil
            return
        }
        // 1. Launch race: a slow Keychain read must never show "Koppel opnieuw".
        guard tokenLoaded else {
            reloadToken { [weak self] in self?.kick() }
            return
        }
        // 2. Pairing (D-07): no token pauses; a token other than the refused one clears it.
        guard let token = clientToken else {
            pauseReason = .needsPairing
            return
        }
        if pauseReason == .needsPairing {
            guard token != unauthorizedToken else { return }
            pauseReason = nil
        }
        // 3. cloudflared (D-04): installing it clears the pause at the next kick.
        guard Cloudflared.locate() != nil else {
            pauseReason = .cloudflaredMissing
            return
        }
        if pauseReason == .cloudflaredMissing { pauseReason = nil }
        // 4. Sign-in (D-05): stays until login() succeeds or cloudflared hands out a token
        //    again, for example after a login in Terminal. Asked at most every 60 s.
        if pauseReason == .needsLogin {
            recheckLogin()
            // 5. Nothing is sent and no attempt is counted while waiting for Kiran (D-13).
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
            DispatchQueue.main.async { self?.handleUpload(outcome, for: id, token: token) }
        }
    }

    private func handleUpload(_ outcome: DSHOutcome, for id: UUID, token: String) {
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
            if outcome == .accessMissing { lastLoginCheck = Date() }
            setPause(for: outcome, token: token)
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
            // D-26: a test route "done" logged nothing in Salesforce, so the real recording
            // used for the test must stay where it is.
            if keepsRecordingWhenDone(dshTest: record.dshTest) {
                debugLog("DSHQueue: \(id) done on a test route, recording kept")
            } else {
                app.trashOwnRecording(of: record)
                debugLog("DSHQueue: \(id) done, recording to the Trash")
            }
            app.updateSession(id) { $0.stage = .done }
            lastSlowPoll[id] = nil
        } else if mapped == .failed {
            // D-23: the cockpit's error, once per session.
            notifyFailureOnce(id, message: app.sessionStore.load(id)?.error ?? "Verwerking in DSH mislukt")
        }
    }

    // MARK: - Resume and Retry

    /// D-09, Pitfall 4: route dsh sessions found on launch resume here, never through
    /// pendingResumes or POST /process. Accepted ones are only polled (GET finds their
    /// state; a 404 re-uploads with the same client_ref, D-17b); unaccepted ones lose
    /// their backoff wait and go out at once.
    func resumeOnLaunch(_ ids: [UUID]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app else { return }
        for id in ids {
            guard let record = app.sessionStore.load(id), record.route == .dsh, !record.dshAccepted else { continue }
            app.updateSession(id) { $0.nextAttemptAt = nil }
        }
        debugLog("DSHQueue: resume \(ids.count) session(s) on launch")
        kick()
        schedulePolling()
        pollNow()
    }

    /// "Opnieuw proberen" on a failed route dsh session (D-12, D-17, D-17b, D-26).
    /// A session the cockpit never accepted follows the toggle at this moment through
    /// submitSession. An accepted one stays on DSH: GET calls/<client_ref> decides, a
    /// failed record gets POST retry, a 404 re-uploads with the same client_ref and a 409
    /// on retry means it is already moving, so GET again.
    func retry(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = app, let record = app.sessionStore.load(id) else { return }
        guard record.stage == .failed else {
            // A stale session listed under "Mislukt" that is still waiting: ask now.
            kick()
            pollNow()
            return
        }
        notifiedFailures.remove(id)
        guard record.dshAccepted else {
            guard let path = record.audioPath else { return }
            var contact: ContactInfo?
            if record.contactID != nil || record.contactName != nil {
                contact = ContactInfo(id: record.contactID, name: record.contactName ?? "", type: record.contactType ?? "Contact",
                                      phone: nil, account_name: nil, account_id: nil)
            }
            app.updateSession(id) {
                $0.attempts = 0
                $0.nextAttemptAt = nil
            }
            app.submitSession(sessionID: id, audioPath: path, phoneNumber: record.phoneNumber,
                              contact: contact, direction: record.direction ?? "Outbound")
            return
        }
        guard tokenLoaded else {
            reloadToken { [weak self] in self?.retry(id) }
            return
        }
        guard let token = clientToken else {
            pauseReason = .needsPairing
            return
        }
        debugLog("DSHQueue: retry \(id), asking the cockpit first")
        client.call(clientRef: id.uuidString, clientToken: token, test: record.dshTest) { [weak self] outcome in
            DispatchQueue.main.async { self?.handleRetryLookup(outcome, for: id, token: token) }
        }
    }

    /// The GET answer before a retry: failed -> POST retry, anything else is applied as is.
    private func handleRetryLookup(_ outcome: DSHOutcome, for id: UUID, token: String) {
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, current.stage == .failed else { return }
        debugLog("DSHQueue: retry lookup \(id) -> \(DSHClient.caseName(outcome))")
        switch outcome {
        case .success(let data):
            pauseReason = nil
            guard let call = decodeCockpitData(CockpitCall.self, from: data) else { return }
            if call.status == "failed" {
                client.retry(clientRef: id.uuidString, clientToken: token, test: current.dshTest) { [weak self] answer in
                    DispatchQueue.main.async { self?.handleRetryAnswer(answer, for: id, token: token) }
                }
            } else {
                reopen(id, with: call)
            }
        case .notFound:
            reupload(id)
        case .rejected(_, let message):
            app.showNotification(title: "CallBridge", message: "Fout: \(message) (opname bewaard)")
        case .conflict:
            break
        case .accessMissing, .unauthorized, .cloudflaredMissing, .switchOff, .retryable:
            if outcome == .accessMissing { lastLoginCheck = Date() }
            setPause(for: outcome, token: token)
            let title = queuePauseReason(for: outcome)?.menuTitle ?? "DSH niet bereikbaar"
            app.showNotification(title: "CallBridge", message: "Opnieuw proberen lukt nu niet: \(title)")
        }
    }

    /// The POST retry answer. A 409 conflict means the record already moves on, so it is
    /// asked once more with GET and applied (D-26 note).
    private func handleRetryAnswer(_ outcome: DSHOutcome, for id: UUID, token: String) {
        guard let app = app, let current = app.sessionStore.load(id),
              current.route == .dsh, current.stage == .failed else { return }
        debugLog("DSHQueue: retry \(id) -> \(DSHClient.caseName(outcome))")
        switch outcome {
        case .success(let data):
            pauseReason = nil
            if let call = decodeCockpitData(CockpitCall.self, from: data) {
                reopen(id, with: call)
            }
        case .conflict:
            client.call(clientRef: id.uuidString, clientToken: token, test: current.dshTest) { [weak self] answer in
                DispatchQueue.main.async {
                    guard let self = self, case .success(let data) = answer,
                          let call = decodeCockpitData(CockpitCall.self, from: data) else { return }
                    self.reopen(id, with: call)
                }
            }
        case .notFound:
            reupload(id)
        case .rejected(_, let message):
            app.showNotification(title: "CallBridge", message: "Fout: \(message) (opname bewaard)")
        case .accessMissing, .unauthorized, .cloudflaredMissing, .switchOff, .retryable:
            if outcome == .accessMissing { lastLoginCheck = Date() }
            setPause(for: outcome, token: token)
            let title = queuePauseReason(for: outcome)?.menuTitle ?? "DSH niet bereikbaar"
            app.showNotification(title: "CallBridge", message: "Opnieuw proberen lukt nu niet: \(title)")
        }
    }

    /// Moves a failed session back into a polled stage, then applies the cockpit record
    /// (apply ignores terminal sessions). canTransition allows failed -> transcribing and
    /// every stage apply can map to from there.
    private func reopen(_ id: UUID, with call: CockpitCall) {
        guard let app = app else { return }
        app.updateSession(id) {
            $0.stage = .transcribing
            $0.error = nil
        }
        apply(call, to: id)
        schedulePolling()
    }

    /// D-17b: the cockpit does not know the client_ref; upload again with the same one.
    private func reupload(_ id: UUID) {
        guard let app = app else { return }
        debugLog("DSHQueue: retry \(id) -> unknown to the cockpit, re-uploading")
        app.updateSession(id) {
            $0.dshAccepted = false
            $0.stage = .uploading
            $0.error = nil
            $0.attempts = 0
            $0.nextAttemptAt = nil
        }
        kick()
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
        // While waiting for Kiran (sign in, pair, install) a poll cannot get through;
        // kick() re-checks those causes instead.
        if let reason = pauseReason, !reason.countsAttempt { return }
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
                    self?.handlePoll(outcome, for: id, viaDuplicate: followRef != nil, token: token)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.pollInFlight = false
        }
    }

    private func handlePoll(_ outcome: DSHOutcome, for id: UUID, viaDuplicate: Bool, token: String) {
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
            if outcome == .accessMissing { lastLoginCheck = Date() }
            setPause(for: outcome, token: token)
        case .rejected, .conflict:
            debugLog("DSHQueue: poll \(id) -> \(DSHClient.caseName(outcome))")
        }
    }
}
