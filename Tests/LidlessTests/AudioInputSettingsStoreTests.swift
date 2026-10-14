import Foundation
import XCTest

final class AudioInputSettingsStoreTests: XCTestCase {
    func testMissingMalformedAndOversizedConfigurationFallBackToEmpty() {
        withDefaults { store, defaults in
            XCTAssertEqual(store.loadAudioInputSwitchConfiguration(), .empty)

            defaults.set(Data("not-json".utf8), forKey: "audioInputSwitchConfiguration")
            XCTAssertEqual(store.loadAudioInputSwitchConfiguration(), .empty)

            defaults.set(Data(repeating: 0x41, count: 8 * 1024 + 1),
                         forKey: "audioInputSwitchConfiguration")
            XCTAssertEqual(store.loadAudioInputSwitchConfiguration(), .empty)
        }
    }

    func testConfigurationPersistsOpaqueUIDsAndLastKnownNames() {
        withDefaults { store, defaults in
            let configuration = AudioInputSwitchConfiguration(
                primary: AudioInputSelection(
                    uid: "BuiltInMicrophoneDevice",
                    lastKnownName: "MacBook Pro Microphone"
                ),
                secondary: AudioInputSelection(
                    uid: "AppleUSBAudioEngine:StudioDisplay",
                    lastKnownName: "Studio Display Microphone"
                )
            )

            store.saveAudioInputSwitchConfiguration(configuration)

            XCTAssertEqual(store.loadAudioInputSwitchConfiguration(), configuration)
            XCTAssertEqual(
                SettingsStore(defaults: defaults).loadAudioInputSwitchConfiguration(),
                configuration
            )
        }
    }

    func testDuplicateUIDIsSanitizedByClearingSecondarySelection() {
        withDefaults { store, _ in
            store.saveAudioInputSwitchConfiguration(
                AudioInputSwitchConfiguration(
                    primary: AudioInputSelection(uid: "same", lastKnownName: "Primary"),
                    secondary: AudioInputSelection(uid: "same", lastKnownName: "Secondary")
                )
            )

            XCTAssertEqual(
                store.loadAudioInputSwitchConfiguration(),
                AudioInputSwitchConfiguration(
                    primary: AudioInputSelection(uid: "same", lastKnownName: "Primary"),
                    secondary: nil
                )
            )
        }
    }

    func testSavingEmptyConfigurationRemovesStoredValue() {
        withDefaults { store, defaults in
            store.saveAudioInputSwitchConfiguration(
                AudioInputSwitchConfiguration(
                    primary: AudioInputSelection(uid: "one", lastKnownName: "One"),
                    secondary: nil
                )
            )
            XCTAssertNotNil(defaults.data(forKey: "audioInputSwitchConfiguration"))

            store.saveAudioInputSwitchConfiguration(.empty)

            XCTAssertNil(defaults.object(forKey: "audioInputSwitchConfiguration"))
            XCTAssertEqual(store.loadAudioInputSwitchConfiguration(), .empty)
        }
    }

    private func withDefaults(
        _ body: (SettingsStore, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "lidless.test.audio-input-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        try body(SettingsStore(defaults: defaults), defaults)
    }
}
