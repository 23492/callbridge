import Cocoa
import Foundation
import CryptoKit

// MARK: - Update Manifest

struct UpdateManifest: Codable {
    let version: String
    let url: String
    let signature: String
    let notes: String?
}

// MARK: - Update Checker

class UpdateChecker {
    var availableVersion: String?
    var availableManifest: UpdateManifest?
    var isUpdating = false

    /// True when the offered update leaves the beta channel for an older stable build.
    var isReturnToStable = false

    func checkForUpdate(notify: Bool = false, callback: (() -> Void)? = nil) {
        let selected = UpdateChannel.current
        // Beta also needs the stable manifest: a stable release can overtake the newest beta.
        let channels: [UpdateChannel] = [.stable, .beta]
        var manifests: [UpdateChannel: UpdateManifest] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for channel in channels {
            guard let url = URL(string: channel.manifestURL) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            group.enter()
            URLSession.shared.dataTask(with: request) { data, _, error in
                defer { group.leave() }
                guard let data = data, error == nil,
                      let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
                    debugLog("UpdateChecker: Failed to fetch \(channel.rawValue) manifest: \(error?.localizedDescription ?? "decode error")")
                    return
                }
                lock.lock(); manifests[channel] = manifest; lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let decision = decideUpdate(
                installed: appVersion,
                buildChannel: appBuildChannel,
                selected: selected,
                stableManifest: manifests[.stable]?.version,
                betaManifest: selected == .beta ? manifests[.beta]?.version : nil
            )
            debugLog("UpdateChecker: channel=\(selected.rawValue) installed=\(appVersion) (\(appBuildChannel)) decision=\(decision)")

            switch decision {
            case .upgrade(let version), .returnToStable(let version):
                let manifest = [manifests[.beta], manifests[.stable]].compactMap { $0 }.first { $0.version == version }
                self.availableVersion = version
                self.availableManifest = manifest
                if case .returnToStable = decision { self.isReturnToStable = true } else { self.isReturnToStable = false }
            case .none:
                self.availableVersion = nil
                self.availableManifest = nil
                self.isReturnToStable = false
                if notify {
                    self.showNotification(title: "CallBridge", message: "Je hebt de nieuwste versie (v\(appVersion), kanaal \(selected.rawValue))")
                }
            }
            callback?()
        }
    }

    func downloadAndApply() {
        guard let manifest = availableManifest, let downloadURL = URL(string: manifest.url) else { return }
        guard !isUpdating else { return }
        isUpdating = true

        debugLog("UpdateChecker: Downloading update v\(manifest.version) from \(manifest.url)")
        showNotification(title: "CallBridge", message: "Update v\(manifest.version) downloaden...")

        URLSession.shared.dataTask(with: downloadURL) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data, error == nil else {
                debugLog("UpdateChecker: Download failed: \(error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self.showNotification(title: "CallBridge", message: "Update download mislukt")
                    self.isUpdating = false
                }
                return
            }

            // Verify Ed25519 signature
            guard self.verifySignature(data: data, signatureBase64: manifest.signature) else {
                debugLog("UpdateChecker: Signature verification FAILED")
                DispatchQueue.main.async {
                    self.showNotification(title: "CallBridge", message: "Update handtekening ongeldig — update geannuleerd")
                    self.isUpdating = false
                }
                return
            }
            debugLog("UpdateChecker: Signature verified OK")

            // Write zip to temp
            let zipPath = "/tmp/CallBridge-update.zip"
            let extractDir = "/tmp/CallBridge-update"
            let appDest = "/Applications/CallBridge.app"

            do {
                try data.write(to: URL(fileURLWithPath: zipPath))
            } catch {
                debugLog("UpdateChecker: Failed to write zip: \(error)")
                DispatchQueue.main.async { self.isUpdating = false }
                return
            }

            // Clean previous extract
            try? FileManager.default.removeItem(atPath: extractDir)

            // Unzip using ditto
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", zipPath, extractDir]
            do {
                try unzip.run()
                unzip.waitUntilExit()
            } catch {
                debugLog("UpdateChecker: Unzip failed: \(error)")
                DispatchQueue.main.async { self.isUpdating = false }
                return
            }

            // Verify extracted app exists
            let extractedApp = extractDir + "/CallBridge.app"
            let extractedBinary = extractedApp + "/Contents/MacOS/CallBridge"
            guard FileManager.default.fileExists(atPath: extractedBinary) else {
                debugLog("UpdateChecker: Extracted app missing binary at \(extractedBinary)")
                DispatchQueue.main.async {
                    self.showNotification(title: "CallBridge", message: "Update pakket ongeldig")
                    self.isUpdating = false
                }
                return
            }

            // Replace app and relaunch via trampoline
            DispatchQueue.main.async {
                self.showNotification(title: "CallBridge", message: "Update v\(manifest.version) installeren...")
                self.replaceAndRelaunch(extractedApp: extractedApp, appDest: appDest)
            }
        }.resume()
    }

    func verifySignature(data: Data, signatureBase64: String) -> Bool {
        guard !updatePublicKey.isEmpty,
              let pubKeyData = Data(base64Encoded: updatePublicKey),
              let sigData = Data(base64Encoded: signatureBase64) else {
            debugLog("UpdateChecker: Invalid key or signature data")
            return false
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)
            return publicKey.isValidSignature(sigData, for: data)
        } catch {
            debugLog("UpdateChecker: Signature check error: \(error)")
            return false
        }
    }

    func replaceAndRelaunch(extractedApp: String, appDest: String) {
        // Wait until this process has really exited (it stops the backend first) —
        // otherwise the relaunched copy sees a running instance and quits itself.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        for i in $(seq 1 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        sleep 0.5
        rm -rf "\(appDest)"
        mv "\(extractedApp)" "\(appDest)"
        xattr -cr "\(appDest)"
        open "\(appDest)"
        rm -f /tmp/CallBridge-update.zip
        rm -rf /tmp/CallBridge-update
        """
        let scriptPath = "/tmp/callbridge_update_relaunch.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // Make executable
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptPath]
            try chmod.run()
            chmod.waitUntilExit()

            // Launch the trampoline
            let bash = Process()
            bash.executableURL = URL(fileURLWithPath: "/bin/bash")
            bash.arguments = [scriptPath]
            try bash.run()

            debugLog("UpdateChecker: Relaunch trampoline started, terminating app")
            NSApp.terminate(nil)
        } catch {
            debugLog("UpdateChecker: Failed to launch relaunch script: \(error)")
            showNotification(title: "CallBridge", message: "Update installatie mislukt")
            isUpdating = false
        }
    }

    func showNotification(title: String, message: String) {
        let safeTitle   = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let safeMessage = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(safeMessage)\" with title \"\(safeTitle)\""
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script])
    }
}
