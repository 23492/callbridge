import Cocoa
import SwiftUI
import Foundation

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

    /// D-06: "Transcriberen via DSH", saved immediately like the beta toggle.
    @Published var dshEnabled: Bool = readDSHEnabled(.standard) {
        didSet {
            guard dshEnabled != oldValue else { return }
            UserDefaults.standard.set(dshEnabled, forKey: dshEnabledDefaultsKey)
            debugLog("Settings: DSH route \(dshEnabled ? "on" : "off")")
        }
    }
    /// The one-time code from the cockpit. Never logged.
    @Published var pairingCode: String = ""
    @Published var isPaired: Bool = false
    @Published var isPairing: Bool = false
    @Published var pairingMessage: String = ""
    /// Set by AppDelegate.showSettings: the DSH queue's client, for POST pair.
    var dshClient: DSHClient?
    /// Called after pairing or unpairing, so the DSH queue reloads its token.
    var onPairingChange: (() -> Void)?

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
        isPaired        = KeychainHelper.read(key: "DSH_CLIENT_TOKEN") != nil
    }

    /// Sends the pairing code once (POST pair) and stores the client token in the Keychain
    /// under DSH_CLIENT_TOKEN (D-06). Neither the code nor the token reaches a log line.
    func pair() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !isPairing else { return }
        guard let client = dshClient else {
            pairingMessage = "DSH niet bereikbaar"
            return
        }
        isPairing = true
        pairingMessage = ""
        client.pair(code: code) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPairing = false
                switch outcome {
                case .success(let data):
                    guard let answer = decodeCockpitData(CockpitPairAnswer.self, from: data), !answer.token.isEmpty else {
                        self.pairingMessage = "DSH niet bereikbaar"
                        return
                    }
                    KeychainHelper.save(key: "DSH_CLIENT_TOKEN", value: answer.token)
                    self.pairingCode = ""
                    self.isPaired = true
                    self.pairingMessage = "Gekoppeld"
                    debugLog("Settings: paired with DSH")
                    self.onPairingChange?()
                case .rejected(_, let message):
                    self.pairingMessage = message
                case .accessMissing:
                    self.pairingMessage = "Log eerst in bij DSH (menu: Log in bij DSH)"
                case .cloudflaredMissing:
                    self.pairingMessage = "cloudflared ontbreekt: brew install cloudflared"
                default:
                    self.pairingMessage = "DSH niet bereikbaar"
                }
            }
        }
    }

    /// Deletes only the local client token; the cockpit keeps its side (D-06).
    func unpair() {
        KeychainHelper.delete(key: "DSH_CLIENT_TOKEN")
        isPaired = false
        pairingMessage = ""
        debugLog("Settings: DSH pairing removed")
        onPairingChange?()
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
                Section("DSH") {
                    Toggle("Transcriberen via DSH", isOn: $viewModel.dshEnabled)
                    Text(viewModel.isPaired ? "Gekoppeld" : "Niet gekoppeld")
                        .foregroundColor(viewModel.isPaired ? .green : .secondary)
                    TextField("Koppelcode", text: $viewModel.pairingCode)
                    HStack {
                        Button("Koppelen") { viewModel.pair() }
                            .disabled(viewModel.isPairing ||
                                      viewModel.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if viewModel.isPaired {
                            Button("Ontkoppelen") { viewModel.unpair() }
                        }
                    }
                    if !viewModel.pairingMessage.isEmpty {
                        Text(viewModel.pairingMessage)
                            .font(.callout)
                    }
                    Text("Maak een koppelcode in de cockpit: Transcriberen, onderaan 'CallBridge', 'Koppelcode maken'.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
        .frame(width: 480, height: 860)
        .padding(.bottom)
    }
}
