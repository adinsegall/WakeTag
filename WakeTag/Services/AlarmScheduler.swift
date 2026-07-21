import Foundation
import AlarmKit
import SwiftUI

/// Empty metadata: WakeTag keeps alarm details in its own model and only needs
/// AlarmKit's system alert UI.
struct WakeMetadata: AlarmMetadata {
    init() {}
}

/// Thin wrapper over AlarmKit. Alarms are scheduled under the WakeAlarm's UUID
/// so the model, the system alarm, and the ring intents all share one ID.
enum AlarmScheduler {

    static var authorizationState: AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    /// Returns true when authorized, prompting the user if not yet determined.
    static func ensureAuthorized() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let state = try? await AlarmManager.shared.requestAuthorization()
            return state == .authorized
        @unknown default:
            return false
        }
    }

    static func schedule(_ alarm: WakeAlarm) async throws {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: alarm.label),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
            secondaryButton: AlarmButton(text: "Scan Tag", textColor: .white, systemImageName: "dot.radiowaves.up.forward"),
            secondaryButtonBehavior: .custom)

        let attributes = AlarmAttributes<WakeMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: WakeMetadata(),
            tintColor: Color.orange)

        let time = Alarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute)
        let schedule: Alarm.Schedule
        if alarm.repeatDays.isEmpty {
            schedule = .relative(.init(time: time, repeats: .never))
        } else {
            schedule = .relative(.init(time: time, repeats: .weekly(alarm.repeatDays.sorted().map(\.localeWeekday))))
        }

        // Both buttons route through the same foregrounding intent: even the
        // system "Stop" opens the app, where the music starts and only the
        // registered NFC tag can end it.
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: schedule,
            attributes: attributes,
            stopIntent: AlarmRingIntent(alarmID: alarm.id.uuidString),
            secondaryIntent: AlarmRingIntent(alarmID: alarm.id.uuidString),
            sound: .default)

        _ = try await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
    }

    static func cancel(id: UUID) {
        try? AlarmManager.shared.cancel(id: id)
    }

    static func stopRinging(id: UUID) {
        try? AlarmManager.shared.stop(id: id)
    }
}
