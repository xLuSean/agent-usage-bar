import Foundation

public enum TimeFormatting {

    static func usesTraditionalChinese(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "zh"
    }

    /// Local time of day. Deliberately built per call rather than cached in a
    /// static formatter, so a time zone change between refreshes is reflected
    /// instead of being frozen at launch.
    public static func timeOfDay(_ date: Date, locale: Locale = Locale(identifier: "en_US"), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func dateAndTime(_ date: Date, locale: Locale = Locale(identifier: "en_US"), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Relative distance, e.g. "3 小時" / "12 分鐘".
    ///
    /// A reset time already in the past is normal — the window rolled over between
    /// the fetch and now — so it reports "已過" rather than a negative duration.
    public static func relative(from now: Date, to target: Date, locale: Locale = Locale(identifier: "en_US")) -> String {
        let seconds = target.timeIntervalSince(now)
        guard seconds > 0 else {
            return usesTraditionalChinese(locale) ? "已過" : "passed"
        }
        let formatter = DateComponentsFormatter()
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = locale
            return calendar
        }()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        return formatter.string(from: seconds)
            ?? (usesTraditionalChinese(locale) ? "\(Int(seconds / 60)) 分鐘" : "\(Int(seconds / 60)) min")
    }

    /// A reset time the reader can actually place.
    ///
    /// A time alone is enough for a window resetting within the day. For a seven-day
    /// window "11:59 AM" is unreadable — it could be tomorrow or six days out — so
    /// anything past today carries the date, and everything carries how far away it is.
    public static func resetDescription(
        _ resetsAt: Date,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let clock = calendar.isDate(resetsAt, inSameDayAs: now)
            ? timeOfDay(resetsAt, locale: locale, timeZone: timeZone)
            : dateAndTime(resetsAt, locale: locale, timeZone: timeZone)
        guard resetsAt > now else { return clock }
        let distance = relative(from: now, to: resetsAt, locale: locale)
        return usesTraditionalChinese(locale)
            ? "\(clock)（\(distance)後）"
            : "\(clock) (in \(distance))"
    }

    /// ISO 8601 with fractional seconds and an offset, which is what `resets_at`
    /// looks like in practice (`2026-08-18T19:40:00.427101+00:00`).
    /// Both fractional and whole-second forms are accepted because the plan
    /// requires tolerating either.
    public static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
