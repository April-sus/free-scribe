import Foundation

/// The languages the local translation model handles.
///
/// MADLAD-400 covers 492 targets, of which these are the ones the recogniser can
/// also hear — 98 of its 100. A language that cannot be dictated is useless as a
/// target, because there would be nothing to translate.
///
/// Named `M2M` for the model that came first; the type is the list, not the model.
public enum M2M {
    public static let languages = [
        "en", "zh", "es", "hi", "ar", "pt", "ru", "ja", "de", "fr", "ko", "it",
        "tr", "pl", "nl", "id", "vi", "th", "sv", "cs", "el", "he", "uk", "ro",
        "da", "fi", "no", "hu", "ta", "ur", "bn", "ms", "fa", "ca", "hr", "bg",
        "sk", "sl", "lt", "lv", "et", "sr", "az", "kk", "uz", "hy", "ka", "sq",
        "mk", "bs", "is", "cy", "ga", "gl", "eu", "af", "sw", "am", "yo", "ha",
        "so", "zu", "ml", "te", "kn", "mr", "gu", "pa", "si", "ne", "km", "lo",
        "my", "mn", "su", "mg", "mt", "lb", "fo", "br", "la", "yi", "be", "tg",
        "tk", "tt", "ba", "ps", "sd", "sa", "bo", "ht", "ln", "sn", "haw", "mi",
        "as", "nn",
    ]

    public static func supports(_ code: String) -> Bool {
        languages.contains(code)
    }
}
