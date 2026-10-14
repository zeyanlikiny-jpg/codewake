# CodeWake · 醒码

CodeWake is a macOS menu-bar sleep manager for AI coding workflows. It keeps
the Mac awake while a supported agent is doing work and returns macOS to its
normal sleep policy after the work has ended.

This project is an independent fork of
[Lidless by Nghia Luong](https://github.com/nghialuong/Lidless). The original
MIT license and attribution are preserved in [LICENSE](LICENSE) and
[NOTICE](NOTICE). CodeWake modifications are maintained by Kenny at
[zeyanlikiny-jpg/codewake](https://github.com/zeyanlikiny-jpg/codewake).
The Chinese product name is **CodeWake · 醒码**; the English product name and app
file are **CodeWake** and **CodeWake.app**.

This repository publishes source code under the MIT license. It does not publish
a public installation package or an automatic-update channel. Build with your
own Apple Developer signing identity for local use; see
[docs/SIGNING.md](docs/SIGNING.md).

## What it does

- Preserves Lidless's manual closed-lid control, privileged helper, safety
  limits, auto-off timer, and launch-at-login support.
- Offers an optional, default-off display hold for active AI work and manual or
  timed keep-awake. Waiting, completion confirmation, and charging-only holds
  continue to follow the normal macOS display-idle policy.
- Adds a manual built-in-display blackout while a verified keep-awake lease is
  active. It lowers only the unique MacBook display to brightness zero and
  restores the sampled brightness after a new click or regular key press, or
  after any new physical input once the 1.5-second accidental-motion guard has
  expired. The action is unavailable whenever any external, Sidecar, AirPlay,
  or virtual display is present, or when display topology cannot be confirmed.
- Offers **Turn Off All Displays** for the built-in screen and all online
  external displays. Clicking closes the menu and requests macOS display sleep
  after 1.5 seconds. Mouse or keyboard input restores displays normally; existing
  system keep-awake rules continue to apply. The screen-on preference is only
  suspended until wake, and an existing built-in brightness blackout is restored
  before sending the request. Failed or unconfirmed requests show a menu warning.
- Detects Codex Desktop, Codex CLI, and Claude Code turns using lifecycle
  hooks. Codex's `agent-turn-complete` notification supplies the structured
  plan-complete boundary that the plan approval card needs.
- Acquires a keep-awake lease while an agent is working. A successful final
  `Stop` gets a cancelable five-second confirmation, then a closed Mac can sleep
  when no manual, timed, or charging hold remains, no external display is
  connected, and macOS clamshell conditions permit it.
- Treats waiting for user input separately from active work, including plan and
  permission prompts, with a configurable immediate/1/5/10/15/30-minute delay
  (five minutes by default).
- Keeps manual and AI-generated wake requests separate so finishing an AI task
  never cancels a user's manual keep-awake request.

Cursor Agent is reserved for a future integration; it is not installed or
advertised as supported yet.

## Hook integration and privacy

Hook installation is an explicit action in CodeWake. The installer
structurally merges its handlers into these files:

- Codex Desktop and CLI: `~/.codex/hooks.json`
- Codex turn-complete relay: `~/.codex/config.toml`
- Claude Code: `~/.claude/settings.json`

It validates each complete configuration before writing, preserves unknown
settings and third-party handlers, creates a backup before each change, is
idempotent, and removes only its exact handlers on uninstall. The Codex notify
relay forwards the user's existing notification command unchanged. Removal
uses a compare-before-restore check so a later user edit is never overwritten.

The installed executable lives at:

```text
~/Library/Application Support/Lidless AI/bin/LidlessAIHookBridge
```

The bridge reads the provider's official hook JSON on standard input but emits
only a privacy-minimized v3 schema over a current-user Unix socket:

```text
schemaVersion, provider, sessionID, turnID, eventKind, content-free waitingReason,
backgroundWork, backgroundWorkCount, opaque workToken, stopHookActive, timestamp
```

Prompt text, working directories, transcript paths, model names, tool inputs,
tool outputs, and assistant messages are never represented in the outgoing
type. The default socket is
`~/Library/Application Support/Lidless AI/runtime/events.sock`; the app creates
the runtime directory as `0700` and the socket as `0600`. If the app is not
listening, the bridge asks Launch Services to open CodeWake, retries only
within its one-second deadline, then exits successfully and silently so a hook
failure cannot interrupt an agent turn.

Codex's public hooks do not currently expose the manual-interrupt edge. While a
Codex turn is active, CodeWake therefore reconciles only that exact session and
turn against a bounded tail of Codex's local rollout journal. It recognizes only
`event_msg.turn_aborted` with reason `interrupted`, retains only the session ID,
turn ID, and timestamp, and never persists, uploads, or logs rollout content or
paths.
Unreadable, unsafe, or unfamiliar journal data fails closed and leaves the
keep-awake state unchanged. This compatibility fallback can be replaced by an
official cancellation hook when one becomes available.

The Settings window reports hook configuration separately from real runtime
proof. Codex Desktop, Codex CLI, and Claude Code are each marked observed only
after a current-schema event arrives with matching local process ancestry.
During an App-before-hooks rolling upgrade, schema-v1/v2 Prompt events remain a
conservative keep-awake signal, but legacy bridges are never marked observed and
their Stop can only restore normal sleep after the legacy grace; it cannot
request system sleep.
CPU use is diagnostic only: it never revives a waiting or completed turn and is
never treated as a completion signal.

The hook formats follow the official
[Codex hooks guide](https://learn.chatgpt.com/docs/hooks),
[Codex advanced configuration guide](https://learn.chatgpt.com/docs/config-file/config-advanced), and
[Claude Code hooks reference](https://code.claude.com/docs/en/hooks).

## macOS architecture

- **CodeWake** — SwiftUI `MenuBarExtra` app (macOS 13+, `LSUIElement`). It
  owns the optional, bounded user-session display-idle assertion.
- **LidlessHelper** — root LaunchDaemon registered with `SMAppService`; it owns
  the persistent `SleepDisabled` mutation and validates its XPC client identity.
- **LidlessAIHookBridge** — short-lived, privacy-filtering command used by
  Codex and Claude Code hooks.
- **LidlessDisplayWatchdog** — on-demand, non-root child process that owns the
  built-in-brightness transaction and crash recovery only while blackout or
  recovery is active. It is not a login item or LaunchAgent.
- **Shared logic** — deterministic agent state machine, wake-intent arbitration,
  configuration editor, safety evaluation, and tests.

Release bundle identifiers are `com.kenny.lidlessai`,
`com.kenny.lidlessai.helper`, `com.kenny.lidlessai.hookbridge`, and
`com.kenny.lidless-ai.displaywatchdog`. Debug builds use isolated identifiers.

These identifiers, the `LidlessHelper`, `LidlessAIHookBridge`, and
`LidlessDisplayWatchdog` executable names, the
`~/Library/Application Support/Lidless AI/` hooks/socket paths, and the
`LIDLESS_DEVELOPMENT_TEAM` build variable deliberately retain their old names.
Keeping these internal identities preserves existing preferences, helper
authorization, recovery records, and installed Codex/Claude hook configuration
when upgrading from Lidless AI. The generated project and user-facing app are
`CodeWake.xcodeproj` and `CodeWake.app`.

## Build and test

Requirements: Xcode command-line tools and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

`project.yml` is the source of truth; the generated Xcode project is ignored.
The developer team is intentionally not committed. Supply your own team through
`LIDLESS_DEVELOPMENT_TEAM` (or an uncommitted xcconfig) for a signed build:

```bash
xcodegen generate
xcodebuild build \
  -project 'CodeWake.xcodeproj' \
  -scheme CodeWake \
  -configuration Release \
  LIDLESS_DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

Unit tests can run without signing:

```bash
xcodebuild test \
  -project 'CodeWake.xcodeproj' \
  -scheme CodeWake-CI \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  LIDLESS_DEVELOPMENT_TEAM=
```

There is no inherited Sparkle feed, signing key, or automatic-update UI. An
unsigned source build can run tests and preview the UI, but it cannot validate
the privileged Helper or closed-lid behavior. A local signed installation must
verify the app and embedded tools use one team and matching version/build
handshakes. Signing alone does not establish Apple notarization or public
distribution acceptance. See [docs/SIGNING.md](docs/SIGNING.md) for local signing,
Helper acceptance, and the optional notarized DMG workflow.

## Menu-bar assets

The application icon uses the same laptop-and-`>_` mark on an indigo/purple
tile. Regenerate its 1024-pixel master and all ten macOS AppIcon sizes with:

```bash
bash scripts/make_iconset.sh
```

The menu-bar artwork uses the approved laptop-and-`>_` design. Its four variants
are committed under `Resources/Assets.xcassets/`: `MenubarLaptop`,
`MenubarLaptopActive`, `MenubarLaptopWorking`, and `MenubarLaptopAttention`.
Neutral variants are system-tinted templates; working/manual and attention
states keep the existing green/red colors. Generate all 1x/2x/3x PNG assets with:

```bash
swift scripts/make_menubar_task_icons.swift
```

The legacy asset names stay stable, and the icon does not change single-click
menu or double-click display-off behavior.

## Safety and real-device acceptance

Closed-lid work can generate heat and drain the battery. Keep the Mac ventilated
and prefer external power for long jobs. The charging, battery, thermal,
watchdog, and maximum-duration protections remain part of the product, but they
do not replace physical supervision during initial testing.

Closed-lid behavior depends on Mac hardware and macOS power policy. The first
supported release target is Apple Silicon on macOS 13 or later. Intel remains a
best-effort compile target and must not be advertised as supported until it has
passed the same tests on real Intel hardware. Before a release, verify on each
supported hardware and macOS combination:
helper registration and identity rejection, manual and AI leases, lid close and
reopen, battery/thermal cutoffs, crash recovery, reboot recovery, and sleep
restoration after the final grace period.

CodeWake never force-sleeps a Mac while an external display is online. When
the last AI hold ends it releases its own `SleepDisabled` lease and any active
display-idle assertion. The optional display hold only prevents idle dimming or
power-off while qualifying work is active; it does not wake an already-off
display, override the lock screen, or prevent a closed lid from turning the
built-in display off. Connecting or disconnecting a display does not itself
create or remove an AI wake source.

Quickly double-click the menu bar logo to turn off the built-in display using
the same action as the menu button. A single click still opens or closes the
menu. The shortcut requires the same active keep-awake lease and display
availability as the button.

The manual built-in-display blackout is separate from both sleep prevention and
the optional display-idle assertion. It dynamically resolves Apple's private
`DisplayServices` brightness functions, writes only a confirmed unique built-in
display, and keeps an atomic user-level recovery record before changing
brightness. For the first 1.5 seconds after the panel turns off, pointer
movement, dragging, and scrolling are ignored; another click or a regular key
press still restores immediately. After that window, any new physical input
restores the sampled value. CodeWake does not record input content or request
Accessibility/Input Monitoring permission. Private `DisplayServices` APIs have
no compatibility guarantee; this feature is intended for the current Developer
ID local-delivery workflow and is not claimed to be Mac App Store compatible.

## License

[MIT](LICENSE). Original Lidless copyright © 2026 Nghia Luong; CodeWake
modifications copyright © 2026 Kenny. Fork attribution and the modification
notice are in [NOTICE](NOTICE).
