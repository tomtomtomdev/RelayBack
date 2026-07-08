# RelayBack — Implementation Plan

How we build what `SPEC.md` describes. Work is split into **small context slices** —
each is sized to fit in a single context window and to end at a clean, committed,
green-tests state. Track which slice you're on in `PROGRESS.md`.

## Ground rules (see `CLAUDE.md` for full detail)

- **TDD is mandatory for every feature slice.** Write a failing test (RED), make it pass
  with the simplest code (GREEN), then **refactor** (keep tests green). No production code
  without a failing test first.
- One slice at a time. Start a slice by reading `PROGRESS.md` + this file's slice entry.
  End a slice by updating `PROGRESS.md` (what's done, what's next, any decisions/snags).
- Pure logic before I/O. Slices are ordered so the easy-to-TDD core comes first; every
  external dependency lands behind a protocol with a fake.
- Respect the security invariants (SPEC §4) on every slice.

## Dependency order

```
S0 bootstrap
   └─ S1 TOTP ─┐
   └─ S2 ActionRegistry ─┐
   └─ S4 OutputFormatter ─┤
S1 + Clock ─ S3 AuthGuard ─┤
                           ├─ S8 AppCoordinator ── S10 MenuBar+Settings UI ── S11 lifecycle
S5 Keychain ───────────────┤
S6 TelegramClient ─────────┤
S7 CommandRunner ──────────┤
S9 AuditLog ───────────────┘
```

Slices S1–S4 are pure and independent — do them in any order. S5–S7, S9 are I/O behind
protocols. S8 wires everything. S10–S11 are UI/lifecycle.

---

## Slices

Each slice lists: **Goal**, **Tests first (RED)**, **Done when**. "Done when" always
includes: tests green, refactor pass done, `PROGRESS.md` updated.

### S0 — Project bootstrap *(scaffolding, no TDD)*
- **Goal:** Xcode macOS app `RelayBack` + `RelayBackTests` target. Folder structure per
  SPEC §7. `LSUIElement = YES`, min macOS 14, empty `MenuBarExtra` showing a placeholder.
  `RelayBack.entitlements` (no sandbox v1). Confirm it builds, launches as a menu-bar icon,
  and the test target runs one trivial passing test.
- **Done when:** `xcodebuild` builds app + tests; menu-bar icon appears; PROGRESS updated.

### S1 — TOTP core *(pure)*
- **Goal:** `TOTP` with `code(secret:at:)` and `validate(_:secret:at:driftSteps:)`
  (HMAC-SHA1, 6 digits, 30s) via CryptoKit. Base32 secret decode.
- **Tests first:** RFC 6238 Appendix B known vectors; ±1 step drift accepted, ±2 rejected;
  invalid base32 handled; wrong code rejected.
- **Done when:** all vector + edge tests green.

### S2 — Action allowlist & registry *(pure)*
- **Goal:** `Action` (command, description, executable absolute path, args, timeout) and
  `ActionRegistry.match(_ text:) -> Action?` (exact leading-token match). A small seed set
  (`/uptime`, `/disk`, `/whoami`).
- **Tests first:** exact match; unknown → nil; leading-slash + casing rules; control
  commands (`/arm` etc.) are NOT actions.
- **Done when:** match tests green.

### S3 — AuthGuard state machine *(pure, injected Clock)*
- **Goal:** `Clock` protocol (+ system + test impls). `AuthGuard` holding allowlist + arm
  state; `authorize(fromId:text:) -> Decision` where Decision ∈ {rejectedUnknownUser,
  control(.arm/.disarm/.status), disarmed, runAction(Action), unknownCommand}. Implements
  TOTP `/arm`, `/disarm`, idle timeout, idle-timer reset on authorized action.
- **Tests first:** unknown id rejected; disarmed blocks actions; `/arm` bad code stays
  disarmed; `/arm` good code arms; expiry after idle window (advance test clock); action
  resets idle timer; `/disarm` works; `/status` never executes.
- **Done when:** full state-machine table green. (Enforces invariant I2.)

### S4 — Output formatter *(pure)*
- **Goal:** `OutputFormatter.format(CommandResult) -> [OutgoingMessage]` where Outgoing is
  `.text(String)` (≤4096, split on boundaries) or `.document(name,Data)` when total exceeds
  a threshold. Includes exit-code + stderr framing.
- **Tests first:** short output → one text; >4096 → multiple chunks, none over limit;
  very large → single document; nonzero exit + stderr shown; empty output handled.
- **Done when:** chunking/threshold tests green.

### S5 — Keychain store *(I/O behind protocol)*
- **Goal:** `protocol SecretStore { get/set botToken; get/set totpSecret }`, in-memory fake,
  real `KeychainStore` impl.
- **Tests first:** against the fake — set/get round-trips, missing → nil, overwrite. (Real
  Keychain impl is thin; not unit-tested in CI.)
- **Done when:** fake-backed tests green; real impl compiles. (Invariant I3.)

### S6 — Telegram transport *(I/O behind protocol)*
- **Goal:** `TelegramModels` (Update, Message, User — Codable). `protocol TelegramTransport`
  (getUpdates(offset:), sendMessage, sendDocument, setMyCommands). `TelegramClient`
  URLSession impl with long-poll + offset advance + error backoff.
- **Tests first:** decode real `getUpdates` JSON fixtures (incl. non-message updates, missing
  `from`); offset advances to max+1; decode of malformed payload doesn't crash. Use a
  `URLProtocol` stub or inject a transport double — no live network.
- **Done when:** decode + offset tests green; client compiles. (FR-1.)

### S7 — Command runner *(I/O behind protocol)*
- **Goal:** `protocol CommandRunning { run(_ Action) async -> CommandResult }`,
  `ProcessCommandRunner` using `Process` (absolute path, fixed args, restricted PATH,
  timeout→terminate, captures stdout/stderr/exit code). `CommandResult` model.
- **Tests first:** real runner against safe builtins — `/bin/echo` returns stdout + exit 0;
  a sleep action exceeding a short timeout is killed and reported; nonzero exit captured.
- **Done when:** runner tests green. (Invariants I1, I4 — assert no shell, no privilege.)

### S8 — AppCoordinator *(integration, all fakes)*
- **Goal:** Wire transport → AuthGuard → ActionRegistry → CommandRunning → OutputFormatter →
  transport, plus AuditLog. The orchestration brain. Inject every dependency.
- **Tests first (with fakes):** authorized + armed action → runner called → formatted reply
  sent; unknown user → dropped, nothing run, audit notes rejection; disarmed action →
  "disarmed" reply, runner NOT called; `/arm` flow arms then a following action runs;
  oversized output → document sent. This is where invariants I1/I2 are proven end-to-end.
- **Done when:** coordinator scenario tests green.

### S9 — Audit log *(I/O behind protocol)*
- **Goal:** `protocol AuditSink { append(AuditEntry) }`, formatting pure/testable, real
  append-only file impl. No secrets in entries.
- **Tests first:** entry formatting (time, from.id, action/decision, exit code); rejection
  entries; assert token/secret never appear.
- **Done when:** formatting tests green; file impl compiles. (FR-8, invariant I3.)

### S10 — Menu bar + Settings UI
- **Goal:** `MenuBarExtra` window showing arm state + recent audit + quick actions. Settings:
  token entry (→Keychain), allowlist id management, TOTP secret generate + `otpauth://` QR,
  login-item toggle. `@Observable` view state bound to coordinator.
- **Tests first:** view-model logic only (state mapping, validation of id input, QR URL
  string construction). SwiftUI rendering verified manually via Previews.
- **Done when:** view-model tests green; UI usable in Previews + running app.

### S11 — Lifecycle & login item
- **Goal:** Start/stop polling with run state; `SMAppService` launch-at-login toggle wired to
  Settings; graceful shutdown; backoff/reconnect verified against flaky transport fake.
- **Tests first:** reconnect/backoff logic (inject failing-then-succeeding transport);
  start/stop idempotence.
- **Done when:** lifecycle tests green; app runs unattended across a sleep/wake + network
  blip without crashing or double-processing updates.

### S12 — Allowlist persistence & runtime auth wiring *(added after S11)*
- **Why added:** S11 delivered the poll lifecycle, but the authorization allowlist edited in
  Settings (S10) is never persisted or fed into the running `AuthGuard`, so the shipped agent
  authorizes no one (fails closed). This slice closes the last gap before the v1 DoD below is
  actually reachable.
- **Goal:** a non-secret config store — `protocol ConfigStore { allowlist get/set }`, in-memory
  fake, real `UserDefaults` (or JSON file) impl. `SettingsModel` persists the allowlist through it;
  `AppRuntime` reads it to build the `AuthGuard`. Decide + implement how a runtime allowlist change
  reaches the live guard (hot-reload vs. apply-on-next-launch) and whether it resets arm state.
- **Tests first:** against the fake — allowlist round-trips; a persisted allowlist is what the
  coordinator's guard authorizes against (an id added in Settings can run once armed; a removed id
  cannot). Real impl compiles / smoke only.
- **Done when:** persistence + wiring tests green; an operator whose id is in the saved allowlist
  can `/arm` and run an action end-to-end.

### S13 — Design conformance: recreate the handoff in SwiftUI *(added after S12)*

- **Why added:** v1 logic is complete (S0–S12) but the SwiftUI surfaces are a generic
  functional scaffold, not the shipped **design handoff** (`design_handoff_relayback_app/` —
  `RelayBack.dc.html` + `README.md`). The handoff is **high-fidelity** and explicitly asks for a
  pixel-faithful native recreation (system font / SF Mono / SF Symbols, exact tokens). This epic
  brings the UI up to that bar **without touching the verified core** — every change is either a
  pure, test-first view-model extension or a thin, Preview-verified view. It also drops in the
  finalized app icon, which was never integrated (`AppIcon.appiconset` has the 10 slots but no
  PNGs / `filename` keys).
- **Scope guard:** UI + view-model only. No change to `AuthGuard`, `ActionRegistry`,
  `CommandRunning`, `TOTP`, or the security invariants (SPEC §4). The popover action list stays
  **read-only** (execution is Telegram-only in v1 — do not add click-to-run). Secrets still flow
  only through `SecretStore` (I3): the token stays a `SecureField`, never shown back; the base32
  secret/QR derive from the store as today.
- **Too big for one context — split into ordered sub-slices S13a–S13f.** Do one per session,
  update `PROGRESS.md` between each. Later sub-slices depend on earlier ones (tokens → popover →
  audit refactor → settings shell → panes).

Shared groundwork (lands in S13a, reused throughout): a `Features/Theme` of the handoff's
design tokens — colors (`#f4f5f9` popover, `#0a6cff` accent, `#34c759`/`#248a3d` armed,
`#ff9f0a`/`#b76e00` warning, `#ff3b30` danger, `#0f1320` terminal, `155deg #4f6bff→#2aa9c9`
brand gradient), radii (popover 14 / window 12 / cards 9–10 / pills 20), and font roles
(system UI, SF Mono for commands/ids/output/countdowns). Tokens are plain constants — **not
unit-tested**; verified by the Previews that consume them.

#### S13a — App icon + popover shell (disarmed)
- **Goal:** Drop the finalized icon set into `Assets.xcassets/AppIcon.appiconset` (copy the
  handoff's `RelayBack.appiconset` contents — `Contents.json` already references the `-2x`
  filenames; do not rename). Add the `Theme`. Rebuild `MenuBarRootView` to the **disarmed**
  design: 368px shell, brand header (gradient app-glyph + "RelayBack" + a **status pill**),
  locked-state card, "Listening for updates" row with a pulsing dot + `@bot` username, and the
  Settings/Quit footer.
- **Tests first (RED):** extend the pure `MenuBarStatus` — `pillLabel` (`"ARMED"`/`"DISARMED"`),
  `pillStyle` (armed/disarmed enum the view maps to color), and `showsCountdown`. Assert the
  disarmed mapping (label, style, no countdown, the "Send /arm…" detail).
- **Done when:** icon renders in the built app; disarmed popover matches the handoff in a
  Preview; `MenuBarStatus` tests green.

#### S13b — Popover armed content (actions + last result + disarm)
- **Goal:** The **armed** popover: green ARMED pill + mono countdown chip, the
  **ALLOWLISTED ACTIONS** cards (command in accent blue + description), the dark **last-result**
  terminal card (`$ /cmd`, `exit N`, output lines), and a **"Disarm now"** footer button.
- **Tests first (RED):**
  - `MenuBarModel.actions: [ActionSummary]` seeded read-only from `ActionRegistry` (command +
    description only — no executable/args exposed to the UI). Assert it mirrors the registry.
  - A pure `LastResultPresentation(CommandResult)` → (`commandLine`, `exitLabel`,
    `exitIsSuccess`, `outputLines`). Assert exit-0 vs. nonzero framing and line splitting.
  - `MenuBarModel.lastResult` push path + a `disarm` hook (closure the coordinator wires to
    `AuthGuard.disarm`); assert "Disarm now" invokes it. **No new execution path** — assert the
    action cards carry no runnable payload (guards I1 at the UI edge).
- **Done when:** armed popover matches the handoff in a Preview; the new view-model tests green;
  `AppCoordinator`/`AppRuntime` wire `lastResult` and the disarm hook into the live model.

#### S13c — Recent-activity color coding
- **Goal:** Replace the popover's plain `recentAudit: [String]` with structured, color-coded
  rows (time · command · right-aligned status), amber for `rejected · disarmed`, red for
  `rejected · unknown id`, default for runs — per the RECENT list in the handoff.
- **Tests first (RED):** a pure `RecentActivityRow(from: AuditEntry)` mapping → (`time`,
  `command`, `statusText`, `severity: .normal|.warning|.danger`). Assert each decision maps to
  the right severity and that no secret/full-output leaks into a row (I3). Update `MenuBarModel`
  to hold `[RecentActivityRow]`; adjust `MenuBarAuditSink`'s push to build rows.
- **Done when:** mapping + model tests green; the RECENT list renders color-coded in a Preview;
  `MenuBarAuditSink` refactor keeps its existing tests green.

#### S13d — Settings sidebar shell + Security pane
- **Goal:** Reshape Settings from the single grouped `Form` into the handoff's **sidebar window**
  (Connection · Allowlist · Security · Audit · General) at ~660px. Build the **Security** pane to
  spec: QR card, `SECRET (BASE32)` row with **Copy**, **Regenerate** + **Show otpauth://**
  buttons, the green **Keychain-assurance banner**, and **Idle timeout** / **Drift tolerance**
  rows.
- **Decision to make first:** are idle-timeout and drift-tolerance **configurable** or
  **display-only**? SPEC pins the TOTP config fixed and `OtpAuthURI` is pinned to it — so default
  to **display-only** rows reflecting the real configured values (a pure formatter, testable),
  and only make them editable if the SPEC is updated deliberately. Record the choice in
  `PROGRESS.md`.
- **Tests first (RED):** a pure `SettingsPane` enum (nav model) if the selection needs logic;
  a pure formatter for the idle-timeout `m:ss` pill and the drift subtitle. Copy-to-pasteboard
  and the reveal toggle are thin glue — Preview/manual verified, no new test.
- **Done when:** sidebar swaps panes; Security pane matches the handoff in a Preview; the pane
  and formatter tests green; secrets still only via `SecretStore`.

#### S13e — Allowlist pane + General pane
- **Goal:** The **Allowlist** pane styled to spec (member rows: avatar initial + label + mono id
  + `primary`/`Remove` affordances; add-id row) and a small **General** pane (launch-at-login
  toggle relocated here).
- **Decision to make first:** the handoff shows per-member **labels** and a **primary** badge,
  but `ConfigStore`/`AllowlistDraft` store bare `Int64`s. Either (a) keep **ids-only** and treat
  names/avatars as illustrative (render an initial from the id, no label store) — smallest, no
  data-model change — or (b) extend the config to carry an optional label + primary flag
  (test-first on `AllowlistDraft`, persisted through `ConfigStore`). Recommend (a) for v1 unless
  labels are wanted; record the choice.
- **Tests first (RED):** only if (b) — `AllowlistDraft` label/primary handling and its
  round-trip through `ConfigStore`. If (a), no new logic (styling only) — Preview-verified.
- **Done when:** both panes match the handoff in a Preview; any new draft/config tests green.

#### S13f — Audit pane + Connection pane
- **Goal:** The **Audit** pane (append-only, newest-first, columns Time · from.id ·
  Action/decision · Exit, zebra rows, color-coded by decision/exit) and the **Connection** pane
  (connected `@botUsername` vs. error).
- **New seams (behind protocols, with fakes):**
  - `AuditReading` — a **read** side for the audit log (the current `AuditSink` is write-only).
    TDD a pure `AuditRowPresentation(AuditEntry)` → columns + severity against a fake reader;
    keep the real file-read impl thin (bounded tail) and smoke-test only. **Assert no
    secret/full-output column (I3).**
  - Connection state on the view model — `.connecting | .connected(botUsername:) | .error`.
    Obtaining the username needs a transport `getMe` (or deriving it from a successful poll):
    **decision** — add `getMe` to `TelegramTransport` (fake it in tests) vs. show a generic
    connected state without the username. Record the choice.
- **Tests first (RED):** `AuditRowPresentation` mapping (all decisions/exit cases, secret-free);
  a pure `connectionState → (label, style)` mapping.
- **Done when:** both panes match the handoff in a Preview; mapping + fake-backed reader tests
  green; real audit-reader smoke test green; transport addition (if chosen) fake-tested.

**S13 done when:** all sub-slices complete, the six handoff surfaces (menu-bar disarmed/armed,
Settings Security/Allowlist/Audit + Connection/General) match the design in Previews and the
running app, the finalized icon ships, the full `RelayBackTests` suite is green with the new
pure-mapping tests, and no security invariant (SPEC §4) was weakened. (Telegram chat surface #6
is reference-only — not part of the build.)

---

### S14 — Connection-lifecycle logging (persistent)
- **Goal:** A persistent, append-only record of the poll loop's transport health, separate from
  the command audit log (FR-8, which is scoped to received commands). The loop logs only
  *transitions* — reaching Telegram (`connected`) and losing it (`disconnected`) — so a healthy
  loop doesn't spam the file and an outage leaves one clear line. Backs the future S13f Connection
  pane with real history.
- **New seams (pure + thin I/O, with a fake):**
  - `ConnectionEvent` / `ConnectionLogEntry` (pure line rendering) + `ConnectionSink` protocol.
  - `ConnectionReason.from(Error)` — maps a transport error to a SHORT, **secret-free** reason
    derived from the error type/code only (never its description — a `URLError` can carry the
    token-bearing request URL). **I3.**
  - `FileConnectionLog` — thin append-only file sink (`~/Library/Application Support/RelayBack/
    connection.log`).
  - Shared helpers extracted (refactor): `LogText` (timestamp + sanitize) and `AppendOnlyFile`
    (best-effort append), now used by both the audit and connection logs.
- **Tests first (RED):** `ConnectionLogEntry.line` rendering (connected/disconnected + newline
  neutralization); `ConnectionReason.from` never leaks the URL/token (I3); `FileConnectionLog`
  append-only smoke; `PollLoop` logs disconnect→reconnect as transitions and "connected" only once
  while healthy.
- **Done when:** suite green with the new tests; the running agent writes `connection.log`; no
  security invariant (SPEC §4) weakened.
- ✅ **Done** — 158 tests / 23 suites green.

---

## Dev-workflow actions (S15–S19) — validated parameters + repo allowlist *(added 2026-07-03)*

**Why added:** the operator wants to drive real dev tasks from Telegram — navigate to a repo,
`checkout`/`pull`/`push`/`commit`, `xcodebuild`, run a simulator — instead of setting up
Tailscale + SSH. This needs **parameterized actions**, a model v1 deliberately deferred. It is
scoped in via the SPEC amendment (§2, §4/I1, **§4a**, §10) done alongside this plan: parameters
are **validated argv, never shell**; working directory is a **named repo allowlist**; remote ops
are **upstream-only**; builds use **fixed per-repo config**. I1 "no shell, ever" is unchanged.

**Decisions locked** (2026-07-03): repos = named allowlist (config: name → root, scheme,
destination, sim device); full git write power (commit/push/pull/checkout); xcodebuild uses fixed
per-repo scheme+destination. Defaults chosen: `/pull` is `--ff-only`; `/commit` is `-a -m <msg>`
(stages tracked changes, since there is no phone-side `git add`). Revisit either if it bites.

**Scope guard:** every parameter goes through a pure validator (TDD'd) and lands at a fixed argv
index; no operator text reaches a shell or the executable slot. Each git/exec slice adds an
invariant test asserting a malicious value (shell metachars, leading-`-`, path traversal, unknown
repo) is rejected or rendered inert. Runs as normal user, restricted PATH (I4).

### S15 — Parameterized-action foundation *(pure + thin I/O; no new bot commands yet)*
- **Goal:** the mechanism, exercised by tests only — no user-facing command wired.
  - `Action.workingDirectory: String?` (nil = inherit, today's behavior); `ProcessCommandRunner`
    sets `currentDirectoryURL` from it.
  - Pure validators: `ParamValidator.repoName`, `.branch`, `.commitMessage` (charset/length,
    reject leading `-`).
  - A resolver: `(command, argTokens, repoTable) -> .ok(Action) | .invalid(reason)` that builds
    the executable + fixed argv (with `--` guard) from validated tokens only.
  - `Decision.invalidParameters(String)`; `AppCoordinator` replies `⚠️ <reason>` + audits it.
- **Tests first (RED):** each validator's accept/reject table (esp. `-`, metachars, traversal,
  unknown repo); resolver builds expected argv and refuses bad input; runner honors
  `workingDirectory` (`/bin/pwd` in a temp dir smoke test); coordinator maps `.invalidParameters`
  to a reply + audit line, **no runner call**.
- **Done when:** foundation tests green; no new command is matchable yet (proven by a test).
- ✅ **Done** — 226 tests / 32 suites green. `Action.workingDirectory` + runner cwd, pure
  `ParamValidator` + `ParameterizedActionResolver` (+ `ParameterizedCommand`/`ParamKind`),
  `Decision.invalidParameters` wired through `AuthGuard` (empty spec set in production → nothing
  matchable) and `AppCoordinator` (`⚠️` reply + audit, no runner call). See PROGRESS decisions.

### S16 — Repo config + active-repo selection
- **Goal:** `RepoConfig { name, root, scheme?, destination?, simulatorDevice? }` persisted via
  `ConfigStore`; Settings UI to add/remove repos. Session **active-repo** state with `/cd <repo>`
  (validated name → sets context), `/pwd` (active repo + path + current branch), `/repos` (list).
  Active repo lives with the session (like arm state); cleared on disarm.
- **Tests first (RED):** repo list round-trips through `ConfigStore`; `/cd` unknown name →
  `.invalidParameters`; `/cd` valid sets context; git/exec command with no active repo →
  `.invalidParameters("select a repo first")`; `/repos` never leaks anything beyond name/root.
- **Done when:** config + selection tests green; Settings repo editor usable in a Preview.

### S17 — Git commands
- **Goal:** operate on the active repo via `/usr/bin/git` with fixed argv + validated params:
  `/gitstatus` (`status`), `/branch` (`branch`), `/checkout <branch>` (`checkout -- <branch>`),
  `/pull` (`pull --ff-only`), `/push` (`push` — upstream only, no remote/refspec arg),
  `/commit <msg>` (`commit -a -m <msg>`).
- **Tests first (RED):** resolver builds the exact argv per command; `/checkout` rejects a
  branch with metachars / leading `-`; `/push` and `/pull` accept **no** operator args; `/commit`
  rejects a leading-`-` message and caps length; every command runs with cwd = active repo root.
- **Done when:** git resolver/guard tests green; a real smoke test against a throwaway git repo
  (init in a temp dir) confirms `/gitstatus` returns exit 0.

### S18 — xcodebuild
- **Goal:** `/build` → `/usr/bin/xcodebuild -scheme <cfg.scheme> -destination <cfg.destination>
  build`, cwd = active repo root, longer timeout. Scheme/destination come only from `RepoConfig`.
- **Tests first (RED):** resolver builds the fixed argv from config; `/build` accepts no operator
  args; a repo lacking a configured scheme → `.invalidParameters`. (No real build in CI — assert
  argv + guard only; optional manual run on macOS.)
- **Done when:** build resolver/guard tests green.

### S19 — Simulator run *(most involved; xcrun simctl orchestration)*
- **Goal:** `/sim` → build for the configured simulator, install, launch on `cfg.simulatorDevice`
  via `/usr/bin/xcrun simctl` (multi-step: boot → install → launch). Device from config only.
- **Tests first (RED):** the step sequence is built from config (fixed argv per step); unknown /
  missing device → `.invalidParameters`; no operator arg accepted. Real end-to-end run is
  macOS-manual only.
- **Done when:** the orchestration builds the expected argv sequence in tests; documented manual
  verification steps recorded in `PROGRESS.md`.

**S15–S19 done when:** an armed operator can `/cd` to a configured repo and run the git/build/sim
commands from a phone, every parameter is validated-argv (no shell, proven by invariant tests),
the full suite is green, and no SPEC §4 invariant is weakened.

---

## Definition of done (whole project, v1)

All invariants (SPEC §4) hold, all FRs met, full suite green, app runs as an unattended
login-item menu-bar agent, and an operator can `/arm` from a phone and run an allowlisted
action with output returned — while away from the Mac.
