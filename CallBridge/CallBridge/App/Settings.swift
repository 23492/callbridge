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
