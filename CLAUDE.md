# RelayBack — Project Instructions for Claude Code

RelayBack is a menu-bar macOS app that runs a **fixed allowlist** of commands on an
unattended Mac, triggered from a private **Telegram bot**, gated by a **TOTP arm/disarm**
session, returning command output to chat. Full requirements: `SPEC.md`. Build sequence:
`PLAN.md`. Live status: `PROGRESS.md`.

## Start every working session here

1. **Read `PROGRESS.md` first** — it is the source of truth for what's done and what slice
   is next. It is written to survive context clears; trust it over your assumptions.
2. Read the current slice entry in `PLAN.md`.
3. Do **one slice**, then update `PROGRESS.md` before stopping (see "Ending a slice").

Work in small context slices — do not attempt multiple slices at once. Each slice ends at a
green, refactored, documented state so a fresh context can resume cleanly.

## TDD is mandatory (red → green → refactor)

Every feature slice follows the cycle, no exceptions:

1. **RED** — write the smallest failing test that expresses the next behavior. Run it; see
   it fail for the right reason. Never write production code without a failing test first.
2. **GREEN** — write the simplest code that makes the test pass. Don't generalize ahead of
   tests. Don't add untested behavior.
3. **REFACTOR** — with tests green, clean up names, duplication, and structure. Tests stay
   green throughout. This step is required, not optional — do it before moving on.

Notes:
- Pure `Core/` types (TOTP, AuthGuard, ActionRegistry, OutputFormatter) are TDD'd directly.
- For I/O types, TDD the logic behind a **protocol** using a **fake**; the thin real impl
  (Keychain, URLSession, Process) is kept minimal and verified by a focused smoke test only.
- Use RFC 6238 Appendix B vectors as the TOTP test oracle. Use an injected `Clock` so any
  time-dependent behavior (arm expiry, TOTP windows) is deterministic in tests.
- No test may hit the live network, write the real Keychain, or spawn long-running real
  processes (a `/bin/echo` smoke test for the real runner is the one allowed exception).

## Architecture (see SPEC §7 for the full map)

SwiftUI `MenuBarExtra` agent app, `@Observable` view state, Swift Concurrency `actor`s for
stateful I/O. Every external dependency sits behind a protocol with a test fake so
`AppCoordinator` and all decision logic are unit-testable without real I/O.

```
App/  Core/(pure)  Telegram/  Execution/  Storage/  Features/  Resources/
```

- `Core/` is pure and framework-light — TDD-first, no `URLSession`/`Process`/Keychain there.
- `AppCoordinator` wires transport → AuthGuard → ActionRegistry → CommandRunning →
  OutputFormatter → transport (+ AuditLog). It owns no I/O directly — only injected protocols.

## Security invariants — never violate these (SPEC §4)

These outrank convenience, brevity, or "it's just a test helper." If a change would break
one, stop and flag it.

- **I1 — No shell, ever.** Operator text is never passed to a shell or used as an executable
  or argument. Actions are looked up in `ActionRegistry`; only registry-defined absolute
  paths + fixed arg arrays are spawned via `Process`. Never `/bin/sh -c <anything>`.
- **I2 — No run unless authorized AND armed.** An action executes only when `from.id` is on
  the allowlist *and* the session is ARMED. Check `from.id`, never chat id.
- **I3 — Secrets only in Keychain.** Bot token, TOTP secret, and the PGYER API key (SPEC §4c) are
  read only from Keychain; never hard-coded, logged, written to the audit log, or sent to Telegram.
  The PGYER key is additionally kept out of the upload process's argv — passed via a 0600 `curl
  --config` file (deleted after the run) — so it never reaches `ps`. A missing key fails closed.
- **I4 — Never elevate.** `Process` runs as the normal user with a restricted PATH; never
  root, never with privilege escalation.
- **I5 — Agent action is gated (SPEC §4b, S20+).** `/claude` runs only if `claudeEnabled` AND
  armed AND an active repo is selected; spawned non-interactively, cwd = that repo root, configured
  permission profile, never elevated. Absent any, nothing spawns. `claudeEnabled` **defaults OFF**;
  `fullBypass` is never the default and must carry a visible warning. The `/claude` prompt is the
  sole free-text parameter — it is contained by the permission profile + active-repo cwd, never by
  pretending to validate it. Never pass it through a shell or into any argv position other than the
  value of `-p`.

When you add a slice that touches execution, auth, or storage, add a test that asserts the
relevant invariant still holds.

## Conventions

- Swift, async/await over Combine. `@Observable` over `ObservableObject`. Min target macOS 14.
- Keep functions small and named for behavior; match surrounding style.
- One responsibility per type; prefer pure functions in `Core/`.
- Tests mirror source folders under `RelayBackTests/`; fakes live with the tests.
- Tools: prefer `Glob`/`Grep`/`Read`/`Edit`/`Write` over shell equivalents.

## Build & test

- Build: `xcodebuild -scheme RelayBack -destination 'platform=macOS' build`
- Test:  `xcodebuild -scheme RelayBack -destination 'platform=macOS' test`
- Run for real: launch the built `.app`; it appears as a menu-bar icon (no Dock icon).
  Telegram credentials are entered in Settings, not committed anywhere.

## Ending a slice (do this before you stop)

1. Tests green and a refactor pass done.
2. Update `PROGRESS.md`: mark the slice status, note the next slice, and record any
   decisions, deviations from `PLAN.md`/`SPEC.md`, or snags a future session needs.
3. If a decision changes intended behavior, update `SPEC.md`/`PLAN.md` too — keep docs true.
4. Do not start the next slice in the same context unless explicitly asked.

## Guardrails

- Never commit a bot token, TOTP secret, or allowlist of real Telegram ids.
- v1 is non-sandboxed local personal use — don't add sandbox entitlements without revisiting
  SPEC §8 (the sandbox blocks `Process` spawning and would break the app's core purpose).
- Don't add arbitrary-shell or free-text-parameter execution — that's an out-of-scope future
  phase (SPEC §2). If the user asks for it, update the SPEC deliberately first.
- Off-box egress is bounded to what SPEC §4c scopes: the `/release`/`/pgyer` upload sends the
  *configured* artifact to the *configured* endpoint only (both config, never chat). Don't add a new
  network destination, an operator-supplied URL, or a second stored third-party secret without a
  deliberate SPEC amendment first — and any such secret goes in Keychain, never `ConfigStore`.
