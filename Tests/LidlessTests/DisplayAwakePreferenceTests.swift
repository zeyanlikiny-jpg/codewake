import Foundation
import XCTest

final class DisplayAwakePreferenceTests: XCTestCase {
    func testDisplayAwakePreferenceDefaultsToOffWhenMissingOrMalformed() {
        withDefaults { store, defaults in
            XCTAssertFalse(store.loadKeepDisplayAwakeDuringActivity())

            defaults.set("true", forKey: "keepDisplayAwakeDuringActivity")
            XCTAssertFalse(store.loadKeepDisplayAwakeDuringActivity())

            defaults.set(1, forKey: "keepDisplayAwakeDuringActivity")
            XCTAssertFalse(store.loadKeepDisplayAwakeDuringActivity())
        }
    }

    func testDisplayAwakePreferencePersistsIndependently() {
        withDefaults { store, defaults in
            store.saveKeepDisplayAwakeDuringActivity(true)

            XCTAssertTrue(store.loadKeepDisplayAwakeDuringActivity())
            XCTAssertTrue(
                SettingsStore(defaults: defaults)
                    .loadKeepDisplayAwakeDuringActivity()
            )

            store.saveKeepDisplayAwakeDuringActivity(false)
            XCTAssertFalse(store.loadKeepDisplayAwakeDuringActivity())
        }
    }

    private func withDefaults(
        _ body: (SettingsStore, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "lidless.test.display-awake.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        try body(SettingsStore(defaults: defaults), defaults)
    }
}
