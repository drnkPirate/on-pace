import Foundation

enum UsageFormat {
    static let locale = Locale(identifier: "en_US")

    static func euro(_ amount: Double) -> String {
        "≈ " + amount.formatted(.currency(code: "EUR").locale(.current))
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
