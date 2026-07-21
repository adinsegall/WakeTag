import SwiftUI

/// Search the Apple Music catalog and pick the wake-up song.
struct SongPickerView: View {
    @Binding var selection: SongChoice?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var music = MusicService.shared

    @State private var query = ""
    @State private var results: [SongChoice] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Group {
                if !music.isAuthorized {
                    authorizationPrompt
                } else {
                    resultsList
                }
            }
            .navigationTitle("Choose a Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(.orange)
    }

    private var authorizationPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(Design.sunriseGradient)
            Text("Apple Music access needed")
                .font(.headline)
            Text("WakeTag searches the Apple Music catalog so any song can be your alarm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Allow Access") {
                Task { await music.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var resultsList: some View {
        List {
            if let searchError {
                Text(searchError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(results, id: \.id) { song in
                Button {
                    selection = song
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: song.artworkURL, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).lineLimit(1)
                            Text(song.artistName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if selection?.id == song.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search Apple Music")
        .task(id: query) {
            await runSearch()
        }
        .overlay {
            if results.isEmpty && !isSearching && query.isEmpty {
                ContentUnavailableView("Search for your wake-up song",
                                       systemImage: "magnifyingglass",
                                       description: Text("Any song on Apple Music can be your alarm."))
            }
        }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            return
        }
        // Debounce keystrokes; the task is cancelled when `query` changes.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await MusicService.shared.search(term)
        } catch is CancellationError {
        } catch {
            results = []
            searchError = "Search failed: \(error.localizedDescription)\nIf this persists, the MusicKit service may need to be enabled for this app's bundle ID in the Apple Developer portal."
        }
    }
}
