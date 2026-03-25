import Cocoa
import SwiftUI
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

// MARK: - Data Models

struct ContactInfo: Codable, Identifiable, Hashable {
    let id: String?
    let name: String
    let type: String
    let phone: String?
    let account_name: String?
    let account_id: String?

    var displayName: String {
        if let acct = account_name, !acct.isEmpty, type != "Account" {
            return "\(name) (\(acct))"
        }
        return name
    }

    var typeLabel: String {
        switch type {
        case "Contact": return "Contact"
        case "Account": return "Account"
        case "Lead": return "Lead"
        default: return type
        }
    }
}

struct SearchResponse: Codable {
    let results: [ContactInfo]
}

// MARK: - Status Models

struct ProcessingJob: Codable {
    let job_id: String
    let contact_name: String
    let step: String

    var stepLabel: String {
        switch step {
        case "starting": return "Starten..."
        case "transcribing": return "Transcriberen..."
        case "summarizing": return "Samenvatten..."
        case "extracting_actions": return "Acties extraheren..."
        case "saving_to_salesforce": return "Opslaan in Salesforce..."
        default: return step
        }
    }
}

struct FutureTask: Codable {
    let task_id: String
    let subject: String
    let activity_date: String

    var taskURL: URL? {
        URL(string: "https://welisa.lightning.force.com/lightning/r/Task/\(task_id)/view")
    }

    var subjectShort: String {
        subject.count > 20 ? String(subject.prefix(20)) + "…" : subject
    }

    var dateFormatted: String {
        let fmtIn = DateFormatter()
        fmtIn.dateFormat = "yyyy-MM-dd"
        let fmtOut = DateFormatter()
        fmtOut.dateFormat = "dd-MM-yy"
        if let date = fmtIn.date(from: activity_date) {
            return fmtOut.string(from: date)
        }
        return activity_date
    }
}

struct CompletedJob: Codable {
    let contact_name: String
    let contact_id: String
    let contact_type: String
    let task_id: String
    let future_tasks: [FutureTask]?

    var contactURL: URL? {
        URL(string: "https://welisa.lightning.force.com/lightning/r/\(contact_type)/\(contact_id)/view")
    }
    var taskURL: URL? {
        URL(string: "https://welisa.lightning.force.com/lightning/r/Task/\(task_id)/view")
    }
}

struct StatusResponse: Codable {
    let processing: [ProcessingJob]
    let completed: [CompletedJob]
}

// MARK: - Call State Machine

enum CallState {
    case idle
    case recording(phoneNumber: String, startTime: Date, existingFiles: Set<String>)
    case showingDialog(phoneNumber: String, audioPath: String)
    case processing
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    let serverURL = "http://localhost:8765"
    let phoneAppBundleID = "com.apple.mobilephone"
    let audioHijackSessionName = "Voice Chat"
    let recordingsDir = NSHomeDirectory() + "/Auto Logger Recordings"

    var statusItem: NSStatusItem!
    var state: CallState = .idle
    var pollTimer: Timer?
    var dialogWindow: NSWindow?
    var statusTimer: Timer?
    var lastStatus: StatusResponse?
    var serverReachable: Bool = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("App launching, recordingsDir: \(recordingsDir), logPath: \(debugLogPath)")

        // Create recordings directory
        try? FileManager.default.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)

        // Setup menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()

        // Fetch status immediately, then poll every 5 seconds
        fetchStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }

        // Register for URL events
        let em = NSAppleEventManager.shared()
        em.setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Check for unprocessed recordings on launch
        checkForOrphanedRecordings()
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

    func fetchStatus() {
        guard let url = URL(string: "\(serverURL)/status") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    debugLog("fetchStatus error: \(error.localizedDescription)")
                    self.serverReachable = false
                    self.lastStatus = nil
                } else if let data = data,
                          let status = try? JSONDecoder().decode(StatusResponse.self, from: data) {
                    debugLog("fetchStatus OK — processing: \(status.processing.count), completed: \(status.completed.count)")
                    self.serverReachable = true
                    self.lastStatus = status
                } else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? "nil"
                    debugLog("fetchStatus decode failed, data: \(raw)")
                    self.serverReachable = false
                    self.lastStatus = nil
                }
                self.rebuildMenu()
            }
        }.resume()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        debugLog("rebuildMenu — reachable: \(serverReachable), processing: \(lastStatus?.processing.count ?? -1), completed: \(lastStatus?.completed.count ?? -1)")

        // Header
        let header = NSMenuItem(title: "CallBridge v2", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard serverReachable else {
            let item = NSMenuItem(title: "Server niet bereikbaar", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
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

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - URL Handler

    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }

        let phoneNumber = urlString
            .replacingOccurrences(of: "tel://", with: "")
            .replacingOccurrences(of: "tel:", with: "")
            .removingPercentEncoding ?? urlString

        NSLog("CallBridge: tel: URL received for %@", phoneNumber)

        // If already recording, queue or ignore
        if case .recording = state {
            NSLog("CallBridge: Already recording, ignoring new call")
            return
        }

        // 1. Snapshot existing files in recordings folder
        let existingFiles = snapshotRecordingsFolder()

        // 2. Start Audio Hijack recording
        startAudioHijack()

        // 3. Forward to Phone.app
        forwardCall(url: url)

        // 4. Set state to recording
        state = .recording(phoneNumber: phoneNumber, startTime: Date(), existingFiles: existingFiles)
        updateStatusIcon()

        // 5. Start polling for call end
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
        let tmpPath = NSTemporaryDirectory() + "callbridge_cmd.ahcommand"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            if let ahURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.rogueamoeba.audiohijack") {
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: tmpPath)],
                    withApplicationAt: ahURL,
                    configuration: NSWorkspace.OpenConfiguration()
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
        app.runShellCommand('/bin/echo \\'' + data + '\\' > /tmp/ah_state.json');
        """
        runAudioHijackScript(script)
    }

    // MARK: - Recording Detection

    func snapshotRecordingsFolder() -> Set<String> {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: recordingsDir)) ?? []
        return Set(files)
    }

    func findNewRecording(existingFiles: Set<String>) -> String? {
        let fm = FileManager.default
        let currentFiles = (try? fm.contentsOfDirectory(atPath: recordingsDir)) ?? []
        let extensions = ["mp3", "wav", "m4a", "aiff", "caf"]

        for file in currentFiles {
            if !existingFiles.contains(file) {
                let ext = (file as NSString).pathExtension.lowercased()
                if extensions.contains(ext) {
                    let fullPath = (recordingsDir as NSString).appendingPathComponent(file)
                    return fullPath
                }
            }
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
        guard case let .recording(phoneNumber, startTime, existingFiles) = state else {
            stopPolling()
            return
        }

        // Timeout after 2 hours
        if Date().timeIntervalSince(startTime) > 7200 {
            NSLog("CallBridge: Recording timeout (2h), stopping")
            stopAudioHijack()
            stopPolling()
            state = .idle
            updateStatusIcon()
            return
        }

        // Check for new file in recordings folder
        if let newFile = findNewRecording(existingFiles: existingFiles) {
            NSLog("CallBridge: New recording found: %@", newFile)

            // Wait for file to stabilize (background thread)
            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                if self.isFileSizeStable(newFile) {
                    DispatchQueue.main.async {
                        self.stopPolling()
                        self.stopAudioHijack()
                        self.onRecordingComplete(phoneNumber: phoneNumber, audioPath: newFile)
                    }
                }
            }
        }

        // Also query Audio Hijack state (writes to /tmp/ah_state.json)
        // Read previous state file
        if let data = FileManager.default.contents(atPath: "/tmp/ah_state.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let running = json["running"] as? Bool,
           !running {
            NSLog("CallBridge: Audio Hijack session stopped")
            // Session stopped but no new file yet — wait a bit more
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self else { return }
                if let newFile = self.findNewRecording(existingFiles: existingFiles) {
                    if self.isFileSizeStable(newFile) {
                        self.stopPolling()
                        self.onRecordingComplete(phoneNumber: phoneNumber, audioPath: newFile)
                    }
                } else {
                    NSLog("CallBridge: No recording file found after session stop")
                    self.stopPolling()
                    self.state = .idle
                    self.updateStatusIcon()
                    self.showNotification(title: "CallBridge", message: "Geen opname gevonden")
                }
            }
        }

        // Query for next poll cycle
        queryAudioHijackState()
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
        let encoded = phone.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? phone
        guard let url = URL(string: "\(serverURL)/contact-search?phone=\(encoded)") else {
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

    func searchContacts(query: String, completion: @escaping ([ContactInfo]) -> Void) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(serverURL)/contact-search?q=\(encoded)") else {
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
        state = .processing
        updateStatusIcon()

        guard let url = URL(string: "\(serverURL)/process") else { return }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addField("phone_number", phoneNumber)
        addField("direction", direction)
        if let c = contact {
            if let id = c.id { addField("salesforce_id", id) }
            addField("salesforce_type", c.type)
        }

        // Audio file
        let filename = (audioPath as NSString).lastPathComponent
        if let fileData = FileManager.default.contents(atPath: audioPath) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("CallBridge: Backend error: %@", error.localizedDescription)
                    self?.showNotification(title: "CallBridge", message: "Fout: \(error.localizedDescription)")
                } else {
                    NSLog("CallBridge: Sent to backend successfully")
                    self?.showNotification(title: "CallBridge", message: "Opname wordt verwerkt...")
                }
                self?.state = .idle
                self?.updateStatusIcon()
            }
        }.resume()
    }

    // MARK: - Save Dialog

    func showSaveDialog(phoneNumber: String, audioPath: String, contact: ContactInfo?) {
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

        // Store reference
        dialogWindow = window

        // Show and activate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissDialog() {
        dialogWindow?.close()
        dialogWindow = nil
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
        let script = "display notification \"\(message)\" with title \"\(title)\""
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", escaped])
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
                    self?.searchResults = results
                    self?.isSearching = false
                }
            }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    func save() {
        isSending = true
        appDelegate?.sendToBackend(
            audioPath: audioPath,
            phoneNumber: phoneNumber,
            contact: selectedContact
        )
        appDelegate?.dismissDialog()
    }

    func discard() {
        // Delete the recording
        try? FileManager.default.removeItem(atPath: audioPath)
        NSLog("CallBridge: Recording discarded: %@", audioPath)
        appDelegate?.state = .idle
        appDelegate?.updateStatusIcon()
        appDelegate?.dismissDialog()
    }

    func logNNO() {
        guard let contact = selectedContact, let contactId = contact.id else { return }

        isSending = true

        // Delete the recording — no need to process audio for NNO
        try? FileManager.default.removeItem(atPath: audioPath)

        guard let url = URL(string: "\(appDelegate?.serverURL ?? "http://localhost:8765")/log-nno") else { return }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("salesforce_id", contactId)
        addField("salesforce_type", contact.type)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("CallBridge: NNO error: %@", error.localizedDescription)
                    self?.appDelegate?.showNotification(title: "CallBridge", message: "NNO fout: \(error.localizedDescription)")
                } else {
                    NSLog("CallBridge: NNO logged successfully")
                    self?.appDelegate?.showNotification(title: "CallBridge", message: "NNO gelogd + follow-up aangemaakt")
                }
                self?.appDelegate?.state = .idle
                self?.appDelegate?.updateStatusIcon()
            }
        }.resume()

        appDelegate?.dismissDialog()
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
                Button("Niet opslaan") {
                    viewModel.discard()
                }
                .keyboardShortcut(.escape)

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

// MARK: - App Entry Point

debugLog("=== CallBridge starting ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
