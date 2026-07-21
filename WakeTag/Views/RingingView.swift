import SwiftUI

/// Full-screen takeover while the alarm plays. There is no dismiss control —
/// the only way out is scanning the registered tag.
struct RingingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var music = MusicService.shared

    @State private var isScanning = false
    @State private var scanStatus: String?
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Design.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text(model.ringingAlarm?.label ?? "Wake up")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                if let song = model.ringingAlarm?.song {
                    VStack(spacing: 12) {
                        ArtworkView(url: song.artworkURL, size: 180)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                        VStack(spacing: 2) {
                            Text(song.title).font(.headline)
                            Text(song.artistName).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }

                if let note = music.playbackNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text("Volume locked — scan your tag to unlock")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let scanStatus {
                    Text(scanStatus)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                PrimaryButton(title: isScanning ? "Scanning…" : "Scan Tag to Stop",
                              systemImage: "dot.radiowaves.up.forward",
                              isDisabled: isScanning) {
                    Task { await attemptStop() }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private func attemptStop() async {
        guard let tag = model.registeredTag else {
            // Shouldn't happen (tag registration gates onboarding), but never
            // trap someone in an unstoppable alarm.
            model.completeRinging()
            return
        }
        isScanning = true
        scanStatus = nil
        defer { isScanning = false }
        do {
            try await NFCService().scanForMatch(
                expectedUID: tag.uid,
                prompt: "Scan \"\(tag.name)\" to stop the alarm.")
            model.completeRinging()
        } catch {
            scanStatus = error.localizedDescription
        }
    }
}
