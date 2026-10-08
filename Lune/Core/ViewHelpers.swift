import SwiftUI

extension View {
    /// Shows a system alert when there's an error.
    func errorAlert(_ title: LocalizedStringKey, error: Binding<Error?>) -> some View {
        alert(
            title,
            isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }
}

extension Text {
    /// Markdown built at runtime (for example, links with interpolated URLs).
    init(markdown: String) {
        self.init((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
    }
}

/// Lune's days: `yyyy-MM-dd` strings from the server, rolling over at 04:00 local time.
enum LuneDay {
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    static func date(_ day: String) -> Date? {
        keyFormatter.date(from: day)
    }

    static func key(_ date: Date) -> String {
        keyFormatter.string(from: date)
    }

    /// e.g. "Tuesday, October 7".
    static func title(_ day: String) -> String {
        date(day).map(titleFormatter.string(from:)) ?? day
    }

    /// e.g. "October 2026".
    static func month(_ day: String) -> String {
        date(day).map(monthFormatter.string(from:)) ?? day
    }

    /// Whole days between two day keys.
    static func daysBetween(_ earlier: String, _ later: String) -> Int {
        guard let a = date(earlier), let b = date(later) else { return 0 }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// The day before.
    static func previous(_ day: String) -> String {
        guard let date = date(day) else { return day }
        return key(Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: date) ?? date)
    }
}

/// Photo times in the system's relative style, like "yesterday at 9:14 PM" (respects the 12/24-hour setting).
enum PhotoTime {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter
    }()

    private static let standaloneFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// For use inside a sentence ("taken yesterday at 9:14 PM").
    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// For use on its own, e.g. as a list row's value ("Yesterday at 9:14 PM").
    static func standalone(_ date: Date) -> String {
        standaloneFormatter.string(from: date)
    }

    /// "Taken yesterday at 9:14 PM", or "Sent yesterday at 9:14 PM" when the capture time is unknown.
    static func caption(takenAt: Date?, uploadedAt: Date) -> String {
        if let takenAt {
            "Taken \(string(takenAt))"
        } else {
            "Sent \(string(uploadedAt))"
        }
    }
}

/// Instagram's username rules: 1–30 of a–z, 0–9, "." and "_"; no leading, trailing or doubled period.
enum Username {
    static let maxLength = 30
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._")

    /// What the field should hold while typing: lowercase, no "@", only allowed characters.
    static func clean(_ input: String) -> String {
        String(input.lowercased().filter(allowed.contains).prefix(maxLength))
    }

    /// Why a username isn't valid yet, or nil when it is.
    static func problem(_ username: String) -> String? {
        if username.isEmpty { return "Choose a username." }
        if username.hasPrefix(".") || username.hasSuffix(".") { return "Usernames can’t start or end with a period." }
        if username.contains("..") { return "Usernames can’t have two periods in a row." }
        return nil
    }
}
