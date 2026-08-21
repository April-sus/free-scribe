import Foundation

/// The languages the recogniser understands, named the way their speakers name
/// them — "Français", not "French".
///
/// The list is Whisper's own: it is the ceiling on what can be dictated, whatever
/// any later translation step supports. Names come from Foundation rather than a
/// hand-written table, so they are correct and need no upkeep.
public enum Languages {
    /// Whisper's supported codes, most spoken first so the common ones are near
    /// the top of a long menu.
    public static let codes = [
        "en", "zh", "es", "hi", "ar", "pt", "ru", "ja", "de", "fr", "ko", "it",
        "tr", "pl", "nl", "id", "vi", "th", "sv", "cs", "el", "he", "uk", "ro",
        "da", "fi", "no", "hu", "ta", "ur", "bn", "ms", "fa", "ca", "hr", "bg",
        "sk", "sl", "lt", "lv", "et", "sr", "az", "kk", "uz", "hy", "ka", "sq",
        "mk", "bs", "is", "cy", "ga", "gl", "eu", "af", "sw", "am", "yo", "ha",
        "so", "zu", "ml", "te", "kn", "mr", "gu", "pa", "si", "ne", "km", "lo",
        "my", "mn", "tl", "jw", "su", "mg", "mt", "lb", "fo", "br", "la", "yi",
        "be", "tg", "tk", "tt", "ba", "ps", "sd", "sa", "bo", "ht", "ln", "sn",
        "haw", "mi", "as", "nn",
    ]

    public struct Language: Identifiable, Sendable, Hashable {
        public let code: String
        /// As its own speakers write it.
        public let endonym: String
        /// In the reader's language, for searching and for disambiguating.
        public let localised: String

        public var id: String { code }

        /// "Français" on its own when the two agree, "Français — French" otherwise,
        /// so somebody who cannot read the script can still find the entry.
        public var label: String {
            endonym.caseInsensitiveCompare(localised) == .orderedSame
                ? endonym
                : "\(endonym) — \(localised)"
        }
    }

    public static func all(displayedIn locale: Locale = .current) -> [Language] {
        codes.map { code in
            Language(
                code: code,
                endonym: Locale(identifier: code).localizedString(forLanguageCode: code) ?? code,
                localised: locale.localizedString(forLanguageCode: code) ?? code
            )
        }
    }

    /// The language the machine is set to, when the recogniser knows it — a better
    /// starting point than assuming English.
    public static func systemDefault() -> String? {
        guard let code = Locale.current.language.languageCode?.identifier else { return nil }
        return codes.contains(code) ? code : nil
    }
}
