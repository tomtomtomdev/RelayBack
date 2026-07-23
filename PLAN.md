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
  `ActionRegistry.match(_ text:) -> Action?` (exact leading-token match). The `seed` allowlist
  is now empty (the legacy diagnostics were removed post-S19; the runnable surface is the
  repo-scoped git/build/sim commands) — `match()` semantics are exercised against a local test
  fixture, not the seed.
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
- ✅ **Done** — 253 tests / 33 suites green. `Core/RepoConfig` (Codable) persisted via
  `ConfigStore.repos()`/`setRepos()` (JSON in UserDefaults, fails closed); `AuthGuard` gained
  active-repo session state + `/cd`/`/pwd`/`/repos` control commands + a `requiresActiveRepo`
  precondition on parameterized specs (injects the active repo's root as `workingDirectory`) +
  `updateRepos` hot-reload; pure `Core/RepoListPresentation` (name+root only, no build-config leak);
  Settings gained a **Repos** pane + `SettingsModel.addRepo`/`removeRepo` (+ `onReposChanged`
  hot-reload); `AppRuntime` seeds the guard's repos and advertises `/cd`/`/pwd`/`/repos`. Active repo
  is cleared on disarm / fresh arm (§4a). No parameterized git/build/sim spec is wired yet (S17+).
  See PROGRESS decisions.

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
- ✅ **Done** — 265 tests / 34 suites green. `Core/GitCommands.all` holds the six repo-scoped
  `/usr/bin/git` specs (`/gitstatus`, `/branch`, `/checkout <branch>`, `/pull --ff-only`, `/push`,
  `/commit -a -m <msg>`), each `requiresActiveRepo: true`; `AppRuntime` wires them into the guard's
  `parameterizedCommands` and advertises them via `setMyCommands`. `GitCommandsTests` (12) pins the
  exact argv per command, the checkout/commit validation, that `/push`/`/pull` take no operator args,
  and the real git smoke (`/gitstatus` exit 0 in a temp repo). **Deviation:** `/checkout` builds
  `git checkout <branch>` (no `--`) — a `--` forces pathspec interpretation and would break the branch
  switch; the leading-`-` rejection in `ParamValidator.branch` is the real flag guard. See PROGRESS.

### S18 — xcodebuild
- **Goal:** `/build` → `/usr/bin/xcodebuild -scheme <cfg.scheme> -destination <cfg.destination>
  build`, cwd = active repo root, longer timeout. Scheme/destination come only from `RepoConfig`.
- **Tests first (RED):** resolver builds the fixed argv from config; `/build` accepts no operator
  args; a repo lacking a configured scheme → `.invalidParameters`. (No real build in CI — assert
  argv + guard only; optional manual run on macOS.)
- **Done when:** build resolver/guard tests green.
- ✅ **Done** — 272 tests / 35 suites green. `Core/BuildCommands.all` holds the one `/build` spec
  (`/usr/bin/xcodebuild -scheme <cfg.scheme> -destination <cfg.destination> build`), repo-scoped, no
  operator params. New wrinkle solved data-driven: `ParameterizedCommand` gained `configArgs:
  [RepoConfigArg]` (`.scheme`/`.destination`) emitted before `fixedArgs`; the resolver gained an
  `activeRepo: RepoConfig?` arg and draws those values from it (refusing with "no scheme/destination
  configured for this repo" if absent) — never operator text, never argv the operator controls (I1).
  `AuthGuard` threads `currentRepo` into the resolver; `AppRuntime` wires `GitCommands.all +
  BuildCommands.all` into the guard + `setMyCommands`. `BuildCommandsTests` (5) pin the argv, the
  no-operator-arg rule, and the missing-scheme/-destination rejections; `AuthGuardTests` (2) prove
  the guard passes the active repo's full config through. No real xcodebuild runs in CI.

### S19 — Simulator run *(most involved; xcrun simctl orchestration)*
- **Goal:** `/sim` → build for the configured simulator, install, launch on `cfg.simulatorDevice`
  via `/usr/bin/xcrun simctl` (multi-step: boot → install → launch). Device from config only.
- **Tests first (RED):** the step sequence is built from config (fixed argv per step); unknown /
  missing device → `.invalidParameters`; no operator arg accepted. Real end-to-end run is
  macOS-manual only.
- **Done when:** the orchestration builds the expected argv sequence in tests; documented manual
  verification steps recorded in `PROGRESS.md`.
- ✅ **Done** — 286 tests / 36 suites green. Pure `Core/SimulatorCommand` builds the ordered
  `xcodebuild build → xcrun simctl boot <device> → open -a Simulator` step sequence from the active
  repo's config (scheme/destination/simulatorDevice), refusing if any field is missing; new
  `Decision.runActionSequence([Action])` carries it; `AuthGuard` routes `/sim` (injected
  `SimulatorCommandSpec?`, nil until wired) with the same arm → active-repo → no-operator-arg gates;
  `AppCoordinator.runSequence` runs each step (shared `runStep`), stopping on the first non-zero
  exit; `AppRuntime` injects `SimulatorCommand.spec` + advertises `/sim`. **Deviations:** `/sim` is
  **build → boot → reveal**, not PLAN's literal `install → launch` (which needs a bundle-id +
  product-path the v1 `RepoConfig` doesn't model — deferred, SPEC §4a note); and the multi-step
  wrinkle is solved with a **dedicated builder + `runActionSequence`**, not a `.simulatorDevice`
  `RepoConfigArg` (the `configArgs`-before-`fixedArgs` ordering can't express `simctl boot <device>`,
  where the value trails the verb). No real simulator runs in CI (argv sequence + guard only);
  manual steps in PROGRESS. See PROGRESS decisions.

**S15–S19 done when:** an armed operator can `/cd` to a configured repo and run the git/build/sim
commands from a phone, every parameter is validated-argv (no shell, proven by invariant tests),
the full suite is green, and no SPEC §4 invariant is weakened.

---

## Agent action (S20–S22) — `/claude` headless Claude Code *(added 2026-07-19)*

**Why added:** the operator wants to drive Claude Code from Telegram, not just fixed actions. This
is a deliberate threat-model change (SPEC §4b): the prompt is the one free-text parameter, contained
by Claude Code's permission profile + active-repo cwd rather than a validator. Reuses S7 runner
hygiene, S16 active-repo scoping, S4 output, S9 audit.

**Decisions locked:** one-shot `claude -p` (not a persistent session — that's S23); capability toggle
`claudeEnabled` **default OFF**; permission profile default `restricted`, `fullBypass` an explicit
opt-in with a Settings warning; cwd = active repo only (no `--add-dir`); prompt is the value of `-p`
(single inert token). **Confirm exact Claude Code flags against current docs** before wiring — they
evolve.

**Scope guard:** no change to I1–I4. New I5 governs `/claude`. Every slice adds an invariant test
that a hostile prompt (metachars, leading `-`) stays a single argv token and never becomes a
flag/executable, and that a disabled toggle or missing active repo spawns nothing.

### S20 — Claude agent foundation *(pure + thin I/O; no bot command yet)*
- **Goal:** the mechanism, tests only — no user-facing command wired.
  - `ClaudeProfile` (+ `claudeEnabled`) in `ConfigStore`.
  - Pure `ClaudeInvocation.build(prompt:repoRoot:profile:) -> (executable,[argv])`: `-p <prompt>` +
    the profile's allowed/denied-tool / permission-mode flags; prompt is a single token; disabled
    profile is not buildable.
  - `protocol ClaudeRunning` + fake; real `ProcessClaudeRunner` (reuses S7 timeout/kill).
- **Tests first (RED):** prompt with shell metachars / leading `-` stays one argv token, never a
  flag; each profile maps to its expected flag set; empty prompt rejected; runner honors cwd +
  timeout (a `/bin/echo`-style stand-in under the `ClaudeRunning` fake, plus a real-runner smoke
  against a trivial binary); no command matchable yet (proven by a test).
- **Done when:** foundation tests green; `/claude` not yet routable.

### S21 — `/claude` command wiring
- **Goal:** route `/claude <prompt>` through the guard + coordinator.
  - `AuthGuard` gates: armed **AND** `claudeEnabled` **AND** active repo, else
    `.invalidParameters(reason)` (enable-in-Settings / select-a-repo / empty-prompt).
  - `AppCoordinator` runs it via `ClaudeRunning` (cwd = active repo), formats output (reuse S4),
    writes the secret-free audit line.
  - Advertise `/claude` via `setMyCommands` only while enabled.
- **Tests first (RED):** disabled → refused, runner **not** called, audit notes it; armed + enabled
  + repo → runner called with the S20 invocation; no active repo → refused; oversized output →
  document; audit line carries no prompt/output/secret; invariant test (I5) — none of {disabled,
  disarmed, no-repo} spawns.
- **Done when:** guard + coordinator scenario tests green; end-to-end with fakes proves I5.

### S22 — Settings: Claude capability pane
- **Goal:** a **Claude** pane (or section): the `claudeEnabled` toggle (default OFF), a
  permission-profile picker (`restricted` / `editsInRepo` / `fullBypass` — the last with a red
  warning subtitle), `executablePath` (folder/file picker, reuse the S-post-19 `FolderPicking` seam
  pattern), and the agent timeout. `@Observable` view-model.
- **Decision to make first:** does enabling/disabling at runtime hot-reload the guard + re-advertise
  commands (like the S12 allowlist decision), or apply on next arm? Record it. Recommend hot-reload
  for parity with repos/allowlist.
- **Tests first (RED):** view-model — toggle + profile round-trip through `ConfigStore`;
  `fullBypass` selection sets the warning flag; disabling clears advertisement intent. Thin pickers
  Preview-verified.
- **Done when:** pane usable in a Preview; view-model tests green; toggling reaches the live guard
  per the recorded decision.

**S20–S22 done when:** with `claudeEnabled` on, an armed operator can `/cd` to a repo and
`/claude <prompt>`, the prompt is a single inert argv token (no shell, proven by an invariant test),
output returns via the existing formatter, the run is audited secret-free, the suite is green, and
only I5 is added — I1–I4 unchanged.

### S23 — *(deferred)* persistent session + streaming + `/kill`
- A long-lived Claude Code session fed turn-by-turn with streamed partial output and a `/kill`.
  Different architecture (stateful session actor, output streaming, backpressure) than the one-shot
  model above; closes the §10 streaming item. Not v1.

---

## Release & distribution (S26–S30) — `/release` + `/pgyer` (PGYER upload) *(added 2026-07-22)*

**Why added:** the operator wants to build an iOS archive, export an `.ipa`, and ship it to PGYER
from Telegram. This is a deliberate threat-model change (SPEC §4c): the **first action that sends
data off the Mac to a third party**, and the first **stored third-party secret** (the PGYER API
key). It stays inside I1 (no shell — every argv value is config/Keychain, never chat) and reuses the
`/sim` multi-step contract, S7 runner hygiene, S16 active-repo scoping, S4 output, S9 audit.

**Decisions locked:** a multi-step `/release` (archive → export → upload, stop-on-first-failure) plus
a standalone `/pgyer` (upload the configured artifact only, for `.ipa`/`.dmg` without a rebuild); the
PGYER key lives in the Keychain (`SecretStore`) and is passed via a **0600 `curl --config` file**, so
it never appears in argv/`ps`/audit/reply; the endpoint URL is non-secret config (`ConfigStore`,
default `https://www.pgyer.com/apiv2/app/upload`); `-sdk iphoneos -configuration Release` fixed in
code; the build note is a per-repo configured `pgyerDescription` (no operator free-text). Missing
key/field **fails closed** — nothing spawns.

**Scope guard:** no change to I1/I2/I4; I3 is extended to name the PGYER key (Keychain-only, argv-free
via `--config`) and §4c adds the egress threat-model note. The secret never enters `Core`, the guard,
or the `Decision` — only the coordinator holds it, at spawn time. Every slice adds an invariant test
that the key never reaches an argv slot, the audit line, or a reply.

### S26 — SPEC/PLAN/CLAUDE amendment *(docs only)*
- **Goal:** scope §4c before code (this slice). SPEC §2 egress annotation, extended I3 + control 5,
  new §4c, §5 grammar (`/release`/`/pgyer`), FR-12, §7 types (`ReleaseCommand`, `CurlConfigWriting`),
  §10 note; this PLAN section; CLAUDE.md I3 bullet + a third-party-egress guardrail.
- **Done when:** docs are internally consistent; no code/test change (suite count unchanged).

### S27 — Secret + config + repo-config fields *(TDD)*
- **Goal:** the persistence foundation.
  - `SecretStore.pgyerApiKey()`/`setPgyerApiKey(_:)` (+ `KeychainStore` account, `InMemorySecretStore`).
  - `ConfigStore.pgyerUploadURL()`/`setPgyerUploadURL(_:)` (default the pgyer endpoint, fails closed to
    it; + `UserDefaultsConfigStore`, `InMemoryConfigStore`, `PreviewConfigStore`).
  - `RepoConfig` optional `workspace`, `exportOptionsPlist`, `uploadArtifact`, `pgyerDescription`
    (Codable-backward-compatible; defaulted init params keep all call sites compiling).
- **Tests first (RED):** key round-trip/missing→nil/overwrite; URL default + round-trip; repo-config
  JSON round-trip incl. old blobs decoding with the new fields nil.
- **Done when:** foundation tests green; nothing user-facing yet.
- ✅ **Done** — 359 tests / 39 suites green. `SecretStore.pgyerApiKey()`/`setPgyerApiKey` (Keychain
  account `"pgyerApiKey"`, third I3 secret; `InMemorySecretStore`/`PreviewSecretStore` updated);
  `ConfigStore.pgyerUploadURL()`/`setPgyerUploadURL` failing closed to the default endpoint, with the
  default + blank→default fallback centralized in a `ConfigStore` protocol extension
  (`defaultPgyerUploadURL` / `resolvedPgyerUploadURL`, shared by all three impls); `RepoConfig` gained
  optional `workspace`/`exportOptionsPlist`/`uploadArtifact`/`pgyerDescription` (defaulted init params,
  Codable-backward-compatible so pre-S27 blobs decode with them nil). **Deviation:** implemented a
  blank→default fail-closed (SPEC §4c "fails closed to it"), beyond the literal "default + round-trip".
  Key-egress invariant tests deferred to S28/S29 where the key actually flows. See PROGRESS decisions.

### S28 — Pure `Core/ReleaseCommand` *(TDD)*
- **Goal:** the config→steps builder, secret-free.
  - `ReleaseCommandSpec` (token + description), `PgyerUpload` (artifact/url/note) + pure
    `configFileBody(apiKey:)`, `ReleasePlan` (`buildSteps: [Action]` + `upload`),
    `ReleaseCommand.plan(for:uploadURL:)` (+ a `/pgyer`-only upload builder).
  - Archive/export are fixed `/usr/bin/xcodebuild` Actions from config, derived `build/` dir; fail
    closed on any missing field.
- **Tests first (RED):** exact archive/export argv from config; every step in repo root (I1);
  each missing-field rejection; `configFileBody` carries key + form fields; **plan is secret-free**
  (no key in `buildSteps`/`upload` — the I3-at-the-builder check).
- **Done when:** builder tests green; not yet routable.
- ✅ **Done** — 374 tests / 40 suites green (+15 / +1). `Core/ReleaseCommand` with `spec` (`/release`)
  + `pgyerSpec` (`/pgyer`); `plan(for:uploadURL:)` builds two fixed `/usr/bin/xcodebuild` steps
  (`archive` → `-exportArchive`) in the repo root from config, deriving `<root>/build/` paths, fixed
  `-sdk iphoneos -configuration Release`, failing closed on any missing `workspace`/`scheme`/
  `exportOptionsPlist`/`uploadArtifact`; `upload(for:uploadURL:)` is the `/pgyer`-only builder (artifact
  required, reused by `plan` with its refusal propagated). `PgyerUpload` (secret-free artifact/url/note)
  + `configFileBody(apiKey:)` emits the 0600 `curl --config` form fields (`_api_key`/`file`/optional
  `buildUpdateDescription`); the key is a parameter, never in the plan (`planNeverCarriesTheApiKey`
  proves it structurally — the S28 half of the key-egress invariant; argv/ps/audit/reply checks land in
  S29). **Decisions:** two specs (not one) for independent S29 routing; endpoint URL rides as a curl arg
  (not in the config body) per S29's `curl --config <path> <url>`; `buildUpdateDescription` = PGYER
  apiv2's note field. Not routable yet (guard/coordinator/`AppRuntime` untouched).

### S29 — Guard routing + coordinator run *(TDD)*
- **Goal:** route `/release`/`/pgyer` and run them.
  - `AuthGuard`: `Decision.runRelease`/`.runPgyerUpload`, injected `releaseCommand` +
    `pgyerUploadURL`; `resolveRelease`/`resolvePgyer` gate order = arm (I2) → active repo → no
    operator arg → build (mirrors `resolveSimulator`).
  - `AppCoordinator`: injected PGYER-key provider + `CurlConfigWriting` seam; `runRelease` runs the
    build steps via `runStep` (stop on non-zero), then reads the key (missing → refuse, fail closed),
    writes the 0600 config file, spawns `/usr/bin/curl --config <path> <url>`, deletes the file.
- **Tests first (RED):** full 3-step pipeline in order + secret-free audit each; stops on
  archive/export failure (no upload); missing key → refused, no curl spawn, secret-free audit;
  disarmed / no-repo → refused, nothing spawns (I2); reply + audit never contain the key (I3).
- **Done when:** guard + coordinator scenario tests green; end-to-end with fakes proves §4c.

### S30 — Settings UI + AppRuntime wiring
- **Goal:** make it configurable + reachable.
  - `SettingsModel`/`SettingsView`: a `SecureField` for the PGYER key (via `SecretStore`) + an
    upload-URL field (via `ConfigStore`, pre-filled with the default); Repos add-form gains
    `workspace`/`exportOptionsPlist`/`uploadArtifact` (picked via the existing `FolderPicking`
    `chooseFile()` seam) + a typed `pgyerDescription`.
  - `AppRuntime`: inject `ReleaseCommand.spec` + `pgyerUploadURL()` into the guard, the key provider +
    curl-config writer into the coordinator, advertise `/release`/`/pgyer`, hot-reload on Settings
    changes (mirrors `onReposChanged`).
- **Tests first (RED):** view-model — key persist via `SecretStore`, URL persist+default, new repo
  fields round-trip through `addRepo`. Thin views Preview-verified.
- **Done when:** pane usable in a Preview; view-model tests green; `/release` reaches the live guard.
  **Manual smoke (not in CI):** set key/URL + a repo, `/arm`→`/cd`→`/release`; confirm archive→export
  →upload, stop-on-failure, missing-key refusal, and a secret-free audit log.

**S26–S30 done when:** with a PGYER key + a fully-configured repo, an armed operator can `/cd` then
`/release` to archive/export/upload (or `/pgyer` to upload only); the key never leaves the Keychain
except into a 0600 `--config` file at spawn time (never argv/audit/reply, proven by an invariant
test); output returns via the existing formatter; the run is audited secret-free; the suite is green;
I1/I2/I4 unchanged and I3 holds for the new secret.

---

## Configurable local scripts (S31–S34) — `/run` operator-picked scripts *(added 2026-07-23)*

**Why added:** the operator wants to trigger their own local maintenance/deploy scripts from
Telegram without hard-coding each one. The Mac operator picks a local script **file** in Settings;
`/run` triggers it from chat. This is a threat-model change (operator-defined executables) but stays
inside I1: the script is an ordinary registry `Action` (fixed absolute executable, fixed argv, execve
via the script's shebang — never `/bin/sh -c`), and chat only *selects* among the locally-configured
scripts — it never supplies a path, an argument, or script content.

**Decisions locked (2026-07-23):** an allowlist of picked scripts (not a single bound script), with
`/run` running the one directly / offering a tap-keyboard picker among several (mirrors S25 `/cd`);
the script path is chosen only via the Settings file picker (`FolderPicking.chooseFile()`), always
absolute; zero operator arguments in v1 (all args fixed — no §4a validated params on scripts); a
non-absolute path fails closed at `ScriptConfig.toAction()` (never runnable). Config is non-secret
(`ConfigStore`, JSON, fails closed to `[]`).

**Scope guard:** no change to I1–I4 and no new invariant — a configured script is a registry `Action`.
Every slice adds/keeps a test that chat text never fills the executable or an argv slot (only the
`/run` token / a picked label selects a pre-configured entry) and that a non-absolute/empty path is
refused. Runs as normal user under the restricted PATH (I4).

### S31 — SPEC/PLAN/CLAUDE amendment *(docs only)*
- **Goal:** scope §4d before code (this slice). SPEC §2 shell-non-goal annotation, new §4d, §5
  grammar (`/run`), FR-13, §7 (`ScriptConfig` + module map); this PLAN section; a CLAUDE.md guardrail
  bounding the configurable script allowlist.
- **Done when:** docs are internally consistent; no code/test change (suite count unchanged).

### S32 — `ScriptConfig` + persistence *(TDD)*
- **Goal:** the persistence foundation, secret-free.
  - `Core/ScriptConfig` (Codable): `label`, `path`, optional `workingDirectory`, `timeout`; pure
    `toAction() -> Action?` that **fails closed** (nil) on a non-absolute/empty path and derives the
    `command` token + `description` from the label.
  - `ConfigStore.scripts()/setScripts(_:)` — JSON in `UserDefaults`, fails closed to `[]` (mirrors
    `repos()`); `InMemoryConfigStore`/`PreviewConfigStore` updated.
- **Tests first (RED):** `ScriptConfig` JSON round-trip incl. old blobs; `toAction` maps a valid entry
  to the expected absolute executable + empty argv; **rejects a relative/empty path** (the I1
  fail-closed check); config round-trips + fails closed to `[]`.
- **Done when:** foundation tests green; nothing user-facing yet.
- ✅ **Done** — 386 tests / 41 suites green (+12 / +1). `Core/ScriptConfig` (Codable): `label`/`path`/
  optional `workingDirectory`/`timeout` (default 300s), with a custom `init(from:)` so a minimal blob
  (`label`+`path` only) decodes with the optionals defaulted (forward/backward-compatible, mirrors
  `RepoConfig`). Pure `toAction() -> Action?`: executable = the script's own absolute `path`, **empty
  argv** (execve via shebang, I1 — no `/bin/sh -c`), cwd = `workingDirectory`; command token = `"/" +
  slug(label)`, description = the (trimmed) label. **Fails closed (nil)** on a non-absolute/empty path
  *and* a label that slugs to nothing (would yield a degenerate `/` token). `ConfigStore.scripts()/
  setScripts()` — JSON in `UserDefaults` (key `"scripts"`), fails closed to `[]`; added to the protocol
  + `UserDefaultsConfigStore` + `InMemoryConfigStore` + `PreviewConfigStore`. **Deviation:** added a
  blank/punctuation-only-label fail-closed guard beyond the literal "relative/empty path" check (same
  I1 spirit — an unrunnable degenerate token). Not routable yet (registry seed / `/run` / hot-reload =
  S33). See PROGRESS.

### S33 — `/run` trigger + seed-from-config + hot-reload *(TDD)*
- **Goal:** route `/run` and make the registry operator-configured.
  - `AppRuntime` seeds the `ActionRegistry` from `configStore.scripts().compactMap { $0.toAction() }`
    and advertises `/run` (and, if chosen, each script command) via `setMyCommands`.
  - Hot-reload: `AuthGuard.updateActions(_:)` (mirrors `updateAllowlist`) + `AppCoordinator`
    passthrough; `AppRuntime` wires `onScriptsChanged`.
  - `ControlResult.scriptMenu([ScriptConfig])`; `/run` with one script → runs it via the existing
    `runAction` path; several → a `.keyboard` picker of labels; none →
    `.invalidParameters("no scripts configured")`.
- **Tests first (RED):** an operator-added script runs once armed / a removed one cannot (I2 +
  hot-reload); `/run` offers the labels when several, runs directly when one, refuses when none;
  invariant — only the `/run` token / a picked label flows from chat, never a path or an argument.
- **Done when:** guard + coordinator scenario tests green; end-to-end with fakes proves I1/I2 hold.

### S34 — Settings "Scripts" pane + wiring
- **Goal:** make it configurable + reachable.
  - New **Scripts** pane (mirrors Repos): a script list + add-form (label + a **Choose Script…**
    file-picker row via the existing `FolderPicking.chooseFile()` seam + optional cwd via
    `chooseFolder()` + a timeout stepper); remove affordance.
  - `SettingsModel.scripts` + `addScript(...)`/`removeScript(...)` + `onScriptsChanged` (persist +
    hot-reload, same shape as repos/allowlist).
- **Tests first (RED):** view-model — script add/remove round-trips through `ConfigStore`; the file
  picker fills the path / a cancel is a no-op; add/remove notifies `onScriptsChanged`. Thin views
  Preview-verified.
- **Done when:** pane usable in a Preview; view-model tests green; a picked script reaches the live
  guard and runs from `/run`.

**S31–S34 done when:** an operator picks a local script in Settings, `/arm`s, and triggers it via
`/run` (directly or from the picker); chat never supplies a path, argument, or script content (proven
by an invariant test); output returns via the existing formatter; the run is audited secret-free; the
suite is green; I1–I4 unchanged (no new invariant).

---

## Definition of done (whole project, v1)

All invariants (SPEC §4) hold, all FRs met, full suite green, app runs as an unattended
login-item menu-bar agent, and an operator can `/arm` from a phone and run an allowlisted
action with output returned — while away from the Mac.
