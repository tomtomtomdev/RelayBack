# RelayBack — Specification

> A menu-bar macOS app that lets you trigger a fixed allowlist of commands on your
> Mac from anywhere, via a private Telegram bot, and get the output back in chat.

Status: **design locked, pre-implementation.** This is the source of truth for *what*
we build. `PLAN.md` covers *how/when*; `PROGRESS.md` tracks *where we are*.

---

## 1. Purpose & context

The Mac running RelayBack is unattended — the operator is physically away from it.
Telegram is the remote control channel because it works from any phone, behind NAT,
with no inbound ports and no public endpoint on the Mac.

RelayBack receives messages from a private bot, verifies they came from an authorized
operator who has *armed* the session with a time-based one-time code, matches the
message against a fixed allowlist of pre-defined actions, runs the matched action, and
sends stdout/stderr/exit-code back to the chat.

## 2. Non-goals (explicitly out of scope for v1)

- **No arbitrary shell.** User text never reaches a shell. Only allowlisted actions run.
  (Arbitrary/confirmation-gated execution is a possible *future* phase, not v1.)
- **No arbitrary/free-text command parameters.** Actions accept **only validated argv
  parameters** (see §4a): every parameter is passed as a fixed `Process` argv position —
  never through a shell — and must pass a strict validator (enum / regex / path drawn from a
  configured allowlist), `--`-guarded so it can never be reinterpreted as a flag. Operator
  text never fills the executable slot and never an unvalidated argv position. (Amended
  2026-07-03 for the dev-workflow actions — S15+. This is the "constrained enum parameters"
  future phase §10 anticipated, now scoped in deliberately; arbitrary shell remains out.)
- **No webhooks / inbound network server.** Outbound long-polling only.
- **No multi-tenant / multi-Mac fleet.** One operator, one Mac.
- **No notarization/sandbox in v1.** Personal local install. (Re-evaluate before sharing.)
- **End-to-end secrecy is NOT promised.** See threat model §4.

## 3. Actors

- **Operator** — the human, identified by a numeric Telegram `from.id` on the allowlist.
- **Bot** — the Telegram bot, identified by its token. Token gates *which bot*; the
  `from.id` allowlist gates *who may use it*. These are independent controls.
- **RelayBack** — the app, running as a login-item menu-bar agent on the Mac.

## 4. Security model

### Threat model
- A leaked bot token alone must NOT grant command execution.
- Anyone can message a bot once they know its handle — so identity must be checked
  per-message, not assumed from the channel.
- Telegram bot messages are **TLS in transit but visible to Telegram servers**
  (not end-to-end encrypted). Therefore: never route secrets (keys, prod creds) through
  actions, and treat command names + output as readable by Telegram. This is an accepted
  constraint, documented so no one assumes otherwise.

### Controls (defense in depth — all must hold)
1. **Identity allowlist.** Every update is checked against a configured set of numeric
   `message.from.id` values. Non-matches are dropped silently. Check `from.id`,
   never chat id (prevents group-add bypass).
2. **Arm/disarm with TOTP.** Session starts **DISARMED**. Arming requires a valid RFC 6238
   TOTP code (`/arm <code>`). Armed state auto-expires after an idle timeout and can be
   ended manually with `/disarm`. No action runs while disarmed.
3. **Allowlist-only execution.** Only actions in the `ActionRegistry` can run, each spawned
   as `Process` with an **absolute executable path and a fixed argument array — never via
   `/bin/sh -c`**. This removes shell injection from the threat model by construction.
4. **Execution hygiene.** Run as the normal user (never root), restricted `PATH`,
   per-action timeout that kills the process, single-action concurrency.
5. **Secret storage.** Bot token and TOTP secret live in the macOS Keychain only — never
   in source, plists, logs, or audit entries.
6. **Audit log.** Append-only local record of every received command: timestamp,
   `from.id`, matched action (or "rejected: reason"), exit code. No secrets, no full output.

### Security invariants (must never be violated by any code change)
- I1. No code path passes operator-supplied text to a shell or to `Process` as an
  **executable** or as an **unvalidated** argument. `/bin/sh -c` is never used. Actions are
  looked up; the executable and all fixed args come from the registry. Operator text may fill
  a **validated parameter slot** only (§4a): it is placed at a fixed argv position after
  passing that slot's validator and a `--` flag-guard — never concatenated, never a flag,
  never the executable. "No shell, ever" is unchanged.
- I2. No action executes unless: `from.id` ∈ allowlist **AND** session is ARMED.
- I3. Token and TOTP secret are read only from Keychain; never logged or sent to Telegram.
- I4. Process is never spawned with elevated privileges.

### 4a. Validated parameters & working directory (dev-workflow actions, S15+)

Some actions (git, xcodebuild) need a parameter or a repo context. These extend the model
**without** relaxing I1 — they add validation, they do not add a shell.

- **Parameters are validated argv, never shell.** A parameterized action declares typed
  parameter slots. Each operator-supplied token is validated, then handed to `Process` at a
  **fixed argv index**. Because there is no shell, metacharacters have no meaning
  (`git commit -m "; rm -rf /"` writes that literal message). Validators:
  - **repo name** — must equal a `name` in the configured repo allowlist; resolves to that
    repo's absolute root. No path ever comes from chat, so traversal is impossible.
  - **branch** — `^[A-Za-z0-9._/-]+$`, must not begin with `-`.
  - **commit message** — length-capped, must not begin with `-`; a single argv token.
  - A `--` separator precedes any value-bearing arg so a value can never become a flag.
  - Validation failure → a `.invalidParameters(reason)` reply + audit line; nothing spawns.
- **Working directory = named repo allowlist.** `Process.currentDirectoryURL` is set only to
  an absolute root drawn from the configured repo list. There is no free-form `cd`.
- **Active repo is session state (S16).** The operator selects a working directory with
  `/cd <name>` (matched exactly against the configured repo allowlist — no path from chat). The
  selection lives with the armed session, like arm state: it is cleared on `/disarm`, on a UI
  disarm, and when a fresh `/arm` begins a new session, so it never leaks across sessions. A
  repo-scoped command (git/build/sim) with no active repo → `.invalidParameters("select a repo
  first")`; nothing spawns. `/pwd` reports the active repo, `/repos` lists the configured ones —
  both disclose only name + root, never a repo's build config.
- **Remote ops are upstream-only.** `push`/`pull` use each repo's already-configured upstream;
  no remote name or refspec is ever accepted from chat.
- **Builds use fixed per-repo config.** `xcodebuild` scheme + destination come from the repo's
  config entry, not from operator text — zero build-arg injection surface.
- **Simulator run is a fixed multi-step sequence (S19).** `/sim` resolves to an ordered
  `xcodebuild build → xcrun simctl boot → open -a Simulator` sequence built entirely from the
  active repo's config (scheme, destination, `simulatorDevice`) — never operator text, never argv
  the operator can influence. Steps run in order and stop on the first non-zero exit; `/sim` takes
  no operator argument, and a repo missing any required field is refused (nothing spawns). *(v1
  scope: `/sim` builds and boots the configured device; it does not `simctl install`/`launch` the
  built app, which would need a bundle-id + product-path the v1 repo config does not model —
  deferred to a future phase.)*

Threat-model note: this widens the worst-case-on-full-auth-bypass from *read-only diagnostics*
to *mutating git state and triggering builds in the configured repos*. It does **not** grant a
shell, arbitrary file writes, arbitrary executables, or pushes to arbitrary remotes. Accepted
for single-operator personal use; revisit before any multi-user or shared deployment.

## 5. Command grammar (operator-facing)

Control commands (handled internally, always available to allowlisted users):
- `/arm <6-digit-code>` — validate TOTP, arm session, reply with remaining armed time.
- `/disarm` — drop to DISARMED.
- `/status` — report armed/disarmed + remaining time (no action execution).
- `/help` or `/start` — list available action commands.
- `/repos` — list the configured repos (name + root only). Requires an armed session (S16).
- `/cd <name>` — select the active repo for subsequent git/build/sim commands (S16).
- `/pwd` — report the active repo (name + root), or prompt to `/cd` first (S16).

Action commands: each registry `Action` exposes a `command` (e.g. `/uptime`). Sending it,
while armed and authorized, runs the action. Registered via Telegram `setMyCommands` so
they autocomplete in chat. Unknown commands → polite "unknown command" reply, logged.

Dev-workflow commands (§4a, run in the active repo; require `/cd` first):
- `/gitstatus` · `/branch` · `/checkout <branch>` · `/pull` · `/push` · `/commit <msg>` — git
  operations with validated argv (S17). `push`/`pull` are upstream-only and take no argument.
- `/build` — `xcodebuild build` with the repo's configured scheme + destination; no argument (S18).
- `/sim` — build → boot the configured simulator device → reveal Simulator.app; no argument,
  stops on the first failing step (S19).

## 6. Functional requirements

- **FR-1 Polling.** Continuously long-poll `getUpdates` with an advancing `offset`;
  survive network errors with backoff; never reprocess an update.
- **FR-2 Identity.** Reject (drop + log) any update whose `from.id` ∉ allowlist.
- **FR-3 Arming.** `/arm` validates a TOTP code (±1 step drift tolerance). Success arms for
  the configured idle window; each authorized action resets the idle timer. `/disarm` and
  timeout return to DISARMED.
- **FR-4 Action match.** Map an incoming command string to exactly one `Action` or to
  "unknown". Matching is exact on the leading token.
- **FR-5 Execution.** Run the matched action's executable with its fixed args, capturing
  stdout, stderr, and exit code, killing it at the timeout.
- **FR-6 Output delivery.** Format exit code + stdout + stderr; send as a Telegram message,
  chunked at the 4096-char limit; send oversized output as a `.txt` document instead.
- **FR-7 Persistence of secrets.** Store/retrieve bot token + TOTP secret via Keychain.
- **FR-8 Audit.** Append one structured line per received command to the audit log.
- **FR-9 Settings UI.** Menu-bar UI to enter token, manage allowlisted ids, view/generate
  the TOTP secret (as scannable `otpauth://` QR), toggle login-item, and view recent audit.
- **FR-10 Lifecycle.** Start/stop polling with app run state; optional launch-at-login via
  `SMAppService`. No Dock icon (`LSUIElement`).

## 7. Architecture & modules

SwiftUI `MenuBarExtra` agent app. `@Observable` for view state. Swift Concurrency
(`actor`) for stateful I/O. All I/O sits behind protocols so the decision logic is unit
testable with fakes — no live network or real process spawning in tests.

```
RelayBack/
├── App/         RelayBackApp (entry), AppCoordinator (orchestration brain)
├── Core/        TOTP, AuthGuard, ActionRegistry, OutputFormatter, Clock   ← pure, TDD-first
├── Telegram/    TelegramTransport (protocol), TelegramClient (URLSession), TelegramModels
├── Execution/   CommandRunning (protocol), ProcessCommandRunner (Process impl)
├── Storage/     KeychainStore (protocol + impl), AuditLog
├── Features/    MenuBar/, Settings/   ← SwiftUI views
└── Resources/   Assets, RelayBack.entitlements
RelayBackTests/  mirrors Core/ + Coordinator + JSON fixtures + fakes
```

### Component responsibilities
- **TOTP** — pure RFC 6238 generate/validate (HMAC-SHA1, 6 digits, 30s, ±1 step). Testable
  against RFC 6238 Appendix B vectors.
- **AuthGuard** — pure state machine: holds allowlist + arm state; decides
  `authorize(update) -> Decision` given an injected `Clock`. Drives idle timeout.
- **ActionRegistry** — the allowlist; pure `match(command) -> Action?`.
- **OutputFormatter** — pure: format + chunk + message-vs-document decision.
- **Clock** — `protocol Clock { var now: Date { get } }`; real = system, test = fixed,
  so AuthGuard timeouts and TOTP windows are deterministic in tests.
- **TelegramTransport** — protocol (`getUpdates`, `sendMessage`, `sendDocument`,
  `setMyCommands`); `TelegramClient` is the `URLSession` async implementation.
- **CommandRunning** — protocol (`run(Action) async -> CommandResult`);
  `ProcessCommandRunner` wraps `Process` with timeout/kill.
- **KeychainStore** — protocol with in-memory fake for tests + real Keychain impl.
- **AuditLog** — append-only writer; line formatting is pure/testable.
- **AppCoordinator** — wires transport→AuthGuard→registry→runner→formatter→transport.
  Fully unit-testable by injecting fakes for every protocol.

## 8. Tech & platform decisions

- Swift + SwiftUI, `MenuBarExtra`, `@Observable`, Swift Concurrency, `URLSession` async.
- TOTP via `CryptoKit` (`HMAC<Insecure.SHA1>`).
- Secrets via Keychain Services. Login item via `ServiceManagement.SMAppService`.
- `LSUIElement = YES`. v1: non-sandboxed, run locally from a local build (no notarization).
- Min target: macOS 14+ (for `@Observable` / modern APIs).

## 9. Testability requirements

- Every `Core/` type is pure and unit-tested **test-first** (see `CLAUDE.md` TDD rules).
- Every external dependency (network, Process, Keychain, clock) is behind a protocol with
  a test fake. No test touches the real network, spawns real long-running processes
  (a `/bin/echo` smoke test for the real runner is allowed), or writes the real Keychain.
- `AppCoordinator` is tested end-to-end with all-fake dependencies.

## 10. Open questions / future phases

- ~~Constrained enum parameters for actions (e.g. `/tail <known-service>`).~~ **Scoped in
  2026-07-03 as the dev-workflow actions (S15+); see §4a.**
- Phase-2 confirmation-gated arbitrary execution (inline-keyboard ✅/❌).
- Developer ID signing + notarization if the app is ever shared.
- Streaming partial output + `/kill` for long-running actions.
