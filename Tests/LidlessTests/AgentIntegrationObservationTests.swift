import XCTest

final class AgentIntegrationObservationTests: XCTestCase {
    func testObservationsRoundTripOnlyForCurrentBridgeSchema() {
        let suite = "AgentIntegrationObservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let schema = HookBridgePayload.currentSchemaVersion
        let observed = AgentIntegrationObservations(
            bridgeSchemaVersion: schema,
            codexDesktop: true,
            codexCLI: false,
            claudeCode: true,
            claudeDesktop: true
        )

        store.saveAgentIntegrationObservations(observed)

        XCTAssertEqual(
            store.loadAgentIntegrationObservations(bridgeSchemaVersion: schema),
            observed
        )
        XCTAssertEqual(
            store.loadAgentIntegrationObservations(bridgeSchemaVersion: schema + 1),
            AgentIntegrationObservations(bridgeSchemaVersion: schema + 1)
        )
    }

    func testRemovingIntegrationsClearsRuntimeProof() {
        let suite = "AgentIntegrationObservationClearTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let schema = HookBridgePayload.currentSchemaVersion
        store.saveAgentIntegrationObservations(AgentIntegrationObservations(
            bridgeSchemaVersion: schema,
            codexDesktop: true,
            codexCLI: true,
            claudeCode: true
        ))

        store.clearAgentIntegrationObservations()

        XCTAssertEqual(
            store.loadAgentIntegrationObservations(bridgeSchemaVersion: schema),
            AgentIntegrationObservations(bridgeSchemaVersion: schema)
        )
    }

    func testObservationsStoredBeforeClaudeDesktopKeepOtherSurfaces() throws {
        let suite = "AgentIntegrationObservationLegacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = HookBridgePayload.currentSchemaVersion
        let legacy = #"{"bridgeSchemaVersion":\#(schema),"codexDesktop":true,"codexCLI":false,"claudeCode":true}"#
        defaults.set(Data(legacy.utf8), forKey: "agentIntegrationObservations")

        XCTAssertEqual(
            SettingsStore(defaults: defaults)
                .loadAgentIntegrationObservations(bridgeSchemaVersion: schema),
            AgentIntegrationObservations(
                bridgeSchemaVersion: schema,
                codexDesktop: true,
                codexCLI: false,
                claudeCode: true,
                claudeDesktop: false
            )
        )
    }
}
