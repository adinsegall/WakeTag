import Foundation
import SwiftUI
import AlarmKit

/// App-wide state: the registered account, the registered NFC tag, the alarm
/// list, and the live ringing session. Persisted as JSON in UserDefaults;
/// credentials live in the Keychain.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private enum Keys {
        static let account = "waketag.account"
        static let tag = "waketag.tag"
        static let alarms = "waketag.alarms"
        static let volumeGuard = "waketag.volumeGuardEnabled"
    }

    @Published var account: UserAccount? { didSet { persist(account, key: Keys.account) } }
    @Published var registeredTag: RegisteredTag? { didSet { persist(registeredTag, key: Keys.tag) } }
    @Published var alarms: [WakeAlarm] = [] { didSet { persist(alarms, key: Keys.alarms) } }
    @Published var volumeGuardEnabled: Bool {
        didSet { UserDefaults.standard.set(volumeGuardEnabled, forKey: Keys.volumeGuard) }
    }

    @Published var isRinging = false
    @Published var ringingAlarm: WakeAlarm?
    @Published var lastError: String?

    var isOnboarded: Bool { account != nil && registeredTag != nil }

    private init() {
        volumeGuardEnabled = UserDefaults.standard.object(forKey: Keys.volumeGuard) as? Bool ?? true
        account = Self.restore(UserAccount.self, key: Keys.account)
        registeredTag = Self.restore(RegisteredTag.self, key: Keys.tag)
        alarms = Self.restore([WakeAlarm].self, key: Keys.alarms) ?? []
    }

    // MARK: Ringing

    /// Entry point from the alarm intents and the foreground alarm observer.
    func beginRinging(alarmKitID: UUID?) {
        guard !isRinging else { return }
        // Exact match only: a stale/unknown ID must never hijack another
        // alarm's session (RingingView and MusicService both tolerate nil).
        ringingAlarm = alarms.first { $0.id == alarmKitID }
        isRinging = true
        if volumeGuardEnabled {
            VolumeGuard.shared.engage()
        }
        let song = ringingAlarm?.song
        Task {
            await MusicService.shared.startAlarmPlayback(for: song)
        }
    }

    /// Called only after a successful NFC scan of the registered tag.
    func completeRinging() {
        MusicService.shared.stopPlayback()
        VolumeGuard.shared.disengage()
        if let alarm = ringingAlarm {
            AlarmScheduler.stopRinging(id: alarm.id)
            markSpentIfOneShot(id: alarm.id)
        }
        ringingAlarm = nil
        isRinging = false
    }

    /// A fired one-shot is consumed by AlarmKit; mirror that in the model so
    /// the UI never advertises an alarm that will not actually ring.
    private func markSpentIfOneShot(id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }),
              alarms[index].repeatDays.isEmpty else { return }
        alarms[index].isEnabled = false
        AlarmScheduler.cancel(id: id)
    }

    /// Watches AlarmKit while the app is alive so a foreground fire also goes
    /// through the NFC flow instead of just the system alert.
    func observeAlarmUpdates() async {
        for await updates in AlarmManager.shared.alarmUpdates {
            for alarm in updates where alarm.state == .alerting {
                handleAlerting(id: alarm.id)
            }
        }
    }

    /// On return to foreground: catch an alarm that fired while suspended.
    func sweepAlertingAlarms() {
        guard let systemAlarms = try? AlarmManager.shared.alarms else { return }
        for alarm in systemAlarms where alarm.state == .alerting {
            handleAlerting(id: alarm.id)
        }
    }

    private func handleAlerting(id: UUID) {
        try? AlarmManager.shared.stop(id: id)
        if isRinging {
            // A second alarm fired mid-ring: it can't get its own session, but
            // its one-shot registration was just consumed — record that.
            markSpentIfOneShot(id: id)
        } else {
            beginRinging(alarmKitID: id)
        }
    }

    /// Realign the model with AlarmKit: a one-shot that fired while we weren't
    /// looking (force-quit escape, reboot) is spent; a repeating alarm that
    /// vanished (authorization revoked and restored) is rescheduled.
    func reconcileAlarms() {
        guard let system = try? AlarmManager.shared.alarms else { return }
        let systemIDs = Set(system.map(\.id))
        for index in alarms.indices where alarms[index].isEnabled {
            let alarm = alarms[index]
            guard !systemIDs.contains(alarm.id), ringingAlarm?.id != alarm.id else { continue }
            if alarm.repeatDays.isEmpty {
                alarms[index].isEnabled = false
            } else {
                Task { await syncSchedule(for: alarm) }
            }
        }
    }

    // MARK: Alarm CRUD

    func upsertAlarm(_ alarm: WakeAlarm) async {
        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[index] = alarm
        } else {
            alarms.append(alarm)
        }
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        if let song = alarm.song {
            // Cache the DRM-free preview now so the alarm has real audio even
            // if the phone is offline when it fires.
            Task { await MusicService.shared.downloadPreviewIfNeeded(for: song) }
        }
        await syncSchedule(for: alarm)
    }

    func deleteAlarms(at offsets: IndexSet) {
        for index in offsets {
            AlarmScheduler.cancel(id: alarms[index].id)
        }
        alarms.remove(atOffsets: offsets)
    }

    func setAlarm(_ alarm: WakeAlarm, enabled: Bool) async {
        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[index].isEnabled = enabled
        await syncSchedule(for: alarms[index])
    }

    private func syncSchedule(for alarm: WakeAlarm) async {
        AlarmScheduler.cancel(id: alarm.id)
        guard alarm.isEnabled else { return }
        guard await AlarmScheduler.ensureAuthorized() else {
            disable(alarm.id)
            lastError = "Alarms aren't authorized. Enable WakeTag in Settings > Alarms."
            return
        }
        // The model may have changed while awaiting authorization (toggle
        // flipped, alarm deleted) — only schedule its current state.
        guard let current = alarms.first(where: { $0.id == alarm.id }), current.isEnabled else { return }
        do {
            try await AlarmScheduler.schedule(current)
            // ...and it may have changed again during the schedule round-trip.
            if !alarms.contains(where: { $0.id == current.id && $0.isEnabled }) {
                AlarmScheduler.cancel(id: current.id)
            }
        } catch {
            disable(current.id)
            lastError = "Couldn't schedule the alarm: \(error.localizedDescription)"
        }
    }

    /// Snap the toggle off when scheduling fails, so the UI never shows an
    /// enabled alarm that AlarmKit doesn't have.
    private func disable(_ id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = false
    }

    /// Schedules a one-shot alarm a minute out so the whole flow can be tried.
    func scheduleTestAlarm() async {
        let calendar = Calendar.current
        let fireDate = Date.now.addingTimeInterval(65)
        let components = calendar.dateComponents([.hour, .minute], from: fireDate)
        var alarm = WakeAlarm(hour: components.hour ?? 7, minute: components.minute ?? 0)
        alarm.label = "Test alarm"
        alarm.song = alarms.compactMap(\.song).first
        await upsertAlarm(alarm)
    }

    // MARK: Account

    func register(name: String, email: String, password: String) throws {
        try Credentials.register(email: email, password: password)
        account = UserAccount(name: name, email: email)
    }

    func signOut() {
        for alarm in alarms {
            AlarmScheduler.cancel(id: alarm.id)
        }
        if let email = account?.email {
            Credentials.remove(email: email)
        }
        alarms = []
        registeredTag = nil
        account = nil
    }

    // MARK: Persistence

    private func persist<T: Encodable>(_ value: T?, key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func restore<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
