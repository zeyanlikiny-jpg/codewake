import XCTest

final class AIAutomationSettingsTests: XCTestCase {
    func testDefaultsAreEnabledACOnlyFourHours() {
        let settings = AIAutomationSettings.default
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.allowOnBattery)
        XCTAssertEqual(settings.maximumHours, 4)
        XCTAssertFalse(settings.sleepWhileDocked)
        XCTAssertEqual(settings.waitingReleaseDelaySeconds, 300)
        XCTAssertEqual(settings.waitingReleaseDelay, 300)
        XCTAssertEqual(settings.maximumDuration, 4 * 60 * 60)
        XCTAssertEqual(AIAutomationSettings.completionConfirmation, 5)
        XCTAssertEqual(AIAutomationSettings.waitingGrace, 5 * 60)
    }

    func testUnsupportedMaximumFallsBackToFourHours() {
        XCTAssertEqual(
            AIAutomationSettings(isEnabled: true, allowOnBattery: true, maximumHours: 24).maximumHours,
            4
        )
    }

    func testSettingsStoreRoundTripAndDefaults() {
        let suite = "AIAutomationSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.loadAIAutomationSettings(), .default)
        let custom = AIAutomationSettings(
            isEnabled: false,
            allowOnBattery: true,
            maximumHours: 8,
            waitingReleaseDelaySeconds: 900,
            sleepWhileDocked: true
        )
        store.saveAIAutomationSettings(custom)
        XCTAssertEqual(store.loadAIAutomationSettings(), custom)
        XCTAssertEqual(store.loadAIAutomationSettings().waitingReleaseDelaySeconds, 900)
        XCTAssertFalse(store.loadAIAutomationSettings().sleepWhileDocked)
        XCTAssertNil(defaults.object(forKey: "aiAutomationSleepWhileDocked"))
    }

    func testV1SettingsDecodePreservesChoicesAndMigratesNewPolicies() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "isEnabled": false,
            "allowOnBattery": true,
            "maximumHours": 8,
            "sleepWhileDocked": true,
        ])
        let migrated = try JSONDecoder().decode(AIAutomationSettings.self, from: data)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertTrue(migrated.allowOnBattery)
        XCTAssertEqual(migrated.maximumHours, 8)
        XCTAssertFalse(migrated.sleepWhileDocked)
        XCTAssertEqual(migrated.waitingReleaseDelaySeconds, 300)
    }

    func testAllWaitingReleaseDelayValuesAndPickerLabels() {
        let expected = [
            0: "Immediate",
            60: "1 minute",
            300: "5 minutes",
            600: "10 minutes",
            900: "15 minutes",
            1_800: "30 minutes",
        ]

        XCTAssertEqual(
            AIAutomationSettings.allowedWaitingReleaseDelaySeconds,
            [0, 60, 300, 600, 900, 1_800]
        )
        XCTAssertEqual(expected.count, 6, "The settings picker must expose all six options")
        for seconds in AIAutomationSettings.allowedWaitingReleaseDelaySeconds {
            let settings = AIAutomationSettings(
                isEnabled: true,
                allowOnBattery: false,
                maximumHours: 4,
                waitingReleaseDelaySeconds: seconds
            )
            XCTAssertEqual(settings.waitingReleaseDelaySeconds, seconds)
            XCTAssertEqual(
                AIAutomationSettings.waitingReleaseDelayLabel(seconds: seconds),
                expected[seconds]
            )
        }
    }

    func testMissingAndInvalidWaitingReleaseDelayMigrateToFiveMinutes() throws {
        let missingData = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "allowOnBattery": false,
            "maximumHours": 4,
        ])
        XCTAssertEqual(
            try JSONDecoder().decode(AIAutomationSettings.self, from: missingData)
                .waitingReleaseDelaySeconds,
            300
        )

        for invalid in [-1, 1, 301, 3_600] {
            let settings = AIAutomationSettings(
                isEnabled: true,
                allowOnBattery: false,
                maximumHours: 4,
                waitingReleaseDelaySeconds: invalid
            )
            XCTAssertEqual(settings.waitingReleaseDelaySeconds, 300)
        }

        var directlyMutated = AIAutomationSettings.default
        directlyMutated.waitingReleaseDelaySeconds = 301
        XCTAssertEqual(directlyMutated.waitingReleaseDelaySeconds, 300)
    }

    func testSettingsStoreMissingAndInvalidWaitingReleaseDelayMigrateToFiveMinutes() {
        let suite = "AIAutomationDelayMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        defaults.set(true, forKey: "aiAutomationSettingsSeeded")
        defaults.set(true, forKey: "aiAutomationEnabled")
        defaults.set(4, forKey: "aiAutomationMaximumHours")
        XCTAssertEqual(store.loadAIAutomationSettings().waitingReleaseDelaySeconds, 300)

        for invalid in [-1, 1, 301, 3_600] {
            defaults.set(invalid, forKey: "aiAutomationWaitingReleaseDelaySeconds")
            XCTAssertEqual(store.loadAIAutomationSettings().waitingReleaseDelaySeconds, 300)
        }

        defaults.set("not a delay", forKey: "aiAutomationWaitingReleaseDelaySeconds")
        XCTAssertEqual(store.loadAIAutomationSettings().waitingReleaseDelaySeconds, 300)
    }

    func testLegacyDockedSleepIsClearedOnceAndNeverRePersisted() {
        let suite = "AIAutomationDockedMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        defaults.set(true, forKey: "aiAutomationSettingsSeeded")
        defaults.set(true, forKey: "aiAutomationEnabled")
        defaults.set(4, forKey: "aiAutomationMaximumHours")
        defaults.set(true, forKey: "aiAutomationSleepWhileDocked")

        var migrated = store.loadAIAutomationSettings()
        XCTAssertFalse(migrated.sleepWhileDocked)
        XCTAssertNil(defaults.object(forKey: "aiAutomationSleepWhileDocked"))

        migrated.sleepWhileDocked = true
        XCTAssertFalse(migrated.sleepWhileDocked)
        store.saveAIAutomationSettings(migrated)
        XCTAssertNil(defaults.object(forKey: "aiAutomationSleepWhileDocked"))
    }

    func testEncodingOmitsRetiredDockedSleepAndIncludesWaitingDelay() throws {
        let settings = AIAutomationSettings(
            isEnabled: true,
            allowOnBattery: false,
            maximumHours: 4,
            waitingReleaseDelaySeconds: 600,
            sleepWhileDocked: true
        )
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["waitingReleaseDelaySeconds"] as? Int, 600)
        XCTAssertNil(object["sleepWhileDocked"])
    }

    func testHelperRegistrationRepairPendingPersistsUntilExplicitlyCleared() {
        let suite = "HelperRepairSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.loadHelperRegistrationRepairPending())
        store.saveHelperRegistrationRepairPending(true)
        XCTAssertTrue(SettingsStore(defaults: defaults).loadHelperRegistrationRepairPending())
        store.saveHelperRegistrationRepairPending(false)
        XCTAssertFalse(SettingsStore(defaults: defaults).loadHelperRegistrationRepairPending())
    }

    func testPrivacyMinimizedAgentRecoveryRoundTrip() throws {
        let suite = "AgentRecoverySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var machine = AgentStateMachine(maximumTurnDuration: 100, releaseGrace: 10)
        machine.ingest(AgentEvent(
            provider: .codex,
            sessionID: "opaque-session",
            turnID: "opaque-turn",
            eventKind: .promptSubmitted,
            timestamp: now
        ))

        let snapshot = machine.recoverySnapshot(at: now)
        store.saveAgentRecoverySnapshot(snapshot)

        XCTAssertEqual(store.loadAgentRecoverySnapshot(), snapshot)
        let encoded = try XCTUnwrap(defaults.data(forKey: "agentStateRecoverySnapshot"))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("prompt"))
        XCTAssertFalse(text.contains("cwd"))
        XCTAssertFalse(text.contains("source"))
    }
}
