import Cocoa
import SwiftUI
import Foundation
import AVFoundation

// MARK: - Manual Process View Model

class ManualProcessViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The persisted session for this file; sent to the backend as client_ref.
    let sessionID: UUID
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

    init(sessionID: UUID, audioPath: String, appDelegate: AppDelegate) {
        self.sessionID = sessionID
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
            sessionID: sessionID,
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
