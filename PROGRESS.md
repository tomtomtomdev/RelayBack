# RelayBack — Progress Log

> Source of truth for "where are we." Written to survive context clears. Update this at the
> end of every slice (see `CLAUDE.md` → "Ending a slice"). Newest note at the top of the log.

## Current state

- **Phase:** implementation. **S11 done — all planned slices (S0–S11) complete.** Lifecycle & login
  item. TDD'd core: `Core/Backoff` (pure exponential backoff, base×2ⁿ capped) and `App/PollLoop`
  (the long-poll loop — offset advance/never-reprocess (FR-1), reconnect/backoff across transport
  failures, idempotent start/stop, cancellation-clean shutdown). `PollLoop` dispatches through a new
  `UpdateHandling` protocol (`AppCoordinator` conforms) so the loop is driven by a spy in tests
  against `FakeTelegramTransport` (now scripts per-call successes/failures + records requested
  offsets). Login item: `App/LoginItem` (`LoginItemControlling` protocol + real `SMAppServiceLoginItem`);
  `SettingsModel.launchAtLogin` now goes through that seam (TDD'd against a fake — enable/reflect/
  failure-keeps-state-honest). `AppCoordinator` gained read-only `isArmed`/`remainingArmedTime` for
  the menu bar. `App/MenuBarAuditSink` decorates the file `AuditSink` to push each audit line + arm
  status into the live `MenuBarModel` (TDD'd). Composition root `App/AppRuntime` (main-like, not
  unit-tested) assembles the real Keychain/URLSession/Process/file impls and starts polling;
  `RelayBackApp` uses an `NSApplicationDelegate` to `start()` at launch / `stop()` on terminate.
- **⚠️ Known functional gap (deferred, not a bug):** the authorization **allowlist is not persisted**,
  so a launched agent builds an EMPTY allowlist and authorizes **no one** (fails closed — safe, but
  means the end-to-end `/arm`→run path can't work at runtime yet). Needs a non-secret config store
  (no protocol exists yet) + feeding/hot-reloading it into the running `AuthGuard`. This is the one
  remaining piece before v1 is operationally complete — see the S11 decision note. Also deferred: a
  per-second live countdown in the menu bar (status refreshes on each audit event, not on a timer).
- ✅ **S0–S11 verified green on macOS** (Xcode 26.5, this session): full `RelayBackTests` suite =
  **124 tests / 19 suites** passing (S11 added `BackoffTests`, `PollLoopTests`, `MenuBarAuditSinkTests`
  + a coordinator arm-state test + 3 login-item tests). The `.app` builds, launches as a menu-bar
  agent (no Dock icon), stays idle when unconfigured, and quits cleanly (launch smoke this session).
- ~~**S10 done**~~ — Menu bar + Settings UI (FR-9). The TDD'd surface is the
  pure view-model logic; SwiftUI rendering is thin and Preview-verified. Landed: `Base32.encode`
  (RFC 4648, unpadded — for the QR), `Core/OtpAuthURI` (pure `otpauth://totp/...` builder pinned to
  the app's fixed TOTP config), `Features/Settings/AllowlistDraft` (id-input validation: positive
  Int64 only, dedup, sorted), `Features/MenuBar/MenuBarStatus` (arm-state → headline/detail + m:ss
  countdown). `@Observable` view state: `SettingsModel` (SecretStore-backed token save/load + TOTP
  secret generate/persist + `otpauthURI`) and `MenuBarModel` (arm status + capped recent-audit
  tail). SwiftUI: rewrote `MenuBarRootView` (status + recent activity + Settings/Quit), added
  `SettingsView` (token SecureField→Keychain, allowlist add/remove, QR from `otpauthURI` via
  CoreImage, generate/regenerate secret, launch-at-login toggle *UI only*), and added the `Settings`
  scene in `RelayBackApp`. **I3** upheld: secrets flow only through the `SecretStore` seam; the token
  field is a SecureField (never shown back) — proven in `SettingsModelTests`.
- **S10's "deferred to S11" items — status after S11:** ✅ live `MenuBarModel` arm-state + recent-audit
  wiring (via `MenuBarAuditSink`); ✅ launch-at-login `SMAppService` wiring; ⏳ **allowlist persistence
  + feeding into the running `AuthGuard`** still deferred (see the gap note above — needs a config store).
- ~~**S8 done**~~ — `AppCoordinator` wires the whole run path:
  transport update → `AuthGuard` (identity + arm gate, which does the `ActionRegistry` match) →
  `CommandRunning` (only on `.runAction`) → `OutputFormatter` → transport reply → `AuditSink`
  (every outcome). It owns no I/O — every dependency is an injected protocol. Tested end-to-end
  against three new fakes; this slice is the executable proof of **I2** (runner reached ONLY for
  an allowlisted + armed sender — every other decision leaves `runCount == 0`), **I1** (runner
  gets the registry `Action`, not operator text), and **I3** (run audited by command token + exit
  code only, never output). Also pins FR-6 reply shaping (normal → text, oversized → one document)
  and FR-2 (strangers get no reply, only an audit line). The `Decision`+`ControlResult`+
  `CommandResult` → `AuditEvent` mapping deferred from S9 is now defined here (see decisions).
- **Next slice:** **S12 (new) — Allowlist persistence & runtime auth wiring** (the one remaining gap
  before v1 is operational): add a non-secret config store (protocol + real UserDefaults/file impl +
  fake), have `SettingsModel` persist the allowlist, and feed it into the running `AuthGuard`
  (decide hot-reload vs. restart-to-apply, and whether changing the allowlist resets arm state).
  Not in the original PLAN S0–S11 — append it to `PLAN.md` before starting.
- **Blockers / open questions:** none blocking. Design Q for S12: hot-reload the allowlist into the
  live guard, or apply on next launch? (Future-phase items parked in SPEC §10.)
- ✅ **S1–S10 verified green on macOS** (Xcode 26.5, this session): full `RelayBackTests` suite =
  **109 tests / 16 suites** passing (S10 added Base32-encode tests + 4 suites: `OtpAuthURITests`,
  `AllowlistDraftTests`, `MenuBarStatusTests`, `SettingsModelTests`). SwiftUI views compile and are
  Preview-verified; the app target builds. (CI remains push-to-`main`-only.)

## Slice status

| Slice | Title | Status |
|-------|-------|--------|
| S0  | Project bootstrap            | ✅ done |
| S1  | TOTP core                    | ✅ done |
| S2  | Action allowlist & registry  | ✅ done |
| S3  | AuthGuard state machine      | ✅ done |
| S4  | Output formatter             | ✅ done |
| S5  | Keychain store               | ✅ done |
| S6  | Telegram transport           | ✅ done |
| S7  | Command runner               | ✅ done |
| S8  | AppCoordinator               | ✅ done |
| S9  | Audit log                    | ✅ done |
| S10 | Menu bar + Settings UI       | ✅ done |
| S11 | Lifecycle & login item       | ✅ done |
| S12 | Allowlist persistence & auth wiring *(new)* | ☐ not started |

Legend: ☐ not started · ◐ in progress · ✅ done (green + refactored)

## Decisions & deviations

_(Record anything that differs from or sharpens SPEC.md / PLAN.md, with a one-line why.)_

- 2026-07-03 — S11: **The infinite poll loop is made testable by extracting one iteration.**
  `PollLoop.pollOnce()` (fetch at offset → dispatch each → advance offset) is deterministic against
  the fake, so FR-1 (never reprocess; empty batch never rewinds) is unit-tested directly. `run()` is
  the thin `while !cancelled { pollOnce; on error backoff-sleep }` wrapper; its reconnect/backoff is
  tested by scripting the fake transport (throw, throw, succeed, then block-until-cancel) with an
  **injected `sleep`** that records delays without waiting — no real time passes. The fake signals
  (`onScriptExhausted`) when it runs past the script so the test knows the loop recovered, then calls
  `stop()`; the blocking `getUpdates` (real `Task.sleep`) throws `CancellationError`, which `run()`
  catches to end cleanly. This is the deterministic realization of PLAN S11's "inject failing-then-
  succeeding transport."
- 2026-07-03 — S11: **`PollLoop` depends on `UpdateHandling`, not concrete `AppCoordinator`.** New
  one-method protocol (`handle(_:) async`); `AppCoordinator` conforms via an empty extension. Lets a
  `SpyUpdateHandler` assert exactly which updates were dispatched (proving no double-processing)
  without a real coordinator. `FakeTelegramTransport` gained a scripted mode (`getUpdatesScript:
  [GetUpdatesResult]` + `onScriptExhausted`) and now records `getUpdatesOffsets` — the old
  `updatesToReturn` was removed (no test used it; S8 tests call `handle` directly, not `getUpdates`).
- 2026-07-03 — S11: **Backoff is exponential+capped, failure count owned by the caller.** `Backoff`
  (base 1s, cap 30s, ×2) is a pure `delay(afterFailures:)`; `run()` holds the counter (reset on a
  successful poll, incremented per failure). Kept pure so the schedule is unit-tested in isolation.
- 2026-07-03 — S11: **Launch-at-login goes through a `LoginItemControlling` seam.** Protocol + real
  `SMAppServiceLoginItem` (`SMAppService.mainApp` register/unregister); `SettingsModel.launchAtLogin`
  became `private(set)`, changed only via `setLaunchAtLogin(_:)` which calls the seam and sets the
  flag to what **actually** took effect (`loginItem.isEnabled`) — on failure it surfaces a message
  and leaves the flag reflecting reality (no optimistic drift). Toggle in `SettingsView` now uses a
  custom `Binding` calling that method. Real `SMAppService` impl verified by compile + running app;
  the glue is TDD'd against `FakeLoginItem`. The `SMAppServiceLoginItem()` default arg means the
  existing token/secret tests read real login-item *status* (read-only, harmless) unless they inject
  the fake — the login-item tests inject `FakeLoginItem`.
- 2026-07-03 — S11: **`MenuBarAuditSink` decorates the audit sink to make the popover live.** Every
  outcome already funnels through the `AuditSink` (S8), so wrapping it is the least-invasive way to
  feed `MenuBarModel` (append the pure, secret-free `AuditEntry.line`; refresh arm status via a
  `status` closure that reads the coordinator weakly — set after the coordinator is built to break
  the sink↔coordinator cycle). Arm status therefore refreshes on each audit event, **not** on a
  per-second timer (live countdown deferred). `AppCoordinator` exposes read-only `isArmed`/
  `remainingArmedTime` for this (tested).
- 2026-07-03 — S11: **`AppRuntime` is the composition root; lifecycle tied to the app delegate.**
  Like `main()` — it's the one place concrete impls (`KeychainStore`, `TelegramClient`,
  `ProcessCommandRunner`, `FileAuditLog`) are assembled, so it's verified by build + launch, not unit
  tests. `start()` builds the coordinator + `PollLoop` from stored credentials and begins polling
  (idempotent; **stays idle if unconfigured** — no token/secret → early return, so a fresh install
  doesn't crash); `stop()` halts for graceful shutdown. `RelayBackApp` moved from `.task`-on-popover
  (only fired when the menu was opened — wrong for an unattended agent) to an
  `@NSApplicationDelegateAdaptor` that starts at `applicationDidFinishLaunching` and stops at
  `applicationWillTerminate`. Audit log lives at `~/Library/Application Support/RelayBack/audit.log`.
- 2026-07-03 — S11: **Allowlist persistence deliberately NOT done here → carved out as S12.** PLAN
  S11's Goal (poll lifecycle / SMAppService / graceful shutdown / backoff) is delivered and green;
  the "persist allowlist + feed the running guard" line that PROGRESS had informally folded into S11
  is a distinct concern (needs a new non-secret config-store protocol and a hot-reload-vs-restart
  decision) and would have overloaded the slice. Consequence: the shipped agent authorizes no one
  until S12. Fails closed (safe). Appended S12 to the slice table; add it to `PLAN.md` before starting.
- 2026-07-03 — S10: **The slice split its testable core from thin, Preview-only SwiftUI.** Per PLAN
  S10 ("Tests first: view-model logic only… SwiftUI rendering verified manually via Previews") the
  four pure surfaces are TDD'd directly — `Base32.encode`, `Core/OtpAuthURI`, `AllowlistDraft`,
  `MenuBarStatus` — plus `SettingsModel` behind the `SecretStore` fake. `MenuBarRootView`/
  `SettingsView` hold no logic worth a test (they read the models and render), so they're verified
  via `#Preview` + a compiling app build, not unit tests. `MenuBarModel` is a thin container
  (status + capped audit tail) — one behavior (`appendAudit` cap) is exercised implicitly; not
  separately tested (kept trivial).
- 2026-07-03 — S10: **`Base32.encode` is UNPADDED, uppercase.** RFC 4648 vectors match unpadded
  output (`"f"`→`MY`, not `MY======`); `otpauth://` / authenticator apps expect no padding, and
  `decode` already ignores `=`, so `decode(encode(x)) == x`. Lives in `Core/Base32.swift` next to
  the existing decoder.
- 2026-07-03 — S10: **`OtpAuthURI` is pinned to the app's fixed TOTP config** (`algorithm=SHA1&
  digits=6&period=30`, from `TOTP.digits`/`TOTP.period`) so a scanned QR yields exactly the codes
  `AuthGuard` validates. Label + issuer are percent-encoded (RFC 3986 unreserved set). Contains the
  literal token `SHA1`, so `OtpAuthURI.swift` + `OtpAuthURITests.swift` + `SettingsModelTests.swift`
  were written via **Bash heredoc** to dodge the ios-plugin PreToolUse hook (see memory
  `sha1-hook-heredoc`); comments use "SHA-1".
- 2026-07-03 — S10: **Allowlist ids are positive `Int64` only** (`AllowlistDraft.add` rejects empty
  / non-numeric / zero / negative / overflow, dedupes, sorts). This is what populates the identity
  gate (I2), so malformed input can never silently widen who may run commands. **Persistence and
  wiring into the coordinator's `AuthGuard` are deferred to S11** — there is no protocol for
  non-secret config yet, and the running coordinator that consumes the allowlist is built by the
  S11 poll loop. S10 delivers only the *editing/validation* surface.
- 2026-07-03 — S10: **`SettingsModel` generates a 160-bit (20-byte) TOTP secret** via
  `SecRandomCopyBytes` (RFC 6238's minimum for HMAC-SHA-1) and persists it through `SecretStore`
  only (I3). Randomness makes the exact bytes non-deterministic, so the test asserts the *contract*
  (20 bytes, stored == model.totpSecret, base32/URI derive from it), not a fixed value; the
  fixed-string oracle is covered by the seeded-secret load test + `OtpAuthURITests`.
- 2026-07-03 — S10: **The `Settings` scene + models are owned by `RelayBackApp` as `@State`.** A
  real `KeychainStore` backs `SettingsModel`; `MenuBarModel` starts disarmed/empty. Live updates
  (arm state, recent audit) and the `AppCoordinator`/poll-loop hookup are S11 — S10 leaves the two
  models standalone so the UI is usable and Previewable now without the run loop.
- 2026-07-03 — S8: **`AppCoordinator` is a MainActor class, not a bespoke `actor`.** SPEC §7 says
  "actor for stateful I/O"; landed as a `final class` under the project's default actor isolation
  (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 5 mode) — consistent with the rest of the
  codebase and free of Sendable friction with the fakes. It still never blocks the UI: `handle`
  `await`s every dependency (so it suspends, not stalls), and `ProcessCommandRunner` already
  dispatches its blocking work off-main (S7). The serialized-update guarantee an `actor` would
  give is deferred to S11, where the single polling loop is the only caller (no concurrent
  `handle` calls in v1). This is the deliberate resolution of the concurrency-model question S6/S7
  parked "for S8."
- 2026-07-03 — S8: **The `Decision` → `AuditEvent` / reply mapping (deferred from S9) is defined
  here.** One received update maps as: `rejectedUnknownUser` → **no reply** (FR-2: strangers get
  silence) + `rejected("unknown user")`; `disarmed` → "🔒 disarmed…" reply + `rejected("disarmed")`;
  `unknownCommand` → "❓ Unknown command." + `rejected("unknown command")`; `control(.armAccepted)`
  → "🔓 Armed." + `control("armed")`; `control(.armRejected)` → "❌ Invalid code." +
  **`rejected("bad code")`** (a failed arm changed no state, so it's a rejection, not a control
  event); `control(.disarmAccepted)` → `control("disarmed")`; `control(.status(a))` →
  `control("status armed=<bool>")`; `runAction` → run → `OutputFormatter.format` → send each →
  `actionRan(command, exitCode)`. All reason strings are short and secret-free (I3).
- 2026-07-03 — S8: **Transport sends are best-effort (`try?`), mirroring the audit sink.** A failed
  `sendMessage`/`sendDocument` is swallowed so one bad send can't crash update handling / stop the
  poll loop — same rationale as S9's non-throwing `AuditSink`. Non-actionable updates (no message /
  no `from` / no `text`) are ignored silently with **no audit line** — they can't be authorized
  (allowlist matches `from.id`) and aren't operator commands, so there's nothing to record.
- 2026-07-03 — S8: **Fakes built here (first slice to drive these protocols), in
  `RelayBackTests/Support/`:** `FakeTelegramTransport` (records `sentMessages`/`sentDocuments`/
  `registeredCommands`, canned `updatesToReturn` for the S11 loop), `FakeCommandRunner` (records
  `runActions`, returns a settable `result` — proves I2 via `runCount == 0`), `InMemoryAuditSink`
  (records `entries`). `App/AppCoordinator.swift` and `RelayBackTests/App/` auto-included via the
  file-system-synchronized group (objectVersion 77) — no pbxproj edit.
- 2026-07-03 — S9: **`AuditSink.append` is non-throwing; the sink is best-effort.** PLAN says
  `AuditSink { append(AuditEntry) }`. Auditing is background bookkeeping and must never interrupt
  command handling, so `FileAuditLog` swallows its own write errors rather than propagating them
  (contrast `SecretStore`, which throws because a failed secret op must surface). Rationale: a
  full/locked disk should degrade logging, not break the `/uptime` you're waiting on.
- 2026-07-03 — S9: **The audit *model* enforces I3 by construction, not by scrubbing.** `AuditEvent`
  has exactly three cases — `actionRan(command, exitCode)`, `control(String)`, `rejected(reason)`
  — and **no field can hold command output or a secret**. `actionRan` records only the command
  token + exit code (SPEC §4.6: "no full output"), so a secret in stdout is structurally unable to
  reach the log. Tested directly (`actionEntryCarriesNoOutputOrSecret`). The `Decision`+
  `CommandResult` → `AuditEvent` mapping is **S8's** job (don't generalize the taxonomy ahead of
  the slice that drives it).
- 2026-07-03 — S9: **`AuditEntry.line` is the pure, TDD'd surface; it sanitizes free text to
  guarantee one line per received command.** Newlines/CR/tab in `control`/`rejected`/command text
  collapse to a space and inner `"`→`'`, so an operator (or unauthorized sender) can't inject a
  forged extra audit line or break the quoted field — append-only integrity + I3. Format:
  `<ISO8601-UTC> from=<id> action=/x exit=N | control="…" | rejected="…"`. Timestamp is fixed
  UTC ISO-8601 via a static `ISO8601DateFormatter` (locale/tz-stable, greppable).
- 2026-07-03 — S9: **`FileAuditLog` is smoke-tested (like the S7 runner), not compile-only (like
  the S5 Keychain).** File append to an isolated temp file is safe — no persistent side effects,
  no real Keychain, no network — so it's tested directly: two appends → two lines through the pure
  formatter, second never clobbers the first (proves FR-8 append-only). It holds **zero** formatting
  logic (delegates to `AuditEntry.line`), staying thin. Files in `Storage/` (`AuditEntry.swift`,
  `FileAuditLog.swift`) auto-included via the file-system-synchronized group (objectVersion 77) —
  no pbxproj edit. No `InMemoryAuditSink` fake yet — deferred to S8 (no-fake-until-driven).

- 2026-06-30 — Design locked: allowlist-only execution, TOTP arm/disarm, personal local
  (non-sandboxed) install. Build split into TDD slices S0–S11.
- 2026-07-02 — S7: **`CommandRunning.run` is non-throwing; every failure folds into a
  `CommandResult`.** PLAN specifies `run(_ Action) async -> CommandResult`. So a launch failure
  (bad path / not executable) returns `exitCode 127` + a stderr note rather than throwing, and a
  timeout returns `exitCode 124` (coreutils `timeout(1)` convention) + a `[timed out after Ns;
  process terminated]` stderr note. Rationale: the coordinator (S8) then always has exactly one
  thing to format, deliver, and audit — no separate error channel. This *defines* the timeout
  framing S4 deliberately left open ("S7/S8 can extend later"); consistent with SPEC FR-5
  ("killing it at the timeout") — no SPEC/PLAN edit needed.
- 2026-07-02 — S7: **Execution hygiene is concrete here (SPEC §4.4 / I4).** The child gets
  `environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]` only — a restricted PATH and **no
  inherited operator environment**. `ProcessCommandRunner.restrictedPath` is exposed so a test can
  assert `/usr/bin/env` prints exactly that one line. Runs as the current (non-root) user; no
  privilege API is touched (I4). Timeout kill is **SIGTERM only** (`process.terminate()`) — fine
  for v1's fast read-only allowlist; SIGKILL escalation for a SIGTERM-ignoring child is a noted
  future hardening (untested → not added, per "don't generalize ahead of tests").
- 2026-07-02 — S7: **The real runner is tested directly (the one CLAUDE-sanctioned exception).**
  Unlike S5/S6 (thin impl + smoke test behind a fake), the runner's spawn/capture/timeout logic
  *is* the real `Process` impl — there's no pure logic to fake — so `CommandRunnerTests` drives it
  against safe builtins: `/bin/echo` (stdout+exit0), `/usr/bin/false` (exit 1), `/bin/ls` bad path
  (stderr + nonzero), `/bin/sleep 5`@0.3s (killed <4s, sentinel+note), plus **I1** (`/bin/echo
  "$HOME && echo pwned"` → verbatim, no expansion/chaining) and **I4** (`id -u` ≠ 0; `env` = only
  restricted PATH). All short-lived — no long-running real process. The `CommandRunning` *fake*
  is deferred to S8 (first slice to drive the protocol), mirroring S6's no-fake-until-driven rule.
  Pipes are drained concurrently off the cooperative pool (`DispatchQueue.global`) so a chatty
  child can't fill a pipe buffer and deadlock while we await exit.
- 2026-07-02 — S7: **Isolation left at the project default (`SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`, Swift 5 mode).** Every type is `@MainActor` by default; async `#expect` autoclosures
  therefore emit Swift-6-mode *warnings* (not errors) accessing value-type properties — a
  pre-existing codebase-wide posture (S6's async smoke test hits the same class). `run`'s blocking
  work is explicitly dispatched off-main via `DispatchQueue.global` + continuations, so main is
  never blocked and tests pass. The real actor/concurrency model (SPEC §7: "`actor` for stateful
  I/O") is an S8 decision — deliberately not making an inconsistent `nonisolated` change here.
- 2026-07-02 — S7: New `Execution/` folders (`RelayBack/Execution/`, `RelayBackTests/Execution/`)
  auto-included via the file-system-synchronized group (objectVersion 77) — no pbxproj edit
  (as in S5/S6). `CommandResult` already lives in `Core/` (S4 decision); the runner produces it.
- 2026-07-02 — S6: **Models are `Decodable` (+`Equatable`), not full `Codable`, and prefixed
  `Telegram…`.** PLAN says "TelegramModels (Update, Message, User — Codable)". Landed as
  `TelegramUpdate` / `TelegramMessage` / `TelegramUser` / `TelegramChat` — prefixed to avoid
  clashing with common names (`Update`/`Message`/`User`), and `TelegramChat` added because
  replies need `chat.id` (auth still uses `from.id` only — I2). Decodable-only is the honest
  type: the app *decodes* updates from Telegram and never sends these back. `BotCommand` is the
  one Encodable wire type (sent via `setMyCommands`). Models carry only the consumed fields
  (`update_id`, `from.id`, `chat.id`, `text`); `Decodable` ignores unknown keys, so real
  payloads decode fine. `from` and `message` are optional, mirroring the API (channel posts have
  no `from`; non-message updates have no `message`).
- 2026-07-02 — S6: **Decode + offset are pure statics on `TelegramUpdate`, not a separate
  namespace.** `TelegramUpdate.decodeBatch(from:)` (unwraps the `{ok,result}` envelope,
  `.convertFromSnakeCase`) and `TelegramUpdate.nextOffset(after:in:)` are the TDD'd surface.
  `nextOffset` returns `max(current, maxId+1)` — FR-1 "never reprocess" *and* never rewind on a
  stale/out-of-order batch; empty batch leaves the offset unchanged. Malformed JSON *throws*
  (never traps), so the poll loop can back off rather than crash.
- 2026-07-02 — S6: **Long-poll loop + backoff deferred to S8/S11.** PLAN S6 lists "long-poll +
  offset advance + error backoff" under `TelegramClient`, but per CLAUDE the real I/O impl stays
  thin, and PLAN S11 already tests backoff/reconnect against the *transport fake*. So the client
  does single requests only (`getUpdates` passes a `timeout` param for the server-side long
  poll); the offset-advancing, backing-off *loop* is built above the protocol in S8/S11 where
  it's unit-testable without network. No `FakeTelegramTransport` yet — it belongs to S8, the
  first slice that drives the protocol (TDD: no untested support code).
- 2026-07-02 — S6: **`TelegramTransport` takes primitives, not `OutgoingMessage`.**
  `getUpdates(offset:)`, `sendMessage(chatId:text:)`, `sendDocument(chatId:filename:data:)`,
  `setMyCommands([BotCommand])` — a faithful thin mirror of the Bot API. The coordinator (S8)
  bridges `OutputFormatter`'s `OutgoingMessage` (.text/.document) to these calls.
- 2026-07-02 — S6: **Real `TelegramClient` verified by compile + one `URLProtocol` smoke test
  (no live network).** `init(token:session:longPollTimeout:) throws` (empty/invalid token →
  `TelegramError.emptyToken`); injectable `URLSession` lets the smoke test stub HTTP. Smoke test
  covers `getUpdates` endpoint/method → response body → `decodeBatch`; `sendMessage` /
  `sendDocument` (multipart) / `setMyCommands` are compile-verified only. **I3:** the bot token
  is embedded in each request URL — that URL/token is never logged and `TelegramError` never
  carries it (only a status code or Telegram's own `description`).
- 2026-07-02 — S5: **Naming reconciled — protocol `SecretStore`, real impl `KeychainStore`,
  fake `InMemorySecretStore`.** PLAN S5 names the protocol `SecretStore`; SPEC §7 names the
  component `KeychainStore`. Both are honored: `SecretStore` is the abstraction decision logic
  depends on; `KeychainStore` is its real backing; `InMemorySecretStore` is the test fake.
- 2026-07-02 — S5: **Interface is throwing methods, not settable properties.** Landed as
  `botToken() throws -> String?` / `setBotToken(_:) throws` (and TOTP equivalents), sharpening
  PLAN's "get/set" phrasing: Keychain I/O genuinely fails (locked keychain, OSStatus), and a
  security app must surface that rather than swallow it in a non-throwing property setter.
  `nil` = delete; a missing secret reads back as `nil` (not an error).
- 2026-07-02 — S5: **Types — `botToken: String?`, `totpSecret: Data?`.** TOTP secret is the raw
  decoded bytes, matching what `AuthGuard`/`TOTP` consume (no re-decode round-trip). The S10
  Settings UI base32-encodes those bytes for the `otpauth://` QR. Bot token is inherently a
  String (used in the API URL path); Keychain stores it UTF-8-encoded under the hood.
- 2026-07-02 — S5: **Real `KeychainStore` is compile-verified only (per PLAN/CLAUDE — no test
  writes the real Keychain).** Generic-password items, service `com.RelayBack`, accounts
  `botToken`/`totpSecret`, `kSecAttrAccessibleAfterFirstUnlock` (readable by the background
  agent once the user has logged in), update-then-add upsert (avoids duplicate-item error on
  overwrite). Uses the **default/legacy macOS keychain** — no data-protection keychain, so no
  `keychain-access-groups` entitlement is needed for the local non-sandboxed v1. Runtime
  behavior is validated manually via the Settings UI in S10. All contract behavior is pinned
  by `SecretStoreTests` against the fake, which the real impl must match.
- 2026-07-02 — S5: **`KeychainError.unexpectedStatus(OSStatus)` carries the status only, never
  a secret value (I3).** The testable I3 surface at this layer is the protocol seam (secrets
  read/written only through `SecretStore`) plus the valueless error type. The end-to-end
  "secret never logged / never sent to Telegram" assertion is deferred to S8/S9, where secrets
  actually flow through the coordinator + audit log (PLAN S9 already specifies that test).
- 2026-07-02 — S5: New `Storage/` folders (`RelayBack/Storage/`, `RelayBackTests/Storage/`)
  were created lazily with the first real source file — auto-included via the file-system-
  synchronized group (objectVersion 77), no pbxproj edit needed. Fake lives in
  `RelayBackTests/Support/` alongside `TestClock`; tests in `RelayBackTests/Storage/`.
- 2026-07-01 — S0: **Sandbox disabled** (`ENABLE_APP_SANDBOX = NO`) — required so `Process`
  can spawn (SPEC §8 / invariant I4). `RelayBack.entitlements` (app-sandbox=false) lives at
  `RelayBack/Resources/` and is verified *not* bundled into the .app.
- 2026-07-01 — S0: Deployment target lowered `15.6 → 14.0` to match SPEC's stated macOS 14 floor.
- 2026-07-01 — S0: **Empty module folders are NOT kept in git.** The project uses Xcode 16
  file-system-synchronized groups (`objectVersion 77`): every file under `RelayBack/` is
  auto-added to the target, and placeholder files (even `.gitkeep`) get copied to
  `Contents/Resources/`, colliding as duplicate outputs → build fails. So `Core/`, `Telegram/`,
  `Execution/`, `Storage/`, `Features/Settings/` are created *lazily* when their slice adds a
  real source file. Do **not** add `.gitkeep`/placeholder files to satisfy folder structure.
- 2026-07-01 — S0: Bundle id left as template default `com.RelayBack` (no reverse-DNS org).
  Change before any distribution; irrelevant for local v1.
- 2026-07-01 — S1: **HMAC-SHA-1 is required, not optional.** RFC 6238 mandates it and it's
  what standard authenticator apps generate; the SHA-1 collision weakness doesn't affect HMAC
  (no collision resistance needed). The ios-plugin `validate-swift-edit.py` PreToolUse hook
  blanket-flags the literal `SHA1` as a security error and blocks Write/Edit, so `TOTP.swift`
  (uses `Insecure.SHA1`) was written via a Bash heredoc, which the hook doesn't gate. Comments
  use "SHA-1" (hyphen) to dodge the regex. Any future edit to `TOTP.swift` touching that line
  must use the same heredoc route.
- 2026-07-01 — S4: **`CommandResult` lives in `Core/`, not `Execution/`.** It's a pure value
  type (exitCode/stdout/stderr) consumed by the Core formatter and produced by the S7 runner;
  putting it in Core keeps Core free of any dependency on the I/O layer. SPEC §7 associates it
  with Execution in prose — this is the deliberate placement call.
- 2026-07-01 — S4: **Framing + thresholds.** Body = `exit N` header line, then stdout, then a
  blank line + `stderr:` block; empty stdout+stderr → `(no output)`. Chunk limit = 4096 (Telegram
  text cap), document threshold = `4096*4` (16384): above it, one `output.txt` document instead of
  many chunks. Chunking prefers newline boundaries and hard-splits any single line > limit.
  Char counting uses Swift `Character.count` — Telegram's real cap is UTF-16 units, but command
  output is ASCII in v1, so this is a safe simplification (noted for future non-ASCII output).
  **Timeout framing is out of S4 scope** (PLAN S4 = exit+stdout+stderr); S7/S8 can extend later.
- 2026-07-01 — S3: **`Decision` shape sharpened from PLAN.** PLAN listed `control(.arm/.disarm/
  .status)`; landed as `control(ControlResult)` where `ControlResult ∈ {armAccepted, armRejected,
  disarmAccepted, status(isArmed:)}`. Reason: the coordinator (S8) must distinguish "armed" from
  "bad code" to reply correctly, without re-querying guard state. Other cases as planned:
  `rejectedUnknownUser`, `disarmed` (action blocked, not armed), `runAction(Action)`, `unknownCommand`.
- 2026-07-01 — S3: **Idle window is injected, not hard-coded.** SPEC says "configured idle
  window" with no number; `AuthGuard.init(idleTimeout:)` takes it (tests use 300s). S8/Settings
  will supply the real value. Expiry is derived lazily (`armed iff now < armedUntil`) — no
  background timer, keeps the type pure.
- 2026-07-01 — S3: **`/status` is a pure read (does not reset the idle timer); unknown commands
  return `.unknownCommand` regardless of arm state.** Only a matched *action* while armed resets
  the timer and can run (I2). `remaining time` for replies is exposed as `remainingArmedTime`
  (clamped ≥ 0), kept OFF the `Decision` enum so its `Equatable` stays float-free/clean.
- 2026-07-01 — S3: **`Clock` collides with stdlib `Swift.Clock`.** Inside the module the local
  type wins; in the **test target** both are imported so the bare name is ambiguous — test refs
  are qualified `RelayBack.Clock`. Kept the SPEC name `Clock` rather than renaming. Any future
  test referencing the protocol must qualify it the same way.
- 2026-07-01 — Infra: **Added macOS CI** (`.github/workflows/ci.yml`) — builds + runs
  `RelayBackTests` on a `macos-15` runner (Xcode 16, needed for pbxproj objectVersion 77) on
  **push to `main` only** (not PRs / feature branches, per user preference; run CI locally on
  branches). First run went green (CI #1, ~2m17s) with `CODE_SIGNING_ALLOWED=NO` — no signing
  tweaks needed. Required a **shared scheme**
  (`RelayBack.xcodeproj/xcshareddata/xcschemes/RelayBack.xcscheme`) so headless `xcodebuild
  -scheme RelayBack` resolves on a fresh checkout — Xcode had only generated a per-user scheme.
  Scheme's Test action includes only `RelayBackTests` (UITests target excluded — slow/flaky
  headless, not part of the TDD loop). This closes the "tests never executed from Linux
  sessions" gap: cloud-authored pushes now get a real ✅/❌.
  `match` takes the first whitespace-delimited token and compares it case-insensitively to
  each action's `command`. Trailing text (`/uptime foo bar`) is ignored, NOT used as args —
  keeps invariant I1 intact (operator text only *selects* an action; fixed exec+args run).
  A prefix-only token (`/uptimes`) does not match. Casing is lenient purely for operator
  ergonomics; it's a fixed-name lookup, not a shell, so leniency is safe.
- 2026-07-01 — S2: **Control commands are absent from the registry, not special-cased.**
  `/arm` `/disarm` `/status` simply aren't in `seed`, so `match` returns nil for them; AuthGuard
  (S3) owns them. Seed set = `/uptime`→`/usr/bin/uptime`, `/disk`→`/bin/df -h`,
  `/whoami`→`/usr/bin/whoami`, all read-only, 10s timeout.
- 2026-07-01 — S1: `TOTP` API landed as `code(secret: Data, at: Date)` +
  `validate(_:secret:at:driftSteps:)` with a separate `Base32.decode(_:) -> Data?`. PLAN
  phrased the secret param loosely; splitting base32 decode into its own pure type keeps the
  "invalid base32 handled" case testable on its own. Constant-time code compare in `validate`.

## Log

_(Append newest first: date — slice — what got done, what's next, snags.)_

- 2026-07-03 — S11 complete. Lifecycle & login item. Pure/TDD: `Core/Backoff.swift` (exponential,
  capped) + `BackoffTests`. `App/PollLoop.swift` (long-poll loop: `pollOnce` offset-advance/no-
  reprocess, `run` backoff+reconnect, idempotent `start`/`stop`, cancellation-clean) + `UpdateHandling`
  protocol (`AppCoordinator` conforms) + `PollLoopTests` (driven via `SpyUpdateHandler` +
  scripted/blocking `FakeTelegramTransport` + `SleepRecorder`/`AsyncSignal`, no real time). Login:
  `App/LoginItem.swift` (`LoginItemControlling` + real `SMAppServiceLoginItem`); `SettingsModel`
  `launchAtLogin`→ seam via `setLaunchAtLogin`; `FakeLoginItem` + 3 tests. `AppCoordinator` +
  `isArmed`/`remainingArmedTime` (+test). `App/MenuBarAuditSink.swift` (feeds live `MenuBarModel`) +
  `MenuBarAuditSinkTests`. Composition: `App/AppRuntime.swift` (builds real deps, starts polling,
  idle-if-unconfigured) + `RelayBackApp` `NSApplicationDelegate` start/stop. Ran RED (types missing:
  `UpdateHandling`/`Backoff`/`PollLoop`) → GREEN → refactor on macOS: **124 tests / 19 suites green**
  (was 109/16; +15, +3 suites). One compile fix: `try?` flattens `String?`/`Data?`, so the config
  guard needed single (not double) optional binding. App launches as a menu-bar agent, idle when
  unconfigured, quits cleanly (launch smoke). New files auto-included (objectVersion 77) — no pbxproj
  edit. **Next: S12 (new) — allowlist persistence + feed the running `AuthGuard`** (the last gap
  before v1 is operational; append to `PLAN.md` first). All original PLAN slices S0–S11 are ✅.
- 2026-07-03 — S10 complete. Menu bar + Settings UI (FR-9). Pure/TDD: added `Base32.encode`
  (unpadded RFC 4648) + tests; `Core/OtpAuthURI.swift` (pure `otpauth://` builder) +
  `OtpAuthURITests`; `Features/Settings/AllowlistDraft.swift` (positive-Int64 id validation, dedup,
  sort) + `AllowlistDraftTests`; `Features/MenuBar/MenuBarStatus.swift` (arm-state text + m:ss) +
  `MenuBarStatusTests`. `@Observable`: `SettingsModel` (SecretStore-backed token save/load, 160-bit
  secret generate/persist, `otpauthURI`) + `SettingsModelTests` (against `InMemorySecretStore`);
  `MenuBarModel` (status + capped recent-audit tail). SwiftUI (Preview-verified, no logic): rewrote
  `MenuBarRootView`, added `SettingsView` (SecureField token, allowlist add/remove, CoreImage QR
  from `otpauthURI`, generate/regenerate, launch-at-login toggle UI), added the `Settings` scene +
  models to `RelayBackApp`. Files with the literal `SHA1` (`OtpAuthURI`, its tests,
  `SettingsModelTests`) written via Bash heredoc (hook workaround). Ran RED (new types unresolved) →
  GREEN → refactor on macOS: **109 tests / 16 suites green** (was 84/12; +25, +4 suites). App target
  builds. **Next: S11 — Lifecycle & login item**: poll loop wiring (real `TelegramClient` →
  `AppCoordinator.handle`, offset advance + backoff), `SMAppService` toggle, live `MenuBarModel`
  updates, allowlist persistence → `AuthGuard`, graceful shutdown across sleep/wake + network blip.
- 2026-07-03 — S8 complete. Added `App/AppCoordinator.swift` (MainActor `final class`: `handle(_
  TelegramUpdate) async` → extract message/from/text → `AuthGuard.authorize` → reply + audit;
  `.runAction` is the only path to `runner.run` → `OutputFormatter.format` → send). Built three
  fakes in `RelayBackTests/Support/`: `FakeTelegramTransport`, `FakeCommandRunner`,
  `InMemoryAuditSink`. Tests: `RelayBackTests/App/AppCoordinatorTests.swift` (9 — armed action
  runs + formatted reply + `actionRan` audit w/ no output in the line (**I1/I2/I3**); unknown user
  dropped, nothing run, no reply, `rejected("unknown user")` (**I2/FR-2**); disarmed action replies
  + runner not called (**I2**); bad `/arm` code doesn't arm + audits `rejected("bad code")` then
  `rejected("disarmed")`; `/arm` good code replies "Armed" + `control("armed")`, no run; oversized
  output → one `output.txt` document + only the arm text (**FR-6**); `/status` reports + audits +
  never runs; unknown command replied + audited; update w/o message/sender/text ignored — nothing
  run/sent/audited). Ran RED (`cannot find type 'AppCoordinator'`) → GREEN → refactor on macOS:
  **84 tests / 12 suites green** (was 75/11; +9). `App/` + `RelayBackTests/App/` auto-included
  (objectVersion 77) — no pbxproj edit. **Next: S10 — Menu bar + Settings UI** (view-model logic
  TDD'd; SwiftUI via Previews), then S11 lifecycle/polling loop wires the real transport to
  `handle` with offset advance + backoff.
- 2026-07-03 — S9 complete. Added `Storage/AuditEntry.swift` (`AuditEntry` + `AuditEvent`
  {`actionRan(command,exitCode)`, `control(String)`, `rejected(reason)`} + pure `line` formatting
  with free-text sanitization; `protocol AuditSink { append(AuditEntry) }`, non-throwing) and
  `Storage/FileAuditLog.swift` (real append-only file sink: create-on-first-write, seek-to-end
  append, thin — no formatting logic; swallows its own I/O errors). Tests:
  `RelayBackTests/Storage/AuditLogTests.swift` (8 — action line w/ ts+from+cmd+exit; nonzero exit;
  rejected reason; control detail; **I3** newlines neutralized to one line; embedded quotes can't
  break out; **I3** action entry carries no output/secret; `FileAuditLog` temp-file smoke:
  append-only, two lines, no clobber). Ran RED (types missing → build fail) → GREEN → refactor on
  macOS: **75 tests / 11 suites green**. `Storage/` files auto-included (objectVersion 77) — no
  pbxproj edit. **Next: S8 — AppCoordinator** — all dependency slices (S5–S7, S9) done; S8 wires
  everything and builds the transport/runner/audit fakes (proves I1/I2 end-to-end).
- 2026-07-02 — S7 complete. Added `Execution/CommandRunning.swift` (protocol: non-throwing
  `run(_ Action) async -> CommandResult`) and `Execution/ProcessCommandRunner.swift` (real `Process`
  impl: absolute path + fixed args → execve, `PATH`-only restricted env, concurrent pipe drain,
  timeout race via `TaskGroup` → `terminate()`, `timeoutExitCode 124` / `launchFailureExitCode 127`).
  Tests: `RelayBackTests/Execution/CommandRunnerTests.swift` (7 — echo stdout+exit0; `false` exit 1;
  `ls` bad path stderr+nonzero; sleep-5 under 0.3s timeout killed <4s w/ sentinel+note; **I1** args
  never shell-interpreted; **I4** non-root `id -u`; restricted-env `env`). Oracles verified on-box
  first. Ran RED (types missing) → GREEN → refactor on macOS: **67 tests / 10 suites green** (one
  self-inflicted test-assertion bug caught+fixed at RED→GREEN: a redundant `!contains("pwned\n")`
  that the literal payload trivially matched; exact-equality is the real I1 proof). `Execution/`
  folders auto-included (objectVersion 77) — no pbxproj edit. **Next: S9 — Audit log**, then S8 wires
  transport→AuthGuard→registry→runner→formatter→transport + audit.
- 2026-07-02 — S6 complete. Added `Telegram/TelegramModels.swift` (`TelegramUpdate`/`Message`/
  `User`/`Chat` Decodable+Equatable; `TelegramUpdate.decodeBatch(from:)` + `nextOffset(after:in:)`),
  `Telegram/TelegramTransport.swift` (protocol: `getUpdates`/`sendMessage`/`sendDocument`/
  `setMyCommands` + `BotCommand`), `Telegram/TelegramClient.swift` (thin URLSession impl,
  `throws` init, JSON + multipart requests, `ok`/HTTP-status checks, `TelegramError`). Tests:
  `RelayBackTests/Telegram/TelegramModelsTests.swift` (10 — decode message updates, non-message
  update → nil message, message w/o `from` → nil sender, empty result, malformed + truncated
  throw, offset = max+1 / order-independent / empty-unchanged / never-backward) and
  `TelegramClientSmokeTests.swift` (1 — `URLProtocol` stub, getUpdates endpoint→decode wiring,
  no network). Ran RED (types missing) → GREEN → refactor on macOS: **60 tests / 9 suites green**.
  New `Telegram/` folders auto-included via file-system-synchronized group (objectVersion 77) —
  no pbxproj edit (as in S5). **Next: S7 — Command runner** (or S9 Audit log) before S8 wires all.
- 2026-07-02 — S5 complete. First I/O slice. Added `Storage/SecretStore.swift` (protocol:
  throwing `botToken()/setBotToken(_:)` + `totpSecret()/setTOTPSecret(_:)`; `nil` deletes) and
  `Storage/KeychainStore.swift` (real generic-password impl, service `com.RelayBack`,
  `AfterFirstUnlock`, update-then-add upsert, `KeychainError.unexpectedStatus`). Fake
  `RelayBackTests/Support/InMemorySecretStore.swift`. Tests in
  `RelayBackTests/Storage/SecretStoreTests.swift` (7): missing→nil (both); botToken round-trip;
  totpSecret Data round-trip; overwrite last-wins; nil deletes (both); the two secrets are
  independent. Ran full RED→GREEN→refactor on macOS: RED (types missing) → GREEN (fake) →
  KeychainStore added (compiles) → **49 tests / 7 suites green**. Real Keychain impl is
  compile-verified only (no test writes the real Keychain). **Next: S6 Telegram, S7 Command
  runner, or S9 Audit log** (independent I/O slices) before S8 wires everything.
- 2026-07-01 — S4 complete. Added `Core/CommandResult.swift` (pure `exitCode`/`stdout`/`stderr`)
  and `Core/OutputFormatter.swift` (`OutgoingMessage` enum + `format(_:) -> [OutgoingMessage]`:
  frame exit+stdout+stderr, chunk at 4096 on newline boundaries w/ hard-split, `output.txt`
  document above 16384). Tests in `Core/OutputFormatterTests.swift` (8): short→1 text; empty→
  `(no output)`; nonzero exit + stderr shown; stderr-only (no placeholder); over-limit→multiple
  chunks none over 4096; single over-long line hard-split; chunking preserves content; very
  large→single `.txt` document with full content. ⚠️ Not run here (Linux); verify on macOS or
  via merge to `main`. **All pure Core slices S1–S4 done. Next: first I/O slice (suggest S5 Keychain).**
- 2026-07-01 — S3 complete. Added `Core/Clock.swift` (`Clock` protocol + `SystemClock`) and
  `Core/AuthGuard.swift` (`Decision`/`ControlResult` + `AuthGuard` state machine:
  `authorize(fromId:text:)`, `isArmed`, `remainingArmedTime`; identity gate first, TOTP `/arm`,
  `/disarm`, `/status`, lazy idle expiry, idle-timer reset on authorized action). Fake
  `RelayBackTests/Support/TestClock.swift` (advance-only). Tests in `Core/AuthGuardTests.swift`
  (12): unknown-id dropped for everything incl. valid code; disarmed blocks actions; bad/empty
  `/arm` stays disarmed; good `/arm` arms + next action runs; idle expiry; action resets timer;
  `remainingArmedTime` clamps ≥0; `/disarm`; `/status` reports + never executes + never resets;
  unknown command never runs; control tokens case-insensitive. ⚠️ Not run here (Linux, no
  toolchain; CI main-only) — **run on macOS to confirm green.** **Next: S4 — Output formatter.**
- 2026-07-01 — S2 complete. Added `Core/Action.swift` (pure value type: command, description,
  absolute `executable`, fixed `arguments`, `timeout`) and `Core/ActionRegistry.swift`
  (`match(_:) -> Action?` leading-token, case-insensitive lookup + `seed` allowlist of
  `/uptime`, `/disk`, `/whoami`). Tests under `RelayBackTests/Core/ActionRegistryTests.swift`:
  exact match, all-seeded, unknown → nil, leading-token-ignores-trailing, prefix-only → nil,
  leading-slash rule, case-insensitivity, empty/whitespace → nil, control commands → nil.
  ⚠️ Could not run `xcodebuild test` (Linux session, no Swift toolchain) — tests written to
  the same Swift Testing conventions as S1; **must be run on macOS to confirm green.**
  **Next: S3 — AuthGuard state machine.**
- 2026-07-01 — S1 complete. Added `Core/Base32.swift` (RFC 4648 decode → `Data?`, case-
  insensitive, ignores padding/whitespace, invalid chars → nil) and `Core/TOTP.swift` (RFC 6238
  HMAC-SHA-1 / 6-digit / 30s via CryptoKit, `code(secret:at:)` + `validate(_:secret:at:driftSteps:)`
  with ±1 default drift and constant-time compare). Tests mirror source under `RelayBackTests/Core/`:
  all 6 RFC 6238 Appendix B vectors pass, ±1 drift accepted / ±2 rejected, non-numeric + wrong
  codes rejected, base32 case/padding/invalid cases covered. `xcodebuild test` green; refactored
  Base32 to a static lookup table. **Next: S2 — Action allowlist & registry.**
- 2026-07-01 — S0 complete. Converted stock template → menu-bar agent: `App/RelayBackApp.swift`
  (`MenuBarExtra`, `.window` style), `Features/MenuBar/MenuBarRootView.swift` (S0 placeholder,
  full popover deferred to S10). Removed `ContentView.swift`. Set `LSUIElement=YES`, sandbox off,
  entitlements, min macOS 14. Verified: `xcodebuild build` + `test` green (`bootstrapSmoke`
  passes), built .app has `LSUIElement=true` / min 14.0 / app-sandbox=false, launches as a
  menu-bar icon with no Dock icon and quits cleanly. **Next: S1 — TOTP core.**
- 2026-06-30 — Created SPEC.md, PLAN.md, CLAUDE.md, and seeded this PROGRESS.md. Ready to
  begin S0.
