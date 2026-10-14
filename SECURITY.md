# Security Policy

## Supported versions

CodeWake is an independent open-source fork. Security fixes land on the latest
`main` at [zeyanlikiny-jpg/codewake](https://github.com/zeyanlikiny-jpg/codewake).
This repository publishes source code; there is no public signed installation
package or automatic-update channel.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through
[CodeWake private vulnerability reporting](https://github.com/zeyanlikiny-jpg/codewake/security/advisories/new).
Do not send sensitive reports to the original Lidless maintainer: this fork has
a different owner and signing identity.

Please include steps to reproduce, the macOS version, and the impact you observed.
I'll acknowledge as soon as I can and keep you posted on a fix.

## Security-relevant surface

CodeWake is not sandboxed and installs a **privileged background helper** to do its job,
so a few areas matter more than usual:

- **Root LaunchDaemon** (`LidlessHelper`) registered via `SMAppService`. It runs as
  root and toggles the macOS `SleepDisabled` flag (`IOPMrootDomain`).
- **XPC interface** (`LidlessHelperProtocol`) between the menu-bar app and the helper —
  the only channel the app uses to change power state.
- **Durable lease and heartbeat watchdog**: the helper records baseline and
  ownership before changing `SleepDisabled`, recovers incomplete or stale leases
  on startup, and restores owned state after reboot, expiry, or more than 90
  seconds without a heartbeat. A same-boot helper restart preserves a fresh,
  active lease until it is released or reaches one of those recovery boundaries.
- **Local agent bridge**: hooks send privacy-minimized schema-v3 events over a
  current-user Unix socket. The schema contains `schemaVersion`, `provider`,
  `sessionID`, optional `turnID`, `eventKind`, content-free `waitingReason`,
  `backgroundWork`, `backgroundWorkCount`, opaque `workToken`, `stopHookActive`,
  and `timestamp`. Prompt, model, transcript path, tool content, and assistant
  content are excluded from the outgoing payload; malformed/oversized events
  must be rejected.
- **On-demand display watchdog** (`LidlessDisplayWatchdog`): an unprivileged,
  non-login child process accepts only the bounded versioned pipe protocol from
  its parent, operates only on a confirmed unique built-in display, and keeps a
  mode-`0600` atomic recovery journal. It observes only the age of the last
  physical HID event; it neither intercepts nor stores key or pointer content.
- **Private brightness API boundary**: `DisplayServices` is resolved at runtime
  and must fail closed if its symbols, topology, or readback cannot be confirmed.
  A main-display or external-display fallback is prohibited.
- **Read-only power observer** (`PowerManager`) reads `pmset -g`; every write is
  required to pass through the Helper's durable lease. There is intentionally no
  administrator-prompt or raw `pmset` fallback that could strand the global flag.

Issues in any of these (privilege escalation, unauthorized XPC use, the watchdog
failing to restore sleep) are the most valuable to report.
