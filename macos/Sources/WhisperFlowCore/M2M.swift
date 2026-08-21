import Foundation

/// The languages the local translation model handles.
///
/// M2M-100 covers 100 languages and the recogniser covers 100, but they are not
/// the same hundred — these are the ones both agree on, which is what can actually
/// be dictated and then translated.
public enum M2M {
    public static let languages = [
        "af", "am", "ar", "az", "ba", "be", "bg", "bn", "bs", "ca", "cs", "cy", "da",
        "de", "el", "en", "es", "et", "fa", "fi", "fr", "ga", "gl", "gu", "ha", "he",
        "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja", "jv", "ka", "kk", "km",
        "kn", "ko", "lb", "ln", "lo", "lt", "lv", "mg", "mk", "ml", "mn", "mr", "ms",
        "my", "ne", "nl", "no", "ns", "oc", "or", "pa", "pl", "ps", "pt", "ro", "ru",
        "sd", "si", "sk", "sl", "so", "sq", "sr", "su", "sv", "sw", "ta", "th", "tl",
        "tr", "uk", "ur", "uz", "vi", "yo", "zh", "zu",
    ]

    public static func supports(_ code: String) -> Bool {
        languages.contains(code)
    }
}
