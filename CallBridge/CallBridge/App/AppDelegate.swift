import Cocoa
import SwiftUI
import Foundation

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    let serverURL = "http://localhost:8765"
    let phoneAppBundleID = "com.apple.mobilephone"
    let recordingsDir = NSHomeDirectory() + "/Auto Logger Recordings"

    var statusItem: NSStatusItem!
    var state: CallState = .idle
    /// Captures calls. AppDelegate only talks to the Recorder protocol (FND-03).
    lazy var recorder: Recorder = AudioHijackRecorder(recordingsDir: recordingsDir)
    var dialogWindow: NSWindow?
    var dialogAudioPath: String?
    /// Separate from dialogWindow: a call can end while the manual window is open,
    /// and one shared slot made each window's buttons close the other one.
    var manualWindow: NSWindow?
    var manualViewModel: ManualProcessViewModel?
    /// Identifies the call currently being recorded. Every async completion of the
    /// call-end detection checks it, so a restarted or finished call can never be
    /// completed twice (double dialog / double upload) or by a stale callback.
    /// It is the persisted session id (sessions/<id>.json), sent to the backend as client_ref.
    var currentCallID: UUID?
    /// One JSON record per recording session; each stage is written before its side effect (FND-04).
    /// Runs every 10 s only while a session waits on the backend.
    var sessionPollTimer: Timer?
    private var sessionPollInFlight = false
    /// Stages the poller follows. Uploading is left out on purpose: until the multipart POST
    /// arrives the backend has no ledger entry, and the upload's completion handler owns that step.
    private let polledStages: Set<SessionStage> = [.transcribing, .logging, .loggingNNO]
    lazy var sessionStore = SessionStore(directory: URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/com.welisa.CallBridge/sessions")))
    var settingsWindow: NSWindow?
    var statusTimer: Timer?
    var lastStatus: StatusResponse?
    var serverReachable: Bool = true
    var pendingBackendStart: Bool = false
    let updateChecker = UpdateChecker()
    var updateTimer: Timer?
    let backendSupervisor = BackendSupervisor()

    /// Set in applicationWillFinishLaunching when another copy is already running.
    var otherInstance: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            otherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0 != NSRunningApplication.current && !$0.isTerminated }
        }
        // Registered here (not in didFinishLaunching) so the tel: event that launched
        // the app is never missed — also when this turns out to be a duplicate.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("App launching, recordingsDir: \(recordingsDir), logPath: \(debugLogPath)")

        // Single instance: two copies (e.g. /Applications + a build folder) fought over
        // :8765 and over the tel: handler, killing each other's backend. A tel: link
        // that launched this duplicate is handed to the running instance (handleURL),
        // so give that Apple event a moment to arrive before quitting.
        if let other = otherInstance {
            debugLog("Another CallBridge instance is already running (\(other.bundleURL?.path ?? "?")) — exiting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { NSApp.terminate(nil) }
            return
        }

        // Create recordings directory
        try? FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)

        // The recorder reports the end of every session here, on the main thread.
        recorder.onFinished = { [weak self] id, result in
            DispatchQueue.main.async { self?.recorderFinished(id, result) }
        }

        // Edit menu so Cut/Copy/Paste/Select-All (⌘X/⌘C/⌘V/⌘A) work in text fields —
        // an LSUIElement (menubar-only) app has no menu bar and otherwise can't paste.
        setupMainMenu()

        // Claim the tel: handler so calls route through CallBridge (record + forward).
        claimTelHandlerIfNeeded()

        // Setup menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        // Persistent status-bar menu. Its contents are refreshed on demand via
        // menuNeedsUpdate(_:) — i.e. ONLY when the user opens it — so there is no
        // continuous background polling burning resources.
        let statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildMenu()

        // Gate backend start on credential presence check (D-05, D-06). After the
        // menu-bar icon exists, so slow Keychain prompts don't leave the app invisible.
        credentialCheckPassed { [weak self] passed in
            guard let self = self else { return }
            if passed {
                self.backendSupervisor.start()
            } else {
                self.pendingBackendStart = true
                self.showSettings()
            }
        }


        // Check for unprocessed recordings on launch
        checkForOrphanedRecordings()

        // Follow sessions that were still running on the backend when the app quit.
        scheduleSessionPolling()

        // Update check (the repo is public, so the manifest is reachable). This only
        // surfaces "⬆ Update naar vX" in the menu when a NEWER signed version exists;
        // installing always takes an explicit click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.updateChecker.checkForUpdate { self?.rebuildMenu() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.updateChecker.checkForUpdate { self?.rebuildMenu() }
        }
    }

    /// Minimal main menu with a standard Edit menu so Cut/Copy/Paste/Select-All
    /// key equivalents route to the focused text field. Without it, a menubar-only
    /// (LSUIElement) app has no Edit menu and ⌘V does nothing.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Knippen", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Kopiëren", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Plakken", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Selecteer alles", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    /// Make CallBridge the handler for `tel:` links so calls route through it (record +
    /// forward). On a clean Mac the default is FaceTime, and macOS 26 removed the UI to
    /// change it — but this programmatic claim works for a non-sandboxed app like ours.
    /// Only claims when CallBridge isn't already the default, so it won't re-prompt or
    /// fight the user's choice on every launch.
    private func claimTelHandlerIfNeeded() {
        guard let probe = URL(string: "tel:0") else { return }
        let myURL = Bundle.main.bundleURL
        // Only an installed copy may claim tel:. A build-folder, worktree or
        // translocated (quarantined, run from Downloads) copy would otherwise hijack
        // every call link.
        let path = myURL.standardizedFileURL.path
        let installed = path.hasPrefix("/Applications/")
            || path.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/")
        guard installed, !path.contains("/AppTranslocation/") else {
            debugLog("claimTelHandler: not claiming tel: from non-installed location \(path)")
            return
        }
        if NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL == myURL.standardizedFileURL {
            debugLog("claimTelHandler: already the default tel: handler")
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: myURL, toOpenURLsWithScheme: "tel") { error in
            if let error = error {
                debugLog("claimTelHandler: failed to set tel: handler — \(error.localizedDescription)")
            } else {
                debugLog("claimTelHandler: CallBridge is now the default tel: handler")
            }
        }
    }

    private func credentialCheckPassed(completion: @escaping (Bool) -> Void) {
        // Keychain reads can block for seconds (access prompts) — keep them off main.
        DispatchQueue.global(qos: .userInitiated).async {
            self.runCredentialCheck { passed in DispatchQueue.main.async { completion(passed) } }
        }
    }

    private func runCredentialCheck(completion: @escaping (Bool) -> Void) {
        let keys = ["ASSEMBLYAI_API_KEY", "GEMINI_API_KEY",
                    "SF_USERNAME", "SF_PASSWORD", "SF_SECURITY_TOKEN", "SF_DOMAIN"]
        guard KeychainHelper.allPresent(keys: keys) else {
            debugLog("credentialCheckPassed: missing Keychain items — showing Settings")
            completion(false)
            return
        }
        let domain = KeychainHelper.read(key: "SF_DOMAIN") ?? "login"
        guard let username = KeychainHelper.read(key: "SF_USERNAME"),
              let password = KeychainHelper.read(key: "SF_PASSWORD"),
              let token   = KeychainHelper.read(key: "SF_SECURITY_TOKEN"),
              let url = URL(string: "https://\(domain).salesforce.com/services/Soap/u/58.0") else {
            completion(false)
            return
        }
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:partner.soap.sforce.com">
          <soapenv:Body>
            <urn:login>
              <urn:username>\(xmlEscape(username))</urn:username>
              <urn:password>\(xmlEscape(password + token))</urn:password>
            </urn:login>
          </soapenv:Body>
        </soapenv:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = soapBody.data(using: .utf8)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                // Offline at login (Wi-Fi not up yet, on the train…) is not a credential
                // problem: start the backend anyway; it connects to Salesforce lazily.
                debugLog("credentialCheckPassed: SOAP error — \(error.localizedDescription) — starting anyway")
                completion(true)
                return
            }
            guard let data = data,
                  let body = String(data: data, encoding: .utf8) else {
                completion(true)
                return
            }
            let passed = body.contains("<sessionId>")
            // Only an explicit login fault means the credentials are wrong.
            let authFault = body.contains("INVALID_LOGIN") || body.contains("LOGIN_MUST_USE_SECURITY_TOKEN")
                || body.contains("INVALID_OPERATION_WITH_EXPIRED_PASSWORD")
            debugLog("credentialCheckPassed: SOAP login \(passed ? "OK" : (authFault ? "FAILED (auth)" : "FAILED (other)"))")
            completion(passed || !authFault)
        }.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        backendSupervisor.stop()
    }

    func updateStatusIcon() {
        DispatchQueue.main.async {
            switch self.state {
            case .idle:
                self.statusItem.button?.title = "📞"
            case .recording:
                self.statusItem.button?.title = "🔴"
            case .showingDialog:
                self.statusItem.button?.title = "💬"
            case .processing:
                self.statusItem.button?.title = "⏳"
            }
        }
    }

    // MARK: - Status Polling & Menu

    // MARK: - NSMenuDelegate — fetch status on demand (only when the menu opens)

    /// Called by AppKit right before the status-bar menu is displayed. The menu opens
    /// immediately with the last known status and refreshes in place once /status
    /// answers — the main thread is never blocked waiting for the backend.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        refreshStatus()
    }

    private var statusRefreshInFlight = false

    func refreshStatus() {
        guard !statusRefreshInFlight, let url = URL(string: "\(serverURL)/status") else { return }
        statusRefreshInFlight = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var fetched: StatusResponse?
            if let error = error {
                debugLog("refreshStatus error: \(error.localizedDescription)")
            } else if let data = data {
                do {
                    fetched = try JSONDecoder().decode(StatusResponse.self, from: data)
                } catch {
                    debugLog("refreshStatus decode failed: \(error)")
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusRefreshInFlight = false
                // Reachable = the server answered. A payload we can't decode is a bug,
                // not an outage — don't report "unreachable" or trigger a self-heal for it.
                let answered = error == nil && (response as? HTTPURLResponse) != nil
                self.serverReachable = answered
                if let fetched = fetched { self.lastStatus = fetched }
                if !answered {
                    self.lastStatus = nil
                    self.backendSupervisor.ensureRunning()
                }
                self.rebuildMenu()
            }
        }.resume()
    }

    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        debugLog("rebuildMenu — reachable: \(serverReachable), processing: \(lastStatus?.processing.count ?? -1), completed: \(lastStatus?.completed.count ?? -1)")

        // Header
        let header = NSMenuItem(title: "CallBridge v\(appVersion)\(UpdateChannel.current == .beta ? " · bèta" : "")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard serverReachable else {
            let item = NSMenuItem(title: "Server niet bereikbaar — probeert te herstellen…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
            let settingsItem = NSMenuItem(title: "Instellingen…", action: #selector(showSettings), keyEquivalent: "")
            settingsItem.target = self
            menu.addItem(settingsItem)
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return
        }

        let hasProcessing = !(lastStatus?.processing.isEmpty ?? true)
        let hasCompleted = !(lastStatus?.completed.isEmpty ?? true)

        if hasProcessing {
            let procHeader = NSMenuItem(title: "⏳ Verwerken", action: nil, keyEquivalent: "")
            procHeader.isEnabled = false
            menu.addItem(procHeader)

            for job in lastStatus!.processing {
                let item = NSMenuItem(title: "  \(job.contact_name) — \(job.stepLabel)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        if hasCompleted {
            for job in lastStatus!.completed {
                let contactItem = NSMenuItem(title: "  \(job.contact_name)", action: #selector(openURL(_:)), keyEquivalent: "")
                contactItem.target = self
                contactItem.representedObject = job.contactURL
                menu.addItem(contactItem)

                for ft in job.future_tasks ?? [] {
                    let taskItem = NSMenuItem(title: "    ↳ \(ft.subjectShort) — \(ft.dateFormatted)", action: #selector(openURL(_:)), keyEquivalent: "")
                    taskItem.target = self
                    taskItem.representedObject = ft.taskURL
                    menu.addItem(taskItem)
                }
            }
            menu.addItem(NSMenuItem.separator())
        }

        if !hasProcessing && !hasCompleted {
            let item = NSMenuItem(title: "Geen recente activiteit", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        // Recent recordings (collapsible submenu)
        let recentFiles = listRecentRecordings()
        let recentItem = NSMenuItem(title: "Recente opnames", action: nil, keyEquivalent: "")
        let recentSubmenu = NSMenu()

        if recentFiles.isEmpty {
            let emptyItem = NSMenuItem(title: "Geen opnames", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentSubmenu.addItem(emptyItem)
        } else {
            for file in recentFiles {
                let name = (file as NSString).lastPathComponent
                let item = NSMenuItem(title: name, action: #selector(processRecordingFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = file
                recentSubmenu.addItem(item)
            }
        }

        recentSubmenu.addItem(NSMenuItem.separator())
        let manualItem = NSMenuItem(title: "Kies bestand...", action: #selector(showManualProcessDialog), keyEquivalent: "m")
        manualItem.target = self
        recentSubmenu.addItem(manualItem)

        recentItem.submenu = recentSubmenu
        menu.addItem(recentItem)

        // Update section (the check only offers an update; installing is a click)
        if let version = updateChecker.availableVersion {
            let title = updateChecker.isReturnToStable ? "↩ Terug naar stabiel v\(version)" : "⬆ Update naar v\(version)"
            let updateItem = NSMenuItem(title: title, action: #selector(installUpdate), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        } else {
            let checkItem = NSMenuItem(title: "Zoek naar updates… (v\(appVersion))", action: #selector(checkForUpdatesManually), keyEquivalent: "u")
            checkItem.target = self
            menu.addItem(checkItem)
        }

        let settingsMenuItem = NSMenuItem(title: "Instellingen…", action: #selector(showSettings), keyEquivalent: "")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func showSettings() {
        let viewModel = SettingsViewModel()
        viewModel.onComplete = { [weak self] in
            guard let self = self else { return }
            self.settingsWindow?.close()
            self.settingsWindow = nil
            if KeychainHelper.allPresent(keys: ["ASSEMBLYAI_API_KEY", "GEMINI_API_KEY",
                                                 "SF_USERNAME", "SF_PASSWORD",
                                                 "SF_SECURITY_TOKEN", "SF_DOMAIN"]) {
                self.pendingBackendStart = false
                self.backendSupervisor.reloadCredentials()
            }
        }
        viewModel.onChannelChange = { [weak self] channel in
            guard let self = self else { return }
            self.updateChecker.checkForUpdate { [weak self] in
                guard let self = self else { return }
                self.rebuildMenu()
                if let version = self.updateChecker.availableVersion {
                    let what = self.updateChecker.isReturnToStable ? "Terug naar stabiel: v\(version)" : "Update beschikbaar: v\(version)"
                    self.showNotification(title: "CallBridge", message: "\(what) — installeer via het menu")
                } else {
                    self.showNotification(title: "CallBridge", message: "Kanaal: \(channel == .beta ? "bèta" : "stabiel"), geen update nodig")
                }
            }
        }
        let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Instellingen"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func checkForUpdatesManually() {
        updateChecker.checkForUpdate(notify: true) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc func installUpdate() {
        updateChecker.downloadAndApply()
    }

    func listRecentRecordings() -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: recordingsDir)) ?? []
        let extensions = ["mp3", "wav", "m4a", "aiff", "caf"]
        return files
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { (recordingsDir as NSString).appendingPathComponent($0) }
            .sorted { a, b in
                let dateA = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                let dateB = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                return dateA > dateB
            }
    }

    @objc func processRecordingFromMenu(_ sender: NSMenuItem) {
        guard let audioPath = sender.representedObject as? String else { return }
        showManualProcessWindow(audioPath: audioPath)
    }

    @objc func showManualProcessDialog() {
        let panel = NSOpenPanel()
        panel.title = "Kies een opname"
        panel.allowedContentTypes = [
            .mp3, .wav, .aiff, .audio
        ]
        panel.directoryURL = URL(fileURLWithPath: recordingsDir)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            showManualProcessWindow(audioPath: url.path)
        }
    }

    func showManualProcessWindow(audioPath: String) {
        dismissManualWindow()
        // A file that belongs to an unfinished session keeps that session id. A finished
        // recording picked again gets a new one; the backend's audio hash + target check
        // then blocks it only for the same Salesforce record.
        let sessionID: UUID
        if let existing = reusableSession(forAudioPath: audioPath, in: sessionStore.list()) {
            sessionID = existing.id
        } else {
            var record = SessionRecord(source: .manual, phoneNumber: "", now: Date())
            record.audioPath = audioPath
            do {
                try sessionStore.save(record)
            } catch {
                debugLog("SessionStore: save failed for \(record.id): \(error.localizedDescription)")
            }
            sessionID = record.id
        }
        let viewModel = ManualProcessViewModel(sessionID: sessionID, audioPath: audioPath, appDelegate: self)
        manualViewModel = viewModel

        let view = ManualProcessView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Handmatig Verwerken"
        window.contentView = hostingView
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        manualWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - URL Handler

    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }

        // Duplicate instance about to quit: pass the link to the running one.
        if let other = otherInstance, let otherURL = other.bundleURL, let url = URL(string: urlString) {
            debugLog("handleURL: duplicate instance — forwarding \(urlString) to \(otherURL.path)")
            NSWorkspace.shared.open([url], withApplicationAt: otherURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // Links with spaces ("tel:+31 20 123 4567") are not valid URLs as-is.
        guard let url = URL(string: urlString)
                ?? urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap({ URL(string: $0) })
        else {
            NSLog("CallBridge: Ignoring unparseable tel: URL %@", urlString)
            return
        }

        var phoneNumber = urlString
            .replacingOccurrences(of: "tel://", with: "")
            .replacingOccurrences(of: "tel:", with: "")
        phoneNumber = phoneNumber.removingPercentEncoding ?? phoneNumber
        // Drop RFC 3966 parameters such as ";phone-context=…" or ";ext=…".
        if let semi = phoneNumber.firstIndex(of: ";") { phoneNumber = String(phoneNumber[..<semi]) }

        NSLog("CallBridge: tel: URL received for %@", phoneNumber)

        // A new number while a call is being recorded means the user changed their
        // mind: abandon the current recording and restart the whole flow for the new
        // number. The call is forwarded right away (so the call dialog appears at
        // once); recording restarts after Audio Hijack has processed the stop.
        if case let .recording(previousNumber, _, previousID) = state {
            NSLog("CallBridge: New number while recording %@ — restarting flow for %@", previousNumber, phoneNumber)
            debugLog("handleURL: restart — abandoning recording for \(previousNumber), new call \(phoneNumber)")
            updateSession(previousID) {
                $0.stage = .discarded
                $0.error = "afgebroken: nieuw nummer"
            }
            recorder.stop(session: previousID)
            currentCallID = nil
            forwardCall(url: url)
            let restartID = UUID()
            currentCallID = restartID
            state = .recording(phoneNumber: phoneNumber, startTime: Date(), sessionID: restartID)
            updateStatusIcon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Another number may have been clicked in the meantime.
                guard let self = self, self.currentCallID == restartID else { return }
                self.beginRecording(phoneNumber: phoneNumber, callID: restartID)
            }
            return
        }

        forwardCall(url: url)
        beginRecording(phoneNumber: phoneNumber, callID: UUID())
    }

    /// Snapshot the recordings folder, start Audio Hijack and start polling for the
    /// end of the call. Independent of any save dialog that may still be open for a
    /// previous call — those only touch state that belongs to them.
    private func beginRecording(phoneNumber: String, callID: UUID) {
        // The record exists before Audio Hijack starts; without resumeInfo a relaunch
        // knows the app died before capture began.
        var record = SessionRecord(id: callID, source: .call, phoneNumber: phoneNumber, now: Date())
        record.recorderKind = recorder.kind
        do {
            try sessionStore.save(record)
        } catch {
            debugLog("SessionStore: save failed for \(callID): \(error.localizedDescription)")
        }
        let info = recorder.start(session: callID)
        updateSession(callID) { $0.resumeInfo = info }
        currentCallID = callID
        state = .recording(phoneNumber: phoneNumber, startTime: info.startTime, sessionID: callID)
        updateStatusIcon()
    }

    /// Outcome of a recorder session. Results for a session that is no longer the
    /// current call are dropped by the guards below and in finishRecording.
    func recorderFinished(_ id: UUID, _ result: Result<URL, RecorderError>) {
        switch result {
        case .success(let url):
            finishRecording(callID: id, audioPath: url.path)
        case .failure(.noFile):
            guard currentCallID == id else { return }
            updateSession(id) { $0.stage = .failed; $0.error = "Geen opname gevonden" }
            currentCallID = nil
            state = .idle
            updateStatusIcon()
            showNotification(title: "CallBridge", message: "Geen opname gevonden")
        case .failure(.timeout):
            guard currentCallID == id else { return }
            updateSession(id) { $0.stage = .failed; $0.error = "opname langer dan 2 uur" }
            currentCallID = nil
            state = .idle
            updateStatusIcon()
        case .failure(.startFailed(let reason)):
            guard currentCallID == id else { return }
            debugLog("recorderFinished: recorder failed to start for \(id): \(reason)")
            updateSession(id) { $0.stage = .failed; $0.error = "opname niet gestart: \(reason)" }
            currentCallID = nil
            state = .idle
            updateStatusIcon()
        }
    }

    /// Re-attaches to a recording that was running when the app died (D-02). Used on
    /// relaunch: the recorder resumes polling with the persisted start time and folder
    /// snapshot, and when the file finishes the normal onFinished → finishRecording →
    /// save dialog path runs, as if nothing happened. Never starts a new capture.
    /// No caller yet: plan 01-09 calls it from the launch resume.
    func reattachRecording(sessionID: UUID, phoneNumber: String, info: RecorderResumeInfo) {
        currentCallID = sessionID
        state = .recording(phoneNumber: phoneNumber, startTime: info.startTime, sessionID: sessionID)
        updateStatusIcon()
        recorder.resume(session: sessionID, info: info)
        debugLog("Session: re-attached to recording \(sessionID)")
    }

    /// Single exit point from .recording to the save dialog. Idempotent per call.
    /// The recorder has already stopped polling and Audio Hijack when it reports.
    private func finishRecording(callID: UUID, audioPath: String) {
        guard currentCallID == callID, case let .recording(phoneNumber, _, _) = state else { return }
        currentCallID = nil
        updateSession(callID) {
            $0.stage = .awaitingDecision
            $0.audioPath = audioPath
        }
        onRecordingComplete(sessionID: callID, phoneNumber: phoneNumber, audioPath: audioPath)
    }

    // MARK: - Sessions

    /// Loads a session, applies `change`, stamps updatedAt and saves it. Call it before
    /// the side effect the new stage describes. A transition canTransition refuses is
    /// logged but still saved: the backend is the source of truth for done.
    func updateSession(_ id: UUID, _ change: (inout SessionRecord) -> Void) {
        guard var record = sessionStore.load(id) else {
            debugLog("SessionStore: no record for \(id), update skipped")
            return
        }
        let from = record.stage
        change(&record)
        if !canTransition(from: from, to: record.stage) {
            debugLog("SessionStore: transition \(from.rawValue) -> \(record.stage.rawValue) refused by canTransition for \(id), saving anyway")
        }
        record.updatedAt = Date()
        do {
            try sessionStore.save(record)
        } catch {
            debugLog("SessionStore: save failed for \(id): \(error.localizedDescription)")
        }
        scheduleSessionPolling()
    }

    /// Starts the 10 s session poller while any session waits on the backend, and stops it
    /// when none does. No polling when nothing is in flight.
    func scheduleSessionPolling() {
        let inFlight = sessionStore.list().contains { polledStages.contains($0.stage) }
        if inFlight {
            guard sessionPollTimer == nil else { return }
            sessionPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.pollSessions()
            }
        } else {
            sessionPollTimer?.invalidate()
            sessionPollTimer = nil
        }
    }

    /// Asks GET /sessions/{client_ref} about every session in polledStages and moves it to
    /// what the backend reports. "unknown" and network errors leave the record alone
    /// (01-09 resends on relaunch).
    func pollSessions() {
        guard !sessionPollInFlight else { return }
        let records = sessionStore.list().filter { polledStages.contains($0.stage) }
        guard !records.isEmpty else {
            scheduleSessionPolling()
            return
        }
        sessionPollInFlight = true
        let group = DispatchGroup()
        for record in records {
            guard let url = URL(string: "\(serverURL)/sessions/\(record.id.uuidString)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            group.enter()
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                var fetched: SessionStatusResponse?
                if let error = error {
                    debugLog("pollSessions: \(record.id) error: \(error.localizedDescription)")
                } else if let data = data, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    do {
                        fetched = try JSONDecoder().decode(SessionStatusResponse.self, from: data)
                    } catch {
                        debugLog("pollSessions: decode failed for \(record.id): \(error)")
                    }
                }
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self = self, let fetched = fetched,
                          let mapped = stageForBackend(stage: fetched.stage, step: fetched.step),
                          let current = self.sessionStore.load(record.id),
                          self.polledStages.contains(current.stage) else { return }
                    // An NNO session only takes done or failed: it has no transcription or
                    // logging step, and the backend refuses a call/NNO kind mix with 409.
                    if current.wasNNO && mapped != .done && mapped != .failed {
                        debugLog("pollSessions: ignoring backend stage \(mapped.rawValue) for NNO session \(record.id)")
                        return
                    }
                    guard mapped != current.stage else { return }
                    self.updateSession(record.id) {
                        $0.stage = mapped
                        if mapped == .done { $0.taskID = fetched.task_id ?? $0.taskID }
                        if mapped == .failed { $0.error = fetched.error ?? "mislukt op de server" }
                    }
                }
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            self?.sessionPollInFlight = false
        }
    }

    // MARK: - Post-Recording Flow

    func onRecordingComplete(sessionID: UUID, phoneNumber: String, audioPath: String) {
        NSLog("CallBridge: Recording complete: %@", audioPath)
        state = .showingDialog(phoneNumber: phoneNumber, audioPath: audioPath)
        updateStatusIcon()

        // Look up contact
        lookupContact(phone: phoneNumber) { [weak self] contact in
            DispatchQueue.main.async {
                self?.showSaveDialog(sessionID: sessionID, phoneNumber: phoneNumber, audioPath: audioPath, contact: contact)
            }
        }
    }

    // MARK: - Server Communication

    func lookupContact(phone: String, completion: @escaping (ContactInfo?) -> Void) {
        guard let url = contactSearchURL(name: "phone", value: phone) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil,
                  let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
                  let first = response.results.first else {
                completion(nil)
                return
            }
            completion(first)
        }.resume()
    }

    /// Properly encoded query (".urlQueryAllowed" leaves & = + unescaped, so
    /// "Bakker & Zn" was split and "+31…" arrived as " 31…").
    private func contactSearchURL(name: String, value: String) -> URL? {
        var comps = URLComponents(string: "\(serverURL)/contact-search")
        comps?.queryItems = [URLQueryItem(name: name, value: value)]
        let encoded = comps?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        comps?.percentEncodedQuery = encoded
        return comps?.url
    }

    func searchContacts(query: String, completion: @escaping ([ContactInfo]) -> Void) {
        guard let url = contactSearchURL(name: "q", value: query) else {
            completion([])
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil,
                  let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
                completion([])
                return
            }
            completion(response.results)
        }.resume()
    }

    func sendToBackend(sessionID: UUID, audioPath: String, phoneNumber: String, contact: ContactInfo?, direction: String = "Outbound") {
        guard let url = URL(string: "\(serverURL)/process") else { return }
        updateSession(sessionID) {
            $0.stage = .uploading
            $0.contactID = contact?.id
            $0.contactType = contact?.type
            $0.contactName = contact?.name
            $0.direction = direction
            $0.attempts += 1
        }
        beginBackendWork()

        // Reading (possibly hundreds of MB) and building the body off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fileData = FileManager.default.contents(atPath: audioPath), !fileData.isEmpty else {
                DispatchQueue.main.async {
                    NSLog("CallBridge: Cannot read recording %@", audioPath)
                    self.updateSession(sessionID) { $0.stage = .failed; $0.error = "opname niet leesbaar" }
                    self.showNotification(title: "CallBridge", message: "Fout: opname niet leesbaar")
                    self.endBackendWork()
                }
                return
            }

            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

            var body = Data()
            body.append(Self.multipartField("phone_number", phoneNumber, boundary: boundary))
            body.append(Self.multipartField("direction", direction, boundary: boundary))
            body.append(Self.multipartField("client_ref", sessionID.uuidString, boundary: boundary))
            if let c = contact, let id = c.id {
                body.append(Self.multipartField("salesforce_id", id, boundary: boundary))
                body.append(Self.multipartField("salesforce_type", c.type, boundary: boundary))
            }
            let filename = (audioPath as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            let mime: String
            switch (audioPath as NSString).pathExtension.lowercased() {
            case "wav": mime = "audio/wav"
            case "m4a": mime = "audio/mp4"
            case "aiff": mime = "audio/aiff"
            case "caf": mime = "audio/x-caf"
            default: mime = "audio/mpeg"
            }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
                let failure = Self.backendFailure(data, response, error)
                let answer = Self.submitAnswer(data, response, error)
                DispatchQueue.main.async {
                    let stage = stageAfterSubmit(httpStatus: answer.httpStatus, bodyStatus: answer.bodyStatus, nno: false)
                    self.updateSession(sessionID) {
                        $0.stage = stage
                        if stage == .failed { $0.error = failure ?? "onbekende fout" }
                        if stage == .done { $0.taskID = answer.taskID }
                    }
                    if let failure = failure {
                        NSLog("CallBridge: Backend error: %@", failure)
                        self.showNotification(title: "CallBridge", message: "Fout: \(failure) — opname bewaard")
                    } else {
                        NSLog("CallBridge: Sent to backend successfully")
                        self.showNotification(title: "CallBridge", message: "Opname wordt verwerkt...")
                    }
                    self.endBackendWork()
                }
            }.resume()
        }
    }

    // MARK: - Save Dialog

    func showSaveDialog(sessionID: UUID, phoneNumber: String, audioPath: String, contact: ContactInfo?) {
        dismissDialog()
        let viewModel = SaveDialogViewModel(
            sessionID: sessionID,
            phoneNumber: phoneNumber,
            audioPath: audioPath,
            initialContact: contact,
            appDelegate: self
        )

        let view = SaveRecordingView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Opname Opslaan"
        window.contentView = hostingView
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Store reference
        dialogWindow = window
        dialogAudioPath = audioPath

        // Show and activate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissDialog() {
        let window = dialogWindow
        dialogWindow = nil
        dialogAudioPath = nil
        window?.close()
    }

    func dismissManualWindow() {
        manualViewModel?.stopPlayback()
        manualViewModel = nil
        let window = manualWindow
        manualWindow = nil
        window?.close()
    }

    /// Red close button: the recording is kept on disk (reachable via "Recente
    /// opnames"); only the dialog's own state is released — never a newer call's.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === dialogWindow {
            // This window's own recording — a newer call may already be in .showingDialog.
            let audioPath = dialogAudioPath
            dialogWindow = nil
            dialogAudioPath = nil
            if let audioPath = audioPath { dialogFinished(audioPath: audioPath) }
        } else if window === manualWindow {
            manualViewModel?.stopPlayback()
            manualViewModel = nil
            manualWindow = nil
        }
    }

    /// The save dialog for `audioPath` is done. Only resets the state if it still
    /// belongs to that dialog — a new call may already be recording.
    func dialogFinished(audioPath: String) {
        if case let .showingDialog(_, current) = state, current == audioPath {
            state = .idle
            updateStatusIcon()
        }
    }

    /// Upload/NNO in flight: show ⏳ unless a call is being recorded (that state wins).
    private func beginBackendWork() {
        // Only from idle: a live recording or another open dialog keeps its state.
        if case .idle = state {
            state = .processing
            updateStatusIcon()
        }
    }

    private func endBackendWork() {
        if case .processing = state {
            state = .idle
            updateStatusIcon()
        }
    }

    /// "Niet opslaan": the session is marked discarded first, then the recording goes to
    /// the Trash at once, as before.
    func discardSession(_ sessionID: UUID, audioPath: String) {
        updateSession(sessionID) { $0.stage = .discarded }
        trashRecording(audioPath)
    }

    /// Move a recording to the Trash (recoverable) instead of deleting it outright.
    func trashRecording(_ path: String) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            NSLog("CallBridge: Recording moved to Trash: %@", path)
        } catch {
            NSLog("CallBridge: Could not trash recording %@: %@", path, error.localizedDescription)
        }
    }

    private static func multipartField(_ name: String, _ value: String, boundary: String) -> Data {
        var d = Data()
        d.append("--\(boundary)\r\n".data(using: .utf8)!)
        d.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        d.append("\(value)\r\n".data(using: .utf8)!)
        return d
    }

    /// The parts of a /process or /log-nno answer that decide the session stage:
    /// HTTP status (nil on a transport error), the body's "status" and "task_id".
    private static func submitAnswer(_ data: Data?, _ response: URLResponse?, _ error: Error?)
        -> (httpStatus: Int?, bodyStatus: String?, taskID: String?) {
        guard error == nil, let http = response as? HTTPURLResponse else { return (nil, nil, nil) }
        var bodyStatus: String?
        var taskID: String?
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            bodyStatus = json["status"] as? String
            taskID = (json["task_id"] as? String) ?? (json["nno_task_id"] as? String)
        }
        return (http.statusCode, bodyStatus, taskID)
    }

    /// Transport error or non-2xx → a human-readable failure; nil on success.
    private static func backendFailure(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> String? {
        if let error = error { return error.localizedDescription }
        guard let http = response as? HTTPURLResponse else { return "geen antwoord van server" }
        guard (200...299).contains(http.statusCode) else {
            var detail = ""
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["detail"] { detail = ": \(d)" }
            return "server gaf \(http.statusCode)\(detail)"
        }
        return nil
    }

    func sendNNO(sessionID: UUID, contact: ContactInfo, audioPath: String) {
        guard let contactId = contact.id,
              let url = URL(string: "\(serverURL)/log-nno") else { return }
        updateSession(sessionID) {
            $0.stage = .loggingNNO
            $0.wasNNO = true
            $0.contactID = contact.id
            $0.contactType = contact.type
            $0.contactName = contact.name
            $0.attempts += 1
        }
        beginBackendWork()

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append(Self.multipartField("salesforce_id", contactId, boundary: boundary))
        body.append(Self.multipartField("salesforce_type", contact.type, boundary: boundary))
        body.append(Self.multipartField("client_ref", sessionID.uuidString, boundary: boundary))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Strong self: this outlives the (already closed) dialog and its view model.
        URLSession.shared.dataTask(with: request) { data, response, error in
            let failure = Self.backendFailure(data, response, error)
            let answer = Self.submitAnswer(data, response, error)
            DispatchQueue.main.async {
                let stage = stageAfterSubmit(httpStatus: answer.httpStatus, bodyStatus: answer.bodyStatus, nno: true)
                switch stage {
                case .done:
                    self.updateSession(sessionID) { $0.stage = .done; $0.taskID = answer.taskID }
                    NSLog("CallBridge: NNO logged successfully")
                    // The recording stays on disk: sessions and their audio are kept 7 days
                    // and pruned by retention (D-03), so no Trash here.
                    self.showNotification(title: "CallBridge", message: "NNO gelogd + follow-up aangemaakt")
                case .loggingNNO:
                    // 409: the backend is still logging this NNO; the session poller resolves it.
                    NSLog("CallBridge: NNO already in progress on the backend for %@", sessionID.uuidString)
                default:
                    let message = failure ?? "onbekende fout"
                    self.updateSession(sessionID) { $0.stage = .failed; $0.error = message }
                    NSLog("CallBridge: NNO error: %@", message)
                    self.showNotification(title: "CallBridge", message: "NNO fout: \(message) — opname bewaard")
                }
                self.endBackendWork()
            }
        }.resume()
    }

    // MARK: - Utilities

    func forwardCall(url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        if let phoneAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: phoneAppBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: phoneAppURL, configuration: config)
        } else if let ftURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") {
            NSWorkspace.shared.open([url], withApplicationAt: ftURL, configuration: config)
        }
    }

    func showNotification(title: String, message: String) {
        let safeTitle   = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let safeMessage = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(safeMessage)\" with title \"\(safeTitle)\""
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script])
    }

    func checkForOrphanedRecordings() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: recordingsDir)) ?? []
        let extensions = ["mp3", "wav", "m4a", "aiff"]
        let oneHourAgo = Date().addingTimeInterval(-3600)

        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            let fullPath = (recordingsDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > oneHourAgo else { continue }

            NSLog("CallBridge: Found orphaned recording: %@", file)
            // Could show a dialog here — for now just log it
        }
    }
}
