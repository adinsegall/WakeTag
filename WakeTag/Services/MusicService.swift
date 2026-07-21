import Foundation
import MusicKit
import AVFoundation

/// Apple Music search + alarm playback.
///
/// Playback ladder at ring time:
/// 1. Apple Music subscriber → `ApplicationMusicPlayer` with the full song on
///    repeat (out-of-process, survives backgrounding), plus an in-process
///    silent keeper loop so the app stays alive to enforce the volume guard.
/// 2. Otherwise → loop the song's 30-second preview with AVPlayer — from a
///    locally cached copy when available (downloaded at pick time), else the
///    remote URL with a watchdog.
/// 3. Any failure → loop a synthesized tone so the alarm is never silent.
@MainActor
final class MusicService: ObservableObject {
    static let shared = MusicService()

    private enum PlaybackMode {
        case none
        case fullSong
        case preview
    }

    @Published var authorizationStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackNote: String?

    private var previewPlayer: AVQueuePlayer?
    private var previewLooper: AVPlayerLooper?
    private var keeperPlayer: AVQueuePlayer?
    private var keeperLooper: AVPlayerLooper?
    private var mode: PlaybackMode = .none
    private var watchdogTask: Task<Void, Never>?
    private var itemFailureObservers: [NSObjectProtocol] = []

    private init() {
        // A phone call, Siri, or another alarm pauses our players and they do
        // NOT auto-resume — fatal for an alarm. Always resume on `.ended`.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                if type == .ended {
                    MusicService.shared.resumeIfNeeded()
                }
            }
        }
    }

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

    // MARK: Preview caching

    /// Previews are DRM-free files; caching one at pick time means the alarm
    /// can make its real sound even fully offline.
    nonisolated static func cachedPreviewURL(for songID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Previews", isDirectory: true)
            .appendingPathComponent("\(songID).m4a")
    }

    func downloadPreviewIfNeeded(for choice: SongChoice) async {
        guard let remote = choice.previewURL else { return }
        let destination = Self.cachedPreviewURL(for: choice.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 { return }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            // Best effort — the remote URL and tone fallback still exist.
        }
    }

    // MARK: Alarm playback

    func startAlarmPlayback(for choice: SongChoice?) async {
        playbackNote = nil

        guard let choice else {
            activateAudioSession(mixable: false)
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

        activateAudioSession(mixable: false)
        let cached = Self.cachedPreviewURL(for: choice.id)
        if FileManager.default.fileExists(atPath: cached.path) {
            playLoopingPreview(url: cached, watchdog: false)
        } else if let previewURL = choice.previewURL {
            playLoopingPreview(url: previewURL, watchdog: true)
        } else {
            playFallbackTone()
        }
        isPlaying = true
    }

    /// Re-activates the session and kicks the players. Called after audio
    /// interruptions and whenever the app returns to foreground mid-ring.
    func resumeIfNeeded() {
        switch mode {
        case .none:
            return
        case .fullSong:
            activateAudioSession(mixable: true)
            keeperPlayer?.play()
            Task {
                try? await ApplicationMusicPlayer.shared.play()
            }
        case .preview:
            activateAudioSession(mixable: false)
            previewPlayer?.play()
        }
    }

    func stopPlayback() {
        watchdogTask?.cancel()
        watchdogTask = nil
        removeItemFailureObservers()
        if mode == .fullSong {
            let player = ApplicationMusicPlayer.shared
            player.stop()
            player.queue = []
        }
        previewLooper = nil
        previewPlayer?.pause()
        previewPlayer = nil
        keeperLooper = nil
        keeperPlayer?.pause()
        keeperPlayer = nil
        mode = .none
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Playback paths

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
        mode = .fullSong

        // ApplicationMusicPlayer renders out of process, so without our own
        // audio the app suspends when locked and the volume guard dies. A
        // silent in-process loop (mixed with the music) keeps us running.
        activateAudioSession(mixable: true)
        if let silence = ToneGenerator.silentLoopURL() {
            let keeper = AVQueuePlayer()
            keeperLooper = AVPlayerLooper(player: keeper, templateItem: AVPlayerItem(url: silence))
            keeper.play()
            keeperPlayer = keeper
        }
    }

    private func playLoopingPreview(url: URL, watchdog: Bool) {
        removeItemFailureObservers()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        previewLooper = AVPlayerLooper(player: player, templateItem: item)
        player.volume = 1.0
        player.play()
        previewPlayer = player
        mode = .preview

        for name in [AVPlayerItem.failedToPlayToEndTimeNotification,
                     AVPlayerItem.newErrorLogEntryNotification] {
            itemFailureObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: item, queue: .main
            ) { _ in
                Task { @MainActor in
                    MusicService.shared.handlePreviewFailure()
                }
            })
        }

        guard watchdog else { return }
        // Remote stream: if nothing is audibly playing a few seconds in
        // (offline, dead URL, DNS failure), switch to the offline tone.
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            if self.mode == .preview, let player = self.previewPlayer,
               player.timeControlStatus != .playing || player.currentItem?.status == .failed {
                self.handlePreviewFailure()
            }
        }
    }

    private func handlePreviewFailure() {
        guard mode == .preview else { return }
        playFallbackTone()
        playbackNote = "Couldn't stream the song — using the backup tone."
    }

    /// Local synthesized tone: the floor of the ladder, always playable.
    private func playFallbackTone() {
        watchdogTask?.cancel()
        watchdogTask = nil
        guard let url = ToneGenerator.alarmToneURL() else {
            playbackNote = "Couldn't start playback."
            return
        }
        removeItemFailureObservers()
        previewLooper = nil
        previewPlayer?.pause()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        previewLooper = AVPlayerLooper(player: player, templateItem: item)
        player.volume = 1.0
        player.play()
        previewPlayer = player
        mode = .preview
        isPlaying = true
    }

    private func activateAudioSession(mixable: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: mixable ? [.mixWithOthers] : [])
        try? session.setActive(true)
    }

    private func removeItemFailureObservers() {
        itemFailureObservers.forEach(NotificationCenter.default.removeObserver(_:))
        itemFailureObservers = []
    }
}

/// Writes small WAV files into the caches directory once: an audible two-tone
/// alarm (offline floor of the playback ladder) and a silent loop (keeps the
/// process alive while ApplicationMusicPlayer plays out of process).
enum ToneGenerator {
    static func alarmToneURL() -> URL? {
        writeWAV(named: "waketag-alarm-tone.wav") { t in
            // Alternate 880 Hz / 660 Hz beeps with brief gaps.
            let beepPhase = t.truncatingRemainder(dividingBy: 0.5)
            guard beepPhase < 0.35 else { return 0 }
            let frequency = t.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 880.0 : 660.0
            let envelope = min(1.0, beepPhase / 0.02, (0.35 - beepPhase) / 0.02)
            return sin(2 * .pi * frequency * t) * envelope * 0.6
        }
    }

    static func silentLoopURL() -> URL? {
        writeWAV(named: "waketag-silence.wav") { _ in 0 }
    }

    private static func writeWAV(named name: String, sample: (Double) -> Double) -> URL? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44_100
        let frameCount = sampleRate * 2
        var samples = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            samples[frame] = Int16(max(-1, min(1, sample(t))) * Double(Int16.max - 1))
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
