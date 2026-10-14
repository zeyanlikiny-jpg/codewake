# Signing and local distribution

CodeWake embeds a privileged LaunchDaemon. A source build with signing
disabled is useful for automated tests and UI review, but it cannot be treated
as an installable closed-lid build: the app, helper, and XPC identity must all be
signed by the same Apple Developer team.

## Source publication and unsigned builds

The [CodeWake repository](https://github.com/zeyanlikiny-jpg/codewake) publishes
source code only. It does not provide a public signed installation package,
automatic-update channel, certificates, or private signing material.

You can generate the project, run every unit test, and build an unsigned preview.
That preview cannot establish privileged Helper operation or real closed-lid
acceptance. Use your own active Apple Developer membership and a matching local
signing identity to build an installable app. A successful Developer ID signature
is local signing evidence; it is not evidence that Apple notarization or public
distribution acceptance has completed.

## Local development signing

1. In Xcode, sign in under **Settings > Accounts** and confirm the team appears.
2. Create or download an **Apple Development** certificate for local device
   testing. For distribution outside the Mac App Store, also create a
   **Developer ID Application** certificate.
3. Find the 10-character Team ID on the Apple Developer membership page or in
   Xcode. Never commit certificates, private keys, passwords, or a personal
   Team ID to this repository.
4. Confirm macOS can see the identity:

   ```bash
   security find-identity -v -p codesigning
   ```

5. Generate and build with the team injected at build time:

   ```bash
   xcodegen generate
   xcodebuild build \
     -project 'CodeWake.xcodeproj' \
     -scheme CodeWake \
     -configuration Debug \
     LIDLESS_DEVELOPMENT_TEAM=YOUR_TEAM_ID
   ```

The Debug app uses `com.kenny.lidlessai.dev`; Release uses
`com.kenny.lidlessai`. Their helper labels and durable lease journals are also
separate. The renamed application is `CodeWake.app`, while the release bundle
ID, embedded tool names, existing hooks/data paths, and
`LIDLESS_DEVELOPMENT_TEAM` keep their legacy names for upgrade compatibility.

## Helper acceptance

On the first signed run, install the Helper from onboarding and approve it in
**System Settings > General > Login Items & Extensions** if macOS asks. Verify
all of these before a real lid-close test:

macOS can also request approval again while repairing a stale Helper after an
app update. Finish that approval before leaving the Mac unattended. The repair
marker and root journal deliberately fail closed until the replacement daemon
can run; the app cannot bypass this system authorization step.

- the app, `LidlessHelper`, `LidlessAIHookBridge`, and
  `LidlessDisplayWatchdog` report the expected team, version, build, and
  architecture set;
- the generated LaunchDaemon plist contains the matching app ID, helper ID,
  allowed Team ID, `RunAtLoad=true`, and `KeepAlive=true`;
- an unrelated or differently signed client is rejected by XPC;
- releasing the last lease restores the original `SleepDisabled` baseline.

Use external power on a ventilated desk for the first closed-lid run. Never test
this inside a bag or other enclosed space.

## Optional signed and notarized DMG

This is an optional local packaging workflow, separate from the source-only
GitHub publication. After a **Developer ID Application** identity and a notarytool
keychain profile are ready, run:

```bash
LIDLESS_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
NOTARY_PROFILE=YOUR_NOTARY_KEYCHAIN_PROFILE \
DMG_SIGNING_IDENTITY='Developer ID Application: Name (YOUR_TEAM_ID)' \
./scripts/release.sh
```

The script archives and exports the app, notarizes and staples the app, then
creates, signs, notarizes, staples, and Gatekeeper-checks the DMG. It does not
publish an update feed or upload a release.

Do not describe a package as notarized until the Apple notary result, stapling,
and Gatekeeper assessment have all succeeded. Real-device acceptance is also
separate: universal compilation alone does not establish Intel support.
