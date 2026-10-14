import XCTest

final class AppLanguageTests: XCTestCase {
    func testRawValuesAndLocalesMatchSupportedLanguageIdentifiers() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.rawValue, "zh-Hans")
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.english.rawValue, "en")
        XCTAssertEqual(AppLanguage.english.locale.identifier, "en")
        XCTAssertEqual(AppLanguage.allCases, [.simplifiedChinese, .english])
    }

    func testMissingLanguageDefaultsToSimplifiedChinese() {
        withStore { store, _ in
            XCTAssertEqual(store.loadAppLanguage(), .simplifiedChinese)
        }
    }

    func testInvalidLanguageDefaultsToSimplifiedChinese() {
        withStore { store, defaults in
            defaults.set("fr", forKey: "appLanguage")
            XCTAssertEqual(store.loadAppLanguage(), .simplifiedChinese)

            defaults.set(42, forKey: "appLanguage")
            XCTAssertEqual(store.loadAppLanguage(), .simplifiedChinese)
        }
    }

    func testLanguageRoundTripsAcrossStoreInstances() {
        withStore { store, defaults in
            store.saveAppLanguage(.english)
            XCTAssertEqual(
                SettingsStore(defaults: defaults).loadAppLanguage(),
                .english
            )

            store.saveAppLanguage(.simplifiedChinese)
            XCTAssertEqual(
                SettingsStore(defaults: defaults).loadAppLanguage(),
                .simplifiedChinese
            )
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "zh-Hans")
        }
    }

    func testLocalizationFallsBackAndFormatsWithSelectedLocale() {
        let missingKey = "test.missing.\(UUID().uuidString)"

        XCTAssertEqual(
            L10n.string(
                missingKey,
                defaultValue: "Fallback",
                language: .simplifiedChinese,
                bundle: Bundle(for: Self.self)
            ),
            "Fallback"
        )
        XCTAssertEqual(
            L10n.format(
                missingKey,
                defaultValue: "%d tasks",
                language: .english,
                bundle: Bundle(for: Self.self),
                3
            ),
            "3 tasks"
        )
    }

    private func withStore(
        _ body: (SettingsStore, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "lidless.test.app-language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SettingsStore(defaults: defaults), defaults)
    }
}
