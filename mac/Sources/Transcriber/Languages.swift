import Foundation

/// Canonical list of languages offered in the UI. The order here defines priority for
/// the multilingual allow-list fallback (the first allowed language is the default when
/// no conversation language has been established yet).
enum Languages {
    static let supported: [(code: String, name: String)] = [
        ("en", "English"),
        ("ru", "Russian"),
        ("uk", "Ukrainian"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("tr", "Turkish"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("he", "Hebrew"),
        ("hi", "Hindi"),
    ]

    static let withAuto: [(code: String, name: String)] =
        [("auto", "Auto-detect")] + supported

    static func name(for code: String) -> String {
        supported.first { $0.code == code }?.name ?? code.uppercased()
    }

    /// Returns the given codes in canonical order (used to give the allow-list a
    /// deterministic priority).
    static func ordered(_ codes: Set<String>) -> [String] {
        supported.map(\.code).filter { codes.contains($0) }
    }
}
