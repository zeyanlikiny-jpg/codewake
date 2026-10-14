import Foundation
import XCTest

final class MenuPopoverHeightModeTests: XCTestCase {
    func testCasesExposeStableSemanticRawValuesAndDefault() {
        XCTAssertEqual(
            MenuPopoverHeightMode.allCases,
            [.thirtyPercentTaller, .showAll]
        )
        XCTAssertEqual(
            MenuPopoverHeightMode.thirtyPercentTaller.rawValue,
            "thirtyPercentTaller"
        )
        XCTAssertEqual(MenuPopoverHeightMode.showAll.rawValue, "showAll")
        XCTAssertEqual(MenuPopoverHeightMode.default, .showAll)
        XCTAssertEqual(
            MenuPopoverHeightMode.thirtyPercentTaller.id,
            "thirtyPercentTaller"
        )
        XCTAssertEqual(MenuPopoverHeightMode.showAll.id, "showAll")
    }

    func testMissingAndInvalidStoredValuesFallBackToShowAll() {
        withStore { store, defaults in
            XCTAssertEqual(store.loadMenuPopoverHeightMode(), .showAll)

            defaults.set("unsupported", forKey: "menuPopoverHeightMode")
            XCTAssertEqual(store.loadMenuPopoverHeightMode(), .showAll)

            defaults.set(30, forKey: "menuPopoverHeightMode")
            XCTAssertEqual(store.loadMenuPopoverHeightMode(), .showAll)
        }
    }

    func testBothModesRoundTripAcrossStoreInstances() {
        withStore { store, defaults in
            store.saveMenuPopoverHeightMode(.thirtyPercentTaller)
            XCTAssertEqual(
                SettingsStore(defaults: defaults).loadMenuPopoverHeightMode(),
                .thirtyPercentTaller
            )
            XCTAssertEqual(
                defaults.string(forKey: "menuPopoverHeightMode"),
                "thirtyPercentTaller"
            )

            store.saveMenuPopoverHeightMode(.showAll)
            XCTAssertEqual(
                SettingsStore(defaults: defaults).loadMenuPopoverHeightMode(),
                .showAll
            )
            XCTAssertEqual(
                defaults.string(forKey: "menuPopoverHeightMode"),
                "showAll"
            )
        }
    }

    func testMenuHeightPreferenceIsIndependentOfOtherSettings() {
        withStore { store, defaults in
            store.saveAppLanguage(.english)
            store.saveKeepDisplayAwakeDuringActivity(true)

            store.saveMenuPopoverHeightMode(.thirtyPercentTaller)

            XCTAssertEqual(store.loadAppLanguage(), .english)
            XCTAssertTrue(store.loadKeepDisplayAwakeDuringActivity())
            XCTAssertEqual(
                store.loadMenuPopoverHeightMode(),
                .thirtyPercentTaller
            )

            store.saveAppLanguage(.simplifiedChinese)
            store.saveKeepDisplayAwakeDuringActivity(false)

            let reloaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(
                reloaded.loadMenuPopoverHeightMode(),
                .thirtyPercentTaller
            )
        }
    }

    private func withStore(
        _ body: (SettingsStore, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "lidless.test.menu-popover-height.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        try body(SettingsStore(defaults: defaults), defaults)
    }
}
