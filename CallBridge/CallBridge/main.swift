import Cocoa
import SwiftUI
import Foundation
import CryptoKit
import AVFoundation
import Security

// MARK: - Version & Update Config

let appVersion = "2.1.0-beta.0"
/// Release channel this binary was built for ("stable" or "beta"); set by build-release.sh.
let appBuildChannel = "beta"
let updatePublicKey = "ylneUBx4bMQxiX9rsDkKtya1InBHUzlbfsEOwpvFA2E="

// MARK: - Call State Machine

enum CallState {
    case idle
    case recording(phoneNumber: String, startTime: Date, existingFiles: Set<String>)
    case showingDialog(phoneNumber: String, audioPath: String)
    case processing
}

// MARK: - Settings

class SettingsViewModel: ObservableObject {
    var onComplete: (() -> Void)?
    /// Called right after the update channel changes, so the app can re-check for updates.
    var onChannelChange: ((UpdateChannel) -> Void)?

    /// Saved immediately on toggle, independent of the credential "Opslaan" button.
    @Published var betaChannel: Bool = UpdateChannel.current == .beta {
        didSet {
            guard betaChannel != oldValue else { return }
            let channel: UpdateChannel = betaChannel ? .beta : .stable
            UpdateChannel.current = channel
            debugLog("Settings: update channel set to \(channel.rawValue)")
            onChannelChange?(channel)
        }
    }

    @Published var assemblyAIKey: String = ""
    @Published var geminiKey: String = ""
    @Published var sfUsername: String = ""
    @Published var sfPassword: String = ""
    @Published var sfSecurityToken: String = ""
    @Published var sfDomain: String = "welisa"
    @Published var validationMessage: String = ""
    @Published var isValidating: Bool = false
    @Published var isSaving: Bool = false

    init() {
        assemblyAIKey   = KeychainHelper.read(key: "ASSEMBLYAI_API_KEY") ?? ""
        geminiKey       = KeychainHelper.read(key: "GEMINI_API_KEY") ?? ""
        sfUsername      = KeychainHelper.read(key: "SF_USERNAME") ?? ""
        sfPassword      = KeychainHelper.read(key: "SF_PASSWORD") ?? ""
        sfSecurityToken = KeychainHelper.read(key: "SF_SECURITY_TOKEN") ?? ""
        sfDomain        = KeychainHelper.read(key: "SF_DOMAIN") ?? "welisa"
    }

    func validate() {
        isValidating = true
        validationMessage = ""

        // simple_salesforce builds the login URL as https://<domain>.salesforce.com/services/Soap/u/<v>
        // ('login' = production, 'test' = sandbox, otherwise a My Domain). Match it so Valideer
        // hits the same endpoint the backend will.
        let domain = sfDomain.isEmpty ? "login" : sfDomain
        guard !sfUsername.isEmpty, !sfPassword.isEmpty,
              let url = URL(string: "https://\(domain).salesforce.com/services/Soap/u/58.0") else {
            validationMessage = "Verbinding mislukt: vul minimaal gebruikersnaam en wachtwoord in"
            isValidating = false
            return
        }

        // Validate directly against Salesforce via a SOAP login (read-only, no backend needed).
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:partner.soap.sforce.com">
          <soapenv:Body>
            <urn:login>
              <urn:username>\(xmlEscape(sfUsername))</urn:username>
              <urn:password>\(xmlEscape(sfPassword + sfSecurityToken))</urn:password>
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

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isValidating = false
                if let error = error {
                    self.validationMessage = "Verbinding mislukt: \(error.localizedDescription)"
                    return
                }
                guard let data = data, let body = String(data: data, encoding: .utf8) else {
                    self.validationMessage = "Verbinding mislukt: leeg antwoord"
                    return
                }
                if body.contains("<sessionId>") {
                    self.validationMessage = "Salesforce verbinding geslaagd ✓"
                } else {
                    let fault: String
                    if let r = body.range(of: "<faultstring>"), let e = body.range(of: "</faultstring>") {
                        fault = String(body[r.upperBound..<e.lowerBound])
                    } else {
                        fault = "ongeldige inloggegevens"
                    }
                    self.validationMessage = "Verbinding mislukt: \(fault)"
                }
            }
        }.resume()
    }

    func save() {
        isSaving = true
        KeychainHelper.save(key: "ASSEMBLYAI_API_KEY", value: assemblyAIKey)
        KeychainHelper.save(key: "GEMINI_API_KEY",     value: geminiKey)
        KeychainHelper.save(key: "SF_USERNAME",        value: sfUsername)
        KeychainHelper.save(key: "SF_PASSWORD",        value: sfPassword)
        KeychainHelper.save(key: "SF_SECURITY_TOKEN",  value: sfSecurityToken)
        KeychainHelper.save(key: "SF_DOMAIN",          value: sfDomain)
        isSaving = false
        onComplete?()
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("API Keys") {
                    SecureField("AssemblyAI API key", text: $viewModel.assemblyAIKey)
                    SecureField("Gemini API key",     text: $viewModel.geminiKey)
                }
                Section("Salesforce") {
                    SecureField("Gebruikersnaam",  text: $viewModel.sfUsername)
                    SecureField("Wachtwoord",      text: $viewModel.sfPassword)
                    SecureField("Security token",  text: $viewModel.sfSecurityToken)
                }
                Section("Salesforce domein") {
                    TextField("Domein (bijv. welisa)", text: $viewModel.sfDomain)
                }
                Section("Updates") {
                    Toggle("Bètaversies ontvangen", isOn: $viewModel.betaChannel)
                    Text(viewModel.betaChannel
                         ? "Je krijgt testversies met nieuwe functies vóór collega's. Zet uit om terug te gaan naar de stabiele versie."
                         : "Je krijgt alleen stabiele versies.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Geïnstalleerd: v\(appVersion)\(appBuildChannel == "beta" ? " (bèta)" : "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            if !viewModel.validationMessage.isEmpty {
                let isError = viewModel.validationMessage.contains("mislukt") ||
                              viewModel.validationMessage.contains("bereikbaar")
                Text(viewModel.validationMessage)
                    .foregroundColor(isError ? .red : .green)
                    .font(.callout)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            HStack {
                Button("Valideer") { viewModel.validate() }
                    .disabled(viewModel.isValidating)
                Spacer()
                Button("Opslaan") { viewModel.save() }
                    .disabled(
                        viewModel.assemblyAIKey.isEmpty ||
                        viewModel.geminiKey.isEmpty ||
                        viewModel.sfUsername.isEmpty ||
                        viewModel.sfPassword.isEmpty ||
                        viewModel.sfSecurityToken.isEmpty ||
                        viewModel.sfDomain.isEmpty ||
                        viewModel.isSaving
                    )
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 700)
        .padding(.bottom)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    let serverURL = "http://localhost:8765"
    let phoneAppBundleID = "com.apple.mobilephone"
    let audioHijackSessionName = "Voice Chat"
    let recordingsDir = NSHomeDirectory() + "/Auto Logger Recordings"

    var statusItem: NSStatusItem!
    var state: CallState = .idle
    var pollTimer: Timer?
    var dialogWindow: NSWindow?
    var dialogAudioPath: String?
    /// Separate from dialogWindow: a call can end while the manual window is open,
    /// and one shared slot made each window's buttons close the other one.
    var manualWindow: NSWindow?
    var manualViewModel: ManualProcessViewModel?
    /// Identifies the call currently being recorded. Every async completion of the
    /// call-end detection checks it, so a restarted or finished call can never be
    /// completed twice (double dialog / double upload) or by a stale callback.
    var currentCallID: UUID?
    var stabilityCheckInFlight = false
    var noFileCheckScheduled = false
    let ahStatePath = NSTemporaryDirectory() + "callbridge_ah_state.json"
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
        let viewModel = ManualProcessViewModel(audioPath: audioPath, appDelegate: self)
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
        if case let .recording(previousNumber, _, _) = state {
            NSLog("CallBridge: New number while recording %@ — restarting flow for %@", previousNumber, phoneNumber)
            debugLog("handleURL: restart — abandoning recording for \(previousNumber), new call \(phoneNumber)")
            stopPolling()
            currentCallID = nil
            stopAudioHijack()
            forwardCall(url: url)
            let restartID = UUID()
            currentCallID = restartID
            state = .recording(phoneNumber: phoneNumber, startTime: Date(), existingFiles: snapshotRecordingsFolder())
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
        // A state file from the previous call says running=false and would be read
        // on this call's first poll, ending it immediately.
        try? FileManager.default.removeItem(atPath: ahStatePath)

        let existingFiles = snapshotRecordingsFolder()
        startAudioHijack()

        currentCallID = callID
        stabilityCheckInFlight = false
        state = .recording(phoneNumber: phoneNumber, startTime: Date(), existingFiles: existingFiles)
        updateStatusIcon()
        startPolling()
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
        guard case let .recording(phoneNumber, startTime, existingFiles) = state,
              let callID = currentCallID else {
            stopPolling()
            return
        }

        // Timeout after 2 hours
        if Date().timeIntervalSince(startTime) > 7200 {
            NSLog("CallBridge: Recording timeout (2h), stopping")
            stopAudioHijack()
            stopPolling()
            currentCallID = nil
            state = .idle
            updateStatusIcon()
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
                        guard self.currentCallID == callID else { return }   // call restarted/ended meanwhile
                        self.stabilityCheckInFlight = false
                        guard stable else { return }
                        // A size that holds still for 2s while Audio Hijack still reports
                        // running can be a silent stretch mid-call — only finish when the
                        // session stopped, or the file has been idle long enough.
                        if !ahStopped && !self.fileIdle(newFile, seconds: 5) { return }
                        self.finishRecording(callID: callID, phoneNumber: phoneNumber, audioPath: newFile, stopAH: !ahStopped)
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
                    guard self.currentCallID == callID else { return }
                    if self.findNewRecording(existingFiles: existingFiles, since: startTime) != nil {
                        return  // the regular poll will pick it up and check stability
                    }
                    NSLog("CallBridge: No recording file found after session stop")
                    self.stopPolling()
                    self.currentCallID = nil
                    self.state = .idle
                    self.updateStatusIcon()
                    self.showNotification(title: "CallBridge", message: "Geen opname gevonden")
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

    /// Single exit point from .recording to the save dialog. Idempotent per call.
    private func finishRecording(callID: UUID, phoneNumber: String, audioPath: String, stopAH: Bool) {
        guard currentCallID == callID, case .recording = state else { return }
        currentCallID = nil
        stopPolling()
        if stopAH { stopAudioHijack() }
        onRecordingComplete(phoneNumber: phoneNumber, audioPath: audioPath)
    }

    // MARK: - Post-Recording Flow

    func onRecordingComplete(phoneNumber: String, audioPath: String) {
        NSLog("CallBridge: Recording complete: %@", audioPath)
        state = .showingDialog(phoneNumber: phoneNumber, audioPath: audioPath)
        updateStatusIcon()

        // Look up contact
        lookupContact(phone: phoneNumber) { [weak self] contact in
            DispatchQueue.main.async {
                self?.showSaveDialog(phoneNumber: phoneNumber, audioPath: audioPath, contact: contact)
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

    func sendToBackend(audioPath: String, phoneNumber: String, contact: ContactInfo?, direction: String = "Outbound") {
        guard let url = URL(string: "\(serverURL)/process") else { return }
        beginBackendWork()

        // Reading (possibly hundreds of MB) and building the body off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fileData = FileManager.default.contents(atPath: audioPath), !fileData.isEmpty else {
                DispatchQueue.main.async {
                    NSLog("CallBridge: Cannot read recording %@", audioPath)
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
                DispatchQueue.main.async {
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

    func showSaveDialog(phoneNumber: String, audioPath: String, contact: ContactInfo?) {
        dismissDialog()
        let viewModel = SaveDialogViewModel(
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

    func sendNNO(contact: ContactInfo, audioPath: String) {
        guard let contactId = contact.id,
              let url = URL(string: "\(serverURL)/log-nno") else { return }
        beginBackendWork()

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append(Self.multipartField("salesforce_id", contactId, boundary: boundary))
        body.append(Self.multipartField("salesforce_type", contact.type, boundary: boundary))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Strong self: this outlives the (already closed) dialog and its view model.
        URLSession.shared.dataTask(with: request) { data, response, error in
            let failure = Self.backendFailure(data, response, error)
            DispatchQueue.main.async {
                if let failure = failure {
                    NSLog("CallBridge: NNO error: %@", failure)
                    self.showNotification(title: "CallBridge", message: "NNO fout: \(failure) — opname bewaard")
                } else {
                    NSLog("CallBridge: NNO logged successfully")
                    // Only now: an NNO needs no audio, but keep it until the log succeeded.
                    self.trashRecording(audioPath)
                    self.showNotification(title: "CallBridge", message: "NNO gelogd + follow-up aangemaakt")
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

// MARK: - SwiftUI View Model

class SaveDialogViewModel: ObservableObject {
    let phoneNumber: String
    let audioPath: String
    weak var appDelegate: AppDelegate?

    @Published var selectedContact: ContactInfo?
    @Published var searchQuery: String = ""
    @Published var searchResults: [ContactInfo] = []
    @Published var isSearching: Bool = false
    @Published var isSending: Bool = false

    private var searchTask: DispatchWorkItem?

    init(phoneNumber: String, audioPath: String, initialContact: ContactInfo?, appDelegate: AppDelegate) {
        self.phoneNumber = phoneNumber
        self.audioPath = audioPath
        self.selectedContact = initialContact
        self.appDelegate = appDelegate
    }

    func search() {
        searchTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        let task = DispatchWorkItem { [weak self] in
            self?.appDelegate?.searchContacts(query: query) { results in
                DispatchQueue.main.async {
                    // Ignore responses for an older query (or after a pick cleared it).
                    guard let self = self,
                          self.searchQuery.trimmingCharacters(in: .whitespaces) == query else { return }
                    self.searchResults = results
                    self.isSearching = false
                }
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    func save() {
        guard !isSending, let appDelegate = appDelegate else { return }
        isSending = true
        appDelegate.dialogFinished(audioPath: audioPath)
        appDelegate.sendToBackend(
            audioPath: audioPath,
            phoneNumber: phoneNumber,
            contact: selectedContact
        )
        appDelegate.dismissDialog()
    }

    func discard() {
        guard let appDelegate = appDelegate else { return }
        // To the Trash, not a hard delete — recoverable if clicked by mistake.
        appDelegate.trashRecording(audioPath)
        NSLog("CallBridge: Recording discarded: %@", audioPath)
        appDelegate.dialogFinished(audioPath: audioPath)
        appDelegate.dismissDialog()
    }

    func logNNO() {
        guard !isSending, let contact = selectedContact, contact.id != nil,
              let appDelegate = appDelegate else { return }
        isSending = true
        appDelegate.dialogFinished(audioPath: audioPath)
        // The request lives in AppDelegate: this view model is freed as soon as the
        // dialog closes, which silently dropped the NNO result (and state reset).
        appDelegate.sendNNO(contact: contact, audioPath: audioPath)
        appDelegate.dismissDialog()
    }
}

// MARK: - SwiftUI Views

struct SaveRecordingView: View {
    @ObservedObject var viewModel: SaveDialogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Opname opslaan?")
                .font(.title2)
                .bold()

            // Phone number
            HStack {
                Text("Telefoonnummer:")
                    .foregroundColor(.secondary)
                Text(viewModel.phoneNumber)
                    .bold()
            }

            // Current contact
            if let contact = viewModel.selectedContact {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Salesforce record:")
                        .foregroundColor(.secondary)
                    HStack {
                        Text(contact.typeLabel)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(typeColor(contact.type).opacity(0.2))
                            .cornerRadius(4)
                        Text(contact.displayName)
                            .bold()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                Text("Geen Salesforce record gevonden voor dit nummer")
                    .foregroundColor(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
            }

            Divider()

            // Search
            VStack(alignment: .leading, spacing: 8) {
                Text("Zoek ander record:")
                    .foregroundColor(.secondary)
                    .font(.caption)

                TextField("Zoek op naam...", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.searchQuery) { _ in
                        viewModel.search()
                    }

                if viewModel.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                if !viewModel.searchResults.isEmpty {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(viewModel.searchResults) { result in
                                Button(action: {
                                    viewModel.selectedContact = result
                                    viewModel.searchQuery = ""
                                    viewModel.searchResults = []
                                }) {
                                    HStack {
                                        Text(result.typeLabel)
                                            .font(.caption)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(typeColor(result.type).opacity(0.2))
                                            .cornerRadius(3)
                                        Text(result.displayName)
                                        Spacer()
                                        if let phone = result.phone {
                                            Text(phone)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(4)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }

            Spacer()

            // Buttons
            HStack {
                // No Esc shortcut: Esc in the search field used to discard the recording.
                Button("Niet opslaan") {
                    viewModel.discard()
                }
                .disabled(viewModel.isSending)

                Button("NNO") {
                    viewModel.logNNO()
                }
                .disabled(viewModel.selectedContact == nil || viewModel.selectedContact?.id == nil || viewModel.isSending)
                .buttonStyle(.bordered)

                Spacer()

                Button("Opslaan") {
                    viewModel.save()
                }
                .keyboardShortcut(.return)
                .disabled(viewModel.selectedContact == nil || viewModel.isSending)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420, height: 480)
    }

    func typeColor(_ type: String) -> Color {
        switch type {
        case "Contact": return .blue
        case "Account": return .purple
        case "Lead": return .orange
        default: return .gray
        }
    }
}

// MARK: - Manual Process View Model

class ManualProcessViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    let audioPath: String
    weak var appDelegate: AppDelegate?

    @Published var selectedContact: ContactInfo?
    @Published var searchQuery: String = ""
    @Published var searchResults: [ContactInfo] = []
    @Published var isSearching: Bool = false
    @Published var isSending: Bool = false
    @Published var isPlaying: Bool = false
    @Published var playbackProgress: Double = 0
    @Published var playbackTime: String = "0:00"
    @Published var duration: String = "0:00"

    private var searchTask: DispatchWorkItem?
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    var fileName: String {
        (audioPath as NSString).lastPathComponent
    }

    init(audioPath: String, appDelegate: AppDelegate) {
        self.audioPath = audioPath
        self.appDelegate = appDelegate
        super.init()
        loadAudioDuration()
    }

    private func loadAudioDuration() {
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath)) else { return }
        duration = formatTime(player.duration)
    }

    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        if audioPlayer == nil {
            guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath)) else { return }
            player.delegate = self
            audioPlayer = player
        }
        audioPlayer?.play()
        isPlaying = true
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        progressTimer?.invalidate()
    }

    func seek(to fraction: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = fraction * player.duration
        updateProgress()
    }

    private func updateProgress() {
        guard let player = audioPlayer else { return }
        playbackProgress = player.duration > 0 ? player.currentTime / player.duration : 0
        playbackTime = formatTime(player.currentTime)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.playbackProgress = 0
            self.playbackTime = "0:00"
            self.progressTimer?.invalidate()
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    func stopPlayback() {
        audioPlayer?.stop()
        progressTimer?.invalidate()
        audioPlayer = nil
    }

    func search() {
        searchTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        let task = DispatchWorkItem { [weak self] in
            self?.appDelegate?.searchContacts(query: query) { results in
                DispatchQueue.main.async {
                    // Ignore responses for an older query (or after a pick cleared it).
                    guard let self = self,
                          self.searchQuery.trimmingCharacters(in: .whitespaces) == query else { return }
                    self.searchResults = results
                    self.isSearching = false
                }
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    func process() {
        guard !isSending, selectedContact?.id != nil else { return }
        isSending = true
        stopPlayback()
        appDelegate?.sendToBackend(
            audioPath: audioPath,
            phoneNumber: selectedContact?.phone ?? "",
            contact: selectedContact
        )
        appDelegate?.dismissManualWindow()
    }

    func cancel() {
        stopPlayback()
        appDelegate?.dismissManualWindow()
    }
}

// MARK: - Manual Process View

struct ManualProcessView: View {
    @ObservedObject var viewModel: ManualProcessViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Handmatig Verwerken")
                .font(.title2)
                .bold()

            // File info + player
            VStack(spacing: 8) {
                HStack {
                    Text("Bestand:")
                        .foregroundColor(.secondary)
                    Text(viewModel.fileName)
                        .bold()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button(action: { viewModel.togglePlayback() }) {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.primary.opacity(0.1))
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * viewModel.playbackProgress, height: 4)
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                                        viewModel.seek(to: fraction)
                                    }
                            )
                        }
                        .frame(height: 4)

                        HStack {
                            Text(viewModel.playbackTime)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.duration)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)

            // Current contact
            if let contact = viewModel.selectedContact {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Salesforce record:")
                        .foregroundColor(.secondary)
                    HStack {
                        Text(contact.typeLabel)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(typeColor(contact.type).opacity(0.2))
                            .cornerRadius(4)
                        Text(contact.displayName)
                            .bold()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                Text("Zoek een Salesforce record om te koppelen")
                    .foregroundColor(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
            }

            Divider()

            // Search
            VStack(alignment: .leading, spacing: 8) {
                Text("Zoek record:")
                    .foregroundColor(.secondary)
                    .font(.caption)

                TextField("Zoek op naam...", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.searchQuery) { _ in
                        viewModel.search()
                    }

                if viewModel.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                if !viewModel.searchResults.isEmpty {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(viewModel.searchResults) { result in
                                Button(action: {
                                    viewModel.selectedContact = result
                                    viewModel.searchQuery = ""
                                    viewModel.searchResults = []
                                }) {
                                    HStack {
                                        Text(result.typeLabel)
                                            .font(.caption)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(typeColor(result.type).opacity(0.2))
                                            .cornerRadius(3)
                                        Text(result.displayName)
                                        Spacer()
                                        if let phone = result.phone {
                                            Text(phone)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(4)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }

            Spacer()

            // Buttons
            HStack {
                Button("Annuleren") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Verwerken") {
                    viewModel.process()
                }
                .keyboardShortcut(.return)
                .disabled(viewModel.selectedContact == nil || viewModel.isSending)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420, height: 400)
    }

    func typeColor(_ type: String) -> Color {
        switch type {
        case "Contact": return .blue
        case "Account": return .purple
        case "Lead": return .orange
        default: return .gray
        }
    }
}

// MARK: - App Entry Point

debugLog("=== CallBridge starting ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
