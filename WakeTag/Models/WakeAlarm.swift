import Foundation

/// A day of the week for alarm repeats.
enum Weekday: Int, CaseIterable, Codable, Identifiable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }

    var letter: String { String(shortName.prefix(1)) }

    var localeWeekday: Locale.Weekday {
        switch self {
        case .sunday: .sunday
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        }
    }

    static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The Apple Music song chosen for an alarm, flattened to plain data so the
/// rest of the app never needs to import MusicKit.
struct SongChoice: Codable, Equatable, Hashable {
    var id: String
    var title: String
    var artistName: String
    var artworkURL: URL?
    var previewURL: URL?
}

struct WakeAlarm: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var label: String = "Wake up"
    var hour: Int = 7
    var minute: Int = 0
    var repeatDays: Set<Weekday> = []
    var song: SongChoice?
    var isEnabled = true

    var timeString: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    var repeatDescription: String {
        if repeatDays.isEmpty { return "One time" }
        if repeatDays.count == 7 { return "Every day" }
        if repeatDays == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "Weekdays" }
        if repeatDays == [.saturday, .sunday] { return "Weekends" }
        return repeatDays.sorted().map(\.shortName).joined(separator: " ")
    }

    /// The next date this alarm will fire after the given date.
    func nextFireDate(after reference: Date = .now) -> Date? {
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        if repeatDays.isEmpty {
            return calendar.nextDate(after: reference, matching: components, matchingPolicy: .nextTime)
        }
        return repeatDays.compactMap { day -> Date? in
            var c = components
            c.weekday = day.rawValue
            return calendar.nextDate(after: reference, matching: c, matchingPolicy: .nextTime)
        }.min()
    }
}

/// A registered NFC tag whose factory UID is the only "key" that silences alarms.
struct RegisteredTag: Codable, Equatable {
    var uid: String
    var name: String = "My Tag"
    var registeredAt = Date()

    /// "04A2246AB37381" -> "04:A2:24:6A:B3:73:81" for display.
    var formattedUID: String {
        stride(from: 0, to: uid.count, by: 2).map { offset -> String in
            let start = uid.index(uid.startIndex, offsetBy: offset)
            let end = uid.index(start, offsetBy: 2, limitedBy: uid.endIndex) ?? uid.endIndex
            return String(uid[start..<end])
        }.joined(separator: ":")
    }
}
