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
