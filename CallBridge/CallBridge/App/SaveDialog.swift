import Cocoa
import SwiftUI
import Foundation

// MARK: - SwiftUI View Model

class SaveDialogViewModel: ObservableObject {
    /// The persisted session this dialog decides on; sent to the backend as client_ref.
    let sessionID: UUID
    let phoneNumber: String
    let audioPath: String
    weak var appDelegate: AppDelegate?

    @Published var selectedContact: ContactInfo?
    @Published var searchQuery: String = ""
    @Published var searchResults: [ContactInfo] = []
    @Published var isSearching: Bool = false
    @Published var isSending: Bool = false

    private var searchTask: DispatchWorkItem?

    init(sessionID: UUID, phoneNumber: String, audioPath: String, initialContact: ContactInfo?, appDelegate: AppDelegate) {
        self.sessionID = sessionID
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
            sessionID: sessionID,
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
