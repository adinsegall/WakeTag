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
        ringingAlarm = alarms.first { $0.id == alarmKitID } ?? alarms.first
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
            if alarm.repeatDays.isEmpty, let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
                alarms[index].isEnabled = false
                AlarmScheduler.cancel(id: alarm.id)
            }
        }
        ringingAlarm = nil
        isRinging = false
    }

    /// Watches AlarmKit while the app is alive so a foreground fire also goes
    /// through the NFC flow instead of just the system alert.
    func observeAlarmUpdates() async {
        for await updates in AlarmManager.shared.alarmUpdates {
            for alarm in updates where alarm.state == .alerting {
                try? AlarmManager.shared.stop(id: alarm.id)
                beginRinging(alarmKitID: alarm.id)
            }
        }
    }

    /// On return to foreground: catch an alarm that fired while suspended.
    func sweepAlertingAlarms() {
        guard !isRinging, let systemAlarms = try? AlarmManager.shared.alarms else { return }
        for alarm in systemAlarms where alarm.state == .alerting {
            try? AlarmManager.shared.stop(id: alarm.id)
            beginRinging(alarmKitID: alarm.id)
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
            lastError = "Alarms aren't authorized. Enable WakeTag in Settings > Alarms."
            return
        }
        do {
            try await AlarmScheduler.schedule(alarm)
        } catch {
            lastError = "Couldn't schedule the alarm: \(error.localizedDescription)"
        }
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
