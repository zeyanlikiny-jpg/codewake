import XCTest

/// Tests for the helper's identity and the code signing requirement it demands
/// of anything connecting to it.
final class HelperIdentityTests: XCTestCase {

    func testDefaultRuntimeIdentityIsKennyAndFailsClosedWithoutATeam() {
        let identity = LidlessHelper.configuredPeerIdentity(
            environment: [:], infoDictionary: [:], machLabel: nil)
        XCTAssertEqual(identity.appBundleID, "com.kenny.lidlessai")
        XCTAssertNil(identity.teamID)
        XCTAssertEqual(LidlessHelper.runtimeFallbackLabel,
                       "com.kenny.lidlessai.helper")
    }

    func testRuntimeIdentityAcceptsExactEnvironmentInjection() {
        let identity = LidlessHelper.configuredPeerIdentity(
            environment: [
                LidlessHelper.allowedAppBundleIDEnvKey: "com.kenny.lidlessai.dev",
                LidlessHelper.allowedTeamIDEnvKey: "KENNYTEAM1"
            ],
            infoDictionary: [:],
            machLabel: "ignored.bundle.helper")
        XCTAssertEqual(identity,
                       LidlessHelperPeerIdentity(appBundleID: "com.kenny.lidlessai.dev",
                                                 teamID: "KENNYTEAM1"))
    }

    func testProtocolCapabilityUsesExistingVersionSelector() {
        XCTAssertEqual(
            LidlessHelper.protocolVersion(from: LidlessHelper.currentVersionAdvertisement),
            LidlessHelper.currentProtocolVersion
        )
        XCTAssertNil(LidlessHelper.protocolVersion(from: "0.2.0"),
                     "a legacy helper must never be sent a v2 selector")
        XCTAssertNil(LidlessHelper.protocolVersion(from: "0.2.0;protocol="))
        XCTAssertNil(LidlessHelper.protocolVersion(from: "0.2.0;protocol=2-extra"))
    }

    func testBuildUpgradeRequiresExactCurrentHelperAdvertisement() {
        XCTAssertEqual(
            LidlessHelper.currentVersionAdvertisement,
            "0.2.17+22;protocol=2"
        )
        XCTAssertTrue(LidlessHelper.isCurrentVersionAdvertisement(
            LidlessHelper.currentVersionAdvertisement
        ))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement(nil))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement("0.2.16+20;protocol=2"))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement("0.1.3"))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement("0.2.0"))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement("0.2.0;protocol=2"))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement("0.3.0;protocol=2"))
        XCTAssertFalse(LidlessHelper.isCurrentVersionAdvertisement("0.2.0;protocol=1"))
    }

    func testManagerReleaseRouteNeverSendsV2SelectorToLegacyHelper() {
        XCTAssertEqual(
            LidlessHelper.releaseTransportRoute(for: "0.2.0"),
            .legacyRelease
        )
        XCTAssertEqual(
            LidlessHelper.releaseTransportRoute(for: nil),
            .legacyRelease
        )
        XCTAssertEqual(
            LidlessHelper.releaseTransportRoute(
                for: LidlessHelper.currentVersionAdvertisement
            ),
            .conditionalSleepV2
        )
    }

    func testAppBundleIDIsInverseOfLabel() {
        for bundleID in ["com.kenny.lidlessai", "com.kenny.lidlessai.dev"] {
            let label = LidlessHelper.label(appBundleID: bundleID)
            XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: label), bundleID)
        }
    }

    /// The fallback label has to round-trip too — it's what the requirement is
    /// built from when the environment variable is missing, and a wrong answer
    /// there would have the helper demand an app that doesn't exist, locking out
    /// the real one.
    func testAppBundleIDHandlesFallbackLabel() {
        XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: LidlessHelper.fallbackLabel),
                       "com.kenny.lidlessai")
    }

    func testAppBundleIDLeavesUnexpectedLabelAlone() {
        XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: "com.example.thing"),
                       "com.example.thing")
        XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: ""), "")
    }

    /// Each clause closes a hole the other two leave open: identity alone admits
    /// an impostor using the name, the anchor alone admits every Apple-signed
    /// app, the team alone admits anything else we ship.
    func testRequirementPinsIdentityAnchorAndTeam() {
        let requirement = LidlessHelper.codeSigningRequirement(
            appBundleID: "com.kenny.lidlessai", teamID: "KENNYTEAM1")
        XCTAssertTrue(requirement.contains("identifier \"com.kenny.lidlessai\""))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"KENNYTEAM1\""))
    }

    /// The `.dev` and release builds must not satisfy each other's requirement —
    /// keeping their daemons isolated is the whole point of the separate ids.
    func testRequirementDiffersBetweenDebugAndReleaseIdentifiers() {
        XCTAssertNotEqual(
            LidlessHelper.codeSigningRequirement(appBundleID: "com.kenny.lidlessai"),
            LidlessHelper.codeSigningRequirement(appBundleID: "com.kenny.lidlessai.dev")
        )
    }

    /// A malformed requirement throws an Objective-C exception where it's set,
    /// which in the helper means dying on every incoming connection. Keep it to
    /// one line with nothing stray in it.
    func testRequirementIsASingleNonEmptyLine() {
        let requirement = LidlessHelper.codeSigningRequirement(appBundleID: "com.kenny.lidlessai")
        XCTAssertFalse(requirement.contains("\n"))
        XCTAssertFalse(requirement.isEmpty)
    }

    /// The requirement the daemon builds must match the app that will call it.
    /// These are derived on opposite sides of the XPC boundary from different
    /// inputs — the helper from its launchd label, the app from its bundle id —
    /// so a drift between them locks the app out of its own helper.
    func testRequirementFromLabelMatchesRequirementFromBundleID() {
        for bundleID in ["com.kenny.lidlessai", "com.kenny.lidlessai.dev"] {
            let label = LidlessHelper.label(appBundleID: bundleID)
            XCTAssertEqual(
                LidlessHelper.codeSigningRequirement(appBundleID: LidlessHelper.appBundleID(fromLabel: label)),
                LidlessHelper.codeSigningRequirement(appBundleID: bundleID)
            )
        }
    }
}
