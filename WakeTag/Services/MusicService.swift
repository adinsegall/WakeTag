import Foundation
import MusicKit
import AVFoundation

/// Apple Music search + alarm playback.
///
/// Playback strategy at ring time:
/// 1. Apple Music subscriber → `ApplicationMusicPlayer` with the full song on
///    repeat. Playback is rendered out of process, so it survives backgrounding.
/// 2. Otherwise → loop the song's 30-second preview with AVPlayer (DRM-free,
///    no subscription needed), kept alive in background by the audio background
///    mode.
@MainActor
final class MusicService: ObservableObject {
    static let shared = MusicService()

    @Published var authorizationStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackNote: String?

    private var previewPlayer: AVQueuePlayer?
    private var previewLooper: AVPlayerLooper?

    private init() {}

    // MARK: Authorization

    var isAuthorized: Bool { authorizationStatus == .authorized }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
        return status == .authorized
    }

    // MARK: Search

    func search(_ term: String) async throws -> [SongChoice] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        let response = try await request.response()
        return response.songs.map { song in
            SongChoice(
                id: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                artworkURL: song.artwork?.url(width: 300, height: 300),
                previewURL: song.previewAssets?.first?.url)
        }
    }

    // MARK: Alarm playback

    func startAlarmPlayback(for choice: SongChoice?) async {
        playbackNote = nil
        activateAudioSession()

        guard let choice else {
            playFallbackTone()
            return
        }

        if isAuthorized {
            do {
                let subscription = try await MusicSubscription.current
                if subscription.canPlayCatalogContent {
                    try await playFullSong(id: choice.id)
                    isPlaying = true
                    return
                }
                playbackNote = "No Apple Music subscription — playing the preview."
            } catch {
                playbackNote = "Apple Music unavailable — playing the preview."
            }
        }

        if let previewURL = choice.previewURL {
            playLoopingPreview(url: previewURL)
            isPlaying = true
        } else {
            playFallbackTone()
        }
    }

    func stopPlayback() {
        let player = ApplicationMusicPlayer.shared
        player.stop()
        player.queue = []
        previewLooper = nil
        previewPlayer?.pause()
        previewPlayer = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playFullSong(id: String) async throws {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let song = try await request.response().items.first else {
            throw NSError(domain: "WakeTag", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Song not found in the catalog."])
        }
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        try await player.prepareToPlay()
        try await player.play()
        // Set repeat AFTER play(): setting it before playback starts is
        // silently ignored on current iOS builds.
        player.state.repeatMode = .one
        player.state.shuffleMode = .off
    }

    private func playLoopingPreview(url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        previewLooper = AVPlayerLooper(player: player, templateItem: item)
        player.volume = 1.0
        player.play()
        previewPlayer = player
    }

    /// Last resort if the song has no preview URL and full playback failed:
    /// loop a synthesized tone so the alarm is never silent.
    private func playFallbackTone() {
        guard let url = ToneGenerator.alarmToneURL() else {
            playbackNote = "Couldn't start playback."
            return
        }
        playLoopingPreview(url: url)
        isPlaying = true
        playbackNote = "Couldn't play the song — using a backup tone."
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}

/// Writes a short two-tone alarm WAV into the caches directory once, so the
/// alarm always has something audible to loop even fully offline.
enum ToneGenerator {
    static func alarmToneURL() -> URL? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("waketag-alarm-tone.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44_100
        let duration = 2.0
        let frameCount = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            // Alternate 880 Hz / 660 Hz beeps with brief gaps.
            let beepPhase = t.truncatingRemainder(dividingBy: 0.5)
            guard beepPhase < 0.35 else { continue }
            let frequency = t.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 880.0 : 660.0
            let envelope = min(1.0, beepPhase / 0.02, (0.35 - beepPhase) / 0.02)
            samples[frame] = Int16(sin(2 * .pi * frequency * t) * envelope * 0.6 * Double(Int16.max))
        }

        var data = Data()
        let byteCount = samples.count * 2
        func appendLE(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); appendLE(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); appendLE(16); appendLE16(1); appendLE16(1)
        appendLE(UInt32(sampleRate)); appendLE(UInt32(sampleRate * 2)); appendLE16(2); appendLE16(16)
        data.append(contentsOf: Array("data".utf8)); appendLE(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
