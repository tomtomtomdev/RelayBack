# RelayBack

> A menu-bar macOS app that lets you trigger a **fixed allowlist of commands** on an
> unattended Mac from anywhere, via a private **Telegram bot**, gated by a **TOTP
> arm/disarm** session — with command output returned to chat.

RelayBack runs as a background menu-bar agent (no Dock icon) on a Mac you've left behind.
It long-polls a private Telegram bot, verifies every message came from an authorized
operator who has *armed* the session with a one-time code, matches the message against a
pre-defined allowlist of actions, runs the matched action, and sends stdout / stderr /
exit code back to the chat.

Telegram is the control channel because it works from any phone, behind NAT, with **no
inbound ports and no public endpoint** on the Mac.

---

## Why it's safe by design

RelayBack is a remote-execution tool, so its security posture is the whole point. Four
invariants are enforced structurally and covered by tests — no code change may violate them:

- **I1 — No shell, ever.** Operator text is never passed to a shell or used as an
  executable/argument. Actions are looked up in the `ActionRegistry`; only registry-defined
  **absolute paths + fixed argument arrays** are spawned via `Process`. There is no
  `/bin/sh -c` path, so shell injection is removed by construction.
- **I2 — No run unless authorized AND armed.** An action executes only when the sender's
  numeric `from.id` is on the allowlist **and** the session is currently ARMED. Identity is
  checked per-message (`from.id`, never chat id — prevents group-add bypass).
- **I3 — Secrets only in Keychain.** The bot token and TOTP secret are read only from the
  macOS Keychain — never hard-coded, logged, written to the audit log, or sent to Telegram.
- **I4 — Never elevate.** `Process` runs as the normal user with a restricted `PATH` —
  never root, never with privilege escalation.

### Defense in depth

1. **Identity allowlist** — a leaked bot token alone grants nothing; the operator's
   `from.id` must be allowlisted. Non-matches are dropped silently.
2. **TOTP arm/disarm** — the session starts **DISARMED**. Arming needs a valid RFC 6238
   TOTP code (`/arm <code>`). Armed state auto-expires after an idle window and can be ended
   with `/disarm`. Nothing runs while disarmed.
3. **Allowlist-only execution** — only `ActionRegistry` actions can run, each with a fixed
   executable path and argument array.
4. **Execution hygiene** — non-root, restricted `PATH`, per-action timeout that kills the
   process, single-action concurrency.
5. **Append-only audit log** — one line per received command (timestamp, `from.id`, matched
   action or rejection reason, exit code). No secrets, no full output.

> ⚠️ **Not end-to-end secret.** Telegram messages are TLS in transit but visible to Telegram
> servers. Treat command names and output as readable by Telegram, and never route secrets
> (keys, prod credentials) through actions. This is an accepted, documented constraint.

---

## Operator commands

Control commands (handled internally, available to allowlisted users):

| Command | Effect |
|---|---|
| `/arm <6-digit-code>` | Validate TOTP, arm the session, reply with remaining armed time |
| `/disarm` | Return to DISARMED |
| `/status` | Report armed/disarmed + remaining time (runs nothing) |
| `/help`, `/start` | List available action commands |

Action commands come from the registry — sending one while armed and authorized runs it.
The seed allowlist is read-only and quick:

| Command | Runs |
|---|---|
| `/uptime` | `/usr/bin/uptime` |
| `/disk` | `/bin/df -h` |
| `/whoami` | `/usr/bin/whoami` |

Actions are registered via Telegram `setMyCommands`, so they autocomplete in chat. Unknown
commands get a polite reply and are logged.

---

## Architecture

SwiftUI `MenuBarExtra` agent app, `@Observable` view state, Swift Concurrency for stateful
I/O. Every external dependency sits behind a protocol with a test fake, so `AppCoordinator`
and all decision logic are unit-testable without real network, `Process`, or Keychain.

```
RelayBack/
├── App/         RelayBackApp (entry), AppCoordinator (orchestration), PollLoop, AppRuntime
├── Core/        TOTP, AuthGuard, ActionRegistry, OutputFormatter, Clock, Backoff  ← pure, TDD-first
├── Telegram/    TelegramTransport (protocol), TelegramClient (URLSession), TelegramModels
├── Execution/   CommandRunning (protocol), ProcessCommandRunner (Process impl)
├── Storage/     KeychainStore, ConfigStore, AuditLog, ConnectionLog
├── Features/    MenuBar/, Settings/, Theme/   ← SwiftUI views + view models
└── Resources/   Assets, RelayBack.entitlements
RelayBackTests/  mirrors source folders; fakes live under Support/
```

`Core/` is pure and framework-light (TDD'd directly). `AppCoordinator` wires
transport → `AuthGuard` → `ActionRegistry` → `CommandRunning` → `OutputFormatter` →
transport (+ audit log); it owns no I/O directly, only injected protocols.

---

## Requirements

- macOS 14+
- Xcode 16+ (the project uses file-system-synchronized groups, `objectVersion 77`)
- A Telegram bot token (from [@BotFather](https://t.me/BotFather)) and your numeric
  Telegram user id

## Build, test & run

The Xcode project lives at `RelayBack/RelayBack.xcodeproj`.

```bash
# Build
xcodebuild -project RelayBack/RelayBack.xcodeproj -scheme RelayBack \
  -destination 'platform=macOS' build

# Test (unit tests only; UI test target is excluded from the scheme's Test action)
xcodebuild -project RelayBack/RelayBack.xcodeproj -scheme RelayBack \
  -destination 'platform=macOS' test
```

Run for real by launching the built `.app` — it appears as a menu-bar icon with no Dock
icon. Enter Telegram credentials in **Settings**; nothing is committed anywhere.

### First-time setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Launch RelayBack → **Settings**:
   - Paste the **bot token** (stored in Keychain).
   - Add your numeric Telegram **user id** to the allowlist.
   - **Generate** a TOTP secret and scan the `otpauth://` QR with an authenticator app.
   - Optionally enable **launch at login**.
3. From Telegram, message the bot `/arm <code>`, then send an action like `/uptime`.

### Packaging a `.dmg`

```bash
./scripts/build-dmg.sh                                   # unsigned local build → dist/RelayBack-<ver>.dmg
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./scripts/build-dmg.sh   # signed
NOTARY_PROFILE="relayback-notary" ./scripts/build-dmg.sh # sign + notarize + staple
```

---

## Development

This project is built in small, test-first slices. **TDD is mandatory** (red → green →
refactor). Pure `Core/` types are TDD'd directly against oracles (RFC 6238 Appendix B
vectors for TOTP, an injected `Clock` for time-dependent behavior); I/O types are TDD'd
behind a protocol using a fake, with the thin real impl verified by a focused smoke test.

Project docs:

- **`SPEC.md`** — *what* we build (requirements, security model, invariants).
- **`PLAN.md`** — *how/when* (the slice sequence).
- **`PROGRESS.md`** — *where we are* (source of truth, updated every slice).
- **`CLAUDE.md`** — working rules for contributors (and for Claude Code).

CI builds and runs `RelayBackTests` on macOS on push to `main`.

## Status

v1 is **operationally complete** — an authorized operator can arm via TOTP and run an
allowlisted command end-to-end, with output returned to chat and every command audited.
Ongoing work (see `PROGRESS.md`) is recreating the high-fidelity design handoff natively in
SwiftUI and persistent connection-lifecycle logging.

### Out of scope for v1

No arbitrary shell, no free-text command parameters, no webhooks/inbound server, no
multi-Mac fleet, no sandbox/notarization (personal local install). See `SPEC.md` §2 and §10
for future phases.
