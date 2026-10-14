import Foundation

/// The languages that Lidless AI can display independently of the macOS
/// language. The persisted raw values intentionally match locale identifiers.
public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// Locale injected into each SwiftUI root so changing the language updates
    /// already-presented views without relaunching the app.
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// Explicit-language localization for AppKit-owned strings and dynamic text.
/// SwiftUI views should also inject ``AppLanguage/locale`` at their root so
/// regular localized `Text` values update through the environment.
public enum L10n {
    /// Return a catalog value only when the key actually exists.
    ///
    /// A translated brand name can legitimately equal its key (for example,
    /// `Codex`). Comparing the returned value with the key therefore cannot
    /// distinguish an existing translation from a missing entry.
    static func stringIfPresent(
        _ key: String,
        language: AppLanguage,
        bundle: Bundle = .main
    ) -> String? {
        let missingValue = "\u{F8FF}LidlessAI.MissingLocalization.\(key)\u{F8FF}"
        let value = localizedBundle(language: language, bundle: bundle)
            .localizedString(
                forKey: key,
                value: missingValue,
                table: nil
            )
        return value == missingValue ? nil : value
    }

    public static func string(
        _ key: String,
        defaultValue: String,
        language: AppLanguage,
        bundle: Bundle = .main
    ) -> String {
        stringIfPresent(
            key,
            language: language,
            bundle: bundle
        ) ?? defaultValue
    }

    private static func localizedBundle(
        language: AppLanguage,
        bundle: Bundle
    ) -> Bundle {
        let localizedBundle: Bundle
        if let path = bundle.path(
            forResource: language.rawValue,
            ofType: "lproj"
        ), let bundleForLanguage = Bundle(path: path) {
            localizedBundle = bundleForLanguage
        } else {
            localizedBundle = bundle
        }
        return localizedBundle
    }

    public static func format(
        _ key: String,
        defaultValue: String,
        language: AppLanguage,
        bundle: Bundle = .main,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(
                key,
                defaultValue: defaultValue,
                language: language,
                bundle: bundle
            ),
            locale: language.locale,
            arguments: arguments
        )
    }
}
