import Foundation
import AppIntents
import AlarmKit

/// Runs when either button on the system alarm alert is tapped. Foregrounds
/// the app, silences the AlarmKit ring, and hands off to the in-app ringing
/// flow — where the chosen song plays until the registered NFC tag is scanned.
struct AlarmRingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "WakeTag Alarm"
    static var description = IntentDescription("Opens WakeTag so the alarm can be stopped with your NFC tag.")
    static var supportedModes: IntentModes = .foreground(.immediate)
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = UUID(uuidString: alarmID)
        if let id {
            try? AlarmManager.shared.stop(id: id)
        }
        AppModel.shared.beginRinging(alarmKitID: id)
        return .result()
    }
}
