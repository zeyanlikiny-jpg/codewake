import Foundation

/// Durable proof that the current hook-bridge wire version has delivered a
/// real lifecycle event from each supported product surface. Configuration
/// health and runtime proof are deliberately separate: a valid JSON entry does
/// not prove that Codex/Claude actually launched the bridge.
public struct AgentIntegrationObservations: Codable, Equatable {
    public let bridgeSchemaVersion: Int
    public var codexDesktop: Bool
    public var codexCLI: Bool
    public var claudeCode: Bool

    public init(bridgeSchemaVersion: Int,
                codexDesktop: Bool = false,
                codexCLI: Bool = false,
                claudeCode: Bool = false) {
        self.bridgeSchemaVersion = bridgeSchemaVersion
        self.codexDesktop = codexDesktop
        self.codexCLI = codexCLI
        self.claudeCode = claudeCode
    }
}

/// Persists SafetySettings in UserDefaults. Returns `.default` until the user
/// has saved at least once (so first launch uses sane defaults, not zeros).
public struct SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let lowBattery   = "lowBatteryThreshold"
        static let onlyCharging = "onlyWhileCharging"
        static let pauseThermal = "pauseOnHighThermal"
        static let autoEnable   = "autoEnableWhenCharging"
        static let armed        = "keepAwakeArmed"
        static let seeded       = "settingsSeeded"
        static let autoOff      = "autoOffMinutes"
        static let onboarded    = "onboardingComplete"
        static let resumeOnboarding = "resumeOnboarding"
        static let helperBuild  = "lastRegisteredHelperBuild"
        static let helperRepairPending = "helperRegistrationRepairPending"
        static let aiSeeded     = "aiAutomationSettingsSeeded"
        static let aiEnabled    = "aiAutomationEnabled"
        static let aiBattery    = "aiAutomationAllowOnBattery"
        static let aiMaxHours   = "aiAutomationMaximumHours"
        static let aiWaitingReleaseDelay = "aiAutomationWaitingReleaseDelaySeconds"
        static let aiSleepDocked = "aiAutomationSleepWhileDocked"
        static let integrationObservations = "agentIntegrationObservations"
        static let agentRecovery = "agentStateRecoverySnapshot"
        static let appLanguage = "appLanguage"
        static let menuPopoverHeightMode = "menuPopoverHeightMode"
        static let keepDisplayAwakeDuringActivity = "keepDisplayAwakeDuringActivity"
        static let audioInputSwitchConfiguration = "audioInputSwitchConfiguration"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SafetySettings {
        guard defaults.bool(forKey: Key.seeded) else { return .default }
        return SafetySettings(
            lowBatteryThreshold: defaults.integer(forKey: Key.lowBattery),
            onlyWhileCharging: defaults.bool(forKey: Key.onlyCharging),
            pauseOnHighThermal: defaults.bool(forKey: Key.pauseThermal),
            autoEnableWhenCharging: defaults.bool(forKey: Key.autoEnable)
        )
    }

    public func save(_ settings: SafetySettings) {
        defaults.set(settings.lowBatteryThreshold, forKey: Key.lowBattery)
        defaults.set(settings.onlyWhileCharging, forKey: Key.onlyCharging)
        defaults.set(settings.pauseOnHighThermal, forKey: Key.pauseThermal)
        defaults.set(settings.autoEnableWhenCharging, forKey: Key.autoEnable)
        defaults.set(true, forKey: Key.seeded)
    }

    /// The master-toggle intent in auto mode: whether the user wants keep-awake
    /// armed (the live state is then gated by power + safety). Defaults to false.
    public func loadArmed() -> Bool {
        defaults.bool(forKey: Key.armed)
    }

    public func saveArmed(_ armed: Bool) {
        defaults.set(armed, forKey: Key.armed)
    }

    /// Auto-off duration in minutes (`0` = no auto-off). Defaults to 0.
    public func loadAutoOffMinutes() -> Int {
        defaults.integer(forKey: Key.autoOff)
    }

    public func saveAutoOffMinutes(_ minutes: Int) {
        defaults.set(minutes, forKey: Key.autoOff)
    }

    /// Whether the user has been through first-run onboarding. Defaults to false.
    public func loadOnboardingComplete() -> Bool {
        defaults.bool(forKey: Key.onboarded)
    }

    public func saveOnboardingComplete(_ complete: Bool) {
        defaults.set(complete, forKey: Key.onboarded)
    }

    /// Whether onboarding should be re-shown on the next launch — set when the app
    /// relaunches itself mid-onboarding (after the helper is enabled) so the flow
    /// resumes instead of being lost. Defaults to false.
    public func loadResumeOnboarding() -> Bool {
        defaults.bool(forKey: Key.resumeOnboarding)
    }

    public func saveResumeOnboarding(_ resume: Bool) {
        defaults.set(resume, forKey: Key.resumeOnboarding)
    }

    /// The app language is independent of the system language. Existing
    /// installs have no stored value, and malformed preferences can occur after
    /// manual defaults edits, so both cases deliberately fall back to Chinese.
    public func loadAppLanguage() -> AppLanguage {
        guard let rawValue = defaults.string(forKey: Key.appLanguage),
              let language = AppLanguage(rawValue: rawValue) else {
            return .simplifiedChinese
        }
        return language
    }

    public func saveAppLanguage(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Key.appLanguage)
    }

    /// How tall the menu-bar popover should be when it opens. Missing values
    /// (including existing installations) and malformed manual defaults edits
    /// both use the product default of showing all content when space permits.
    public func loadMenuPopoverHeightMode() -> MenuPopoverHeightMode {
        guard let rawValue = defaults.string(forKey: Key.menuPopoverHeightMode),
              let mode = MenuPopoverHeightMode(rawValue: rawValue) else {
            return .default
        }
        return mode
    }

    public func saveMenuPopoverHeightMode(_ mode: MenuPopoverHeightMode) {
        defaults.set(mode.rawValue, forKey: Key.menuPopoverHeightMode)
    }

    /// Whether eligible AI/manual activity should also prevent idle display
    /// sleep. This is deliberately independent of the privileged Helper's
    /// system-sleep settings and defaults to false for existing installs.
    /// Reject non-Boolean values so malformed manual defaults edits never turn
    /// the display policy on implicitly.
    public func loadKeepDisplayAwakeDuringActivity() -> Bool {
        guard let value = defaults.object(
            forKey: Key.keepDisplayAwakeDuringActivity
        ) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return false
        }
        return value.boolValue
    }

    public func saveKeepDisplayAwakeDuringActivity(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.keepDisplayAwakeDuringActivity)
    }

    /// The two user-selected system-input devices used by the menu's one-click
    /// switch. Core Audio object IDs are intentionally never persisted: only
    /// opaque device UIDs and last-known display names survive a relaunch or a
    /// temporary USB/Continuity disconnect.
    public func loadAudioInputSwitchConfiguration() -> AudioInputSwitchConfiguration {
        guard let data = defaults.data(forKey: Key.audioInputSwitchConfiguration),
              data.count <= 8 * 1024,
              let stored = try? JSONDecoder().decode(
                  AudioInputSwitchConfiguration.self,
                  from: data
              ) else {
            return .empty
        }
        return stored.sanitized()
    }

    public func saveAudioInputSwitchConfiguration(
        _ configuration: AudioInputSwitchConfiguration
    ) {
        let sanitized = configuration.sanitized()
        guard sanitized != .empty else {
            defaults.removeObject(forKey: Key.audioInputSwitchConfiguration)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sanitized),
              data.count <= 8 * 1024 else { return }
        guard defaults.data(forKey: Key.audioInputSwitchConfiguration) != data else { return }
        defaults.set(data, forKey: Key.audioInputSwitchConfiguration)
    }

    /// The app build (`CFBundleVersion`) for which the privileged helper was last
    /// (re-)registered. Used to refresh the launchd registration after an update,
    /// so the daemon keeps launching with the new binary's requirement. Empty
    /// until the first registration.
    public func loadLastHelperBuild() -> String {
        defaults.string(forKey: Key.helperBuild) ?? ""
    }

    public func saveLastHelperBuild(_ build: String) {
        defaults.set(build, forKey: Key.helperBuild)
    }

    /// True while an update repair may have removed the old launchd job but has
    /// not yet proved the replacement helper usable. This must survive an app
    /// crash or a failed `SMAppService.register()` call: without a registered
    /// KeepAlive daemon, a root lease journal would have no watchdog to restore
    /// `SleepDisabled`.
    public func loadHelperRegistrationRepairPending() -> Bool {
        defaults.bool(forKey: Key.helperRepairPending)
    }

    /// Force the safety marker to the preferences backing store before a repair
    /// is allowed to unregister launchd. A failed clear is conservative (the
    /// next launch simply validates/retries again); a failed set must abort the
    /// destructive half of the repair.
    @discardableResult
    public func saveHelperRegistrationRepairPending(_ pending: Bool) -> Bool {
        defaults.set(pending, forKey: Key.helperRepairPending)
        return defaults.synchronize()
    }

    /// AI automation is enabled by default, but remains inert until the user
    /// installs hooks and the privileged helper is approved. Battery operation
    /// always requires a separate explicit opt-in.
    public func loadAIAutomationSettings() -> AIAutomationSettings {
        // One-way migration: external-display completion must return control
        // to macOS. Removing the retired key also prevents a former `true`
        // value from resurfacing after an older/newer build transition.
        defaults.removeObject(forKey: Key.aiSleepDocked)
        guard defaults.bool(forKey: Key.aiSeeded) else { return .default }
        let waitingReleaseDelaySeconds: Int
        waitingReleaseDelaySeconds = (
            defaults.object(forKey: Key.aiWaitingReleaseDelay) as? NSNumber
        )?.intValue ?? AIAutomationSettings.defaultWaitingReleaseDelaySeconds
        return AIAutomationSettings(
            isEnabled: defaults.bool(forKey: Key.aiEnabled),
            allowOnBattery: defaults.bool(forKey: Key.aiBattery),
            maximumHours: defaults.integer(forKey: Key.aiMaxHours),
            waitingReleaseDelaySeconds: waitingReleaseDelaySeconds
        )
    }

    public func saveAIAutomationSettings(_ settings: AIAutomationSettings) {
        defaults.set(settings.isEnabled, forKey: Key.aiEnabled)
        defaults.set(settings.allowOnBattery, forKey: Key.aiBattery)
        defaults.set(settings.maximumHours, forKey: Key.aiMaxHours)
        defaults.set(
            settings.waitingReleaseDelaySeconds,
            forKey: Key.aiWaitingReleaseDelay
        )
        defaults.removeObject(forKey: Key.aiSleepDocked)
        defaults.set(true, forKey: Key.aiSeeded)
    }

    /// Runtime observations are scoped to the bridge schema. A bridge update
    /// must receive a fresh event before the UI calls that surface verified;
    /// otherwise a years-old observation could make a newly broken hook look
    /// healthy after an upgrade.
    public func loadAgentIntegrationObservations(
        bridgeSchemaVersion: Int
    ) -> AgentIntegrationObservations {
        guard let data = defaults.data(forKey: Key.integrationObservations),
              data.count <= 4 * 1024,
              let stored = try? JSONDecoder().decode(
                AgentIntegrationObservations.self,
                from: data
              ),
              stored.bridgeSchemaVersion == bridgeSchemaVersion else {
            return AgentIntegrationObservations(bridgeSchemaVersion: bridgeSchemaVersion)
        }
        return stored
    }

    public func saveAgentIntegrationObservations(
        _ observations: AgentIntegrationObservations
    ) {
        guard let data = try? JSONEncoder().encode(observations),
              data.count <= 4 * 1024 else { return }
        guard defaults.data(forKey: Key.integrationObservations) != data else { return }
        defaults.set(data, forKey: Key.integrationObservations)
    }

    public func clearAgentIntegrationObservations() {
        defaults.removeObject(forKey: Key.integrationObservations)
    }

    /// Crash/relaunch recovery stores only the privacy-minimized Agent state
    /// type. A hard size bound prevents corrupted defaults from growing app
    /// startup memory, and unchanged snapshots do not cause repeated writes.
    public func loadAgentRecoverySnapshot() -> AgentStateRecoverySnapshot? {
        guard let data = defaults.data(forKey: Key.agentRecovery),
              data.count <= 512 * 1024 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(AgentStateRecoverySnapshot.self, from: data)
    }

    public func saveAgentRecoverySnapshot(_ snapshot: AgentStateRecoverySnapshot) {
        if snapshot.sessions.isEmpty, snapshot.tombstones.isEmpty {
            defaults.removeObject(forKey: Key.agentRecovery)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              data.count <= 512 * 1024 else { return }
        guard defaults.data(forKey: Key.agentRecovery) != data else { return }
        defaults.set(data, forKey: Key.agentRecovery)
    }
}
