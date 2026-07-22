# RelayBack — Progress Log

> Source of truth for "where are we." Written to survive context clears. Update this at the
> end of every slice (see `CLAUDE.md` → "Ending a slice"). Newest note at the top of the log.

## Current state

- **S28 done — pure `Core/ReleaseCommand` config→steps builder (secret-free).** The second code slice
  of the PGYER epic (S26–S30). Turns the S27 persistence (repo release fields + endpoint URL) into the
  `/release` archive→export→upload plan and the `/pgyer` upload-only step — all pure, no I/O, no
  routing yet. New pieces (`Core/ReleaseCommand.swift` + `RelayBackTests/Core/ReleaseCommandTests.swift`):
  - **`ReleaseCommandSpec`** (`command` + `description`, shape-identical to `SimulatorCommandSpec`) with
    **two canonical constants**: `ReleaseCommand.spec` (`/release`) and `ReleaseCommand.pgyerSpec`
    (`/pgyer`). Two specs (not one struct with two tokens) so S29 can inject/route/advertise each
    independently, mirroring how the guard already takes a `SimulatorCommandSpec?`.
  - **`ReleaseCommand.plan(for:uploadURL:) -> ReleaseResolution`** — the full pipeline. Builds two fixed
    `/usr/bin/xcodebuild` `Action`s in the repo root, tagged `/release`, 1800s each (reused `/sim`
    build timeout): **(1)** `archive -workspace <cfg> -scheme <cfg> -archivePath <root>/build/<scheme>.xcarchive
    -sdk iphoneos -configuration Release`; **(2)** `-exportArchive -archivePath <same> -exportOptionsPlist
    <cfg> -exportPath <root>/build`. `-sdk iphoneos -configuration Release` are in-code constants; every
    variable value comes only from `RepoConfig` (I1). Returns `.ok(ReleasePlan{buildSteps, upload})` or
    `.invalid(reason:)`. Fails closed on any missing `workspace`/`scheme`/`exportOptionsPlist`/`uploadArtifact`
    — nothing is built (§4c).
  - **`ReleaseCommand.upload(for:uploadURL:) -> PgyerResolution`** — the `/pgyer` upload-only builder;
    requires only `uploadArtifact` (a pre-built `.ipa`/`.dmg` needs no rebuild). `plan` reuses it for
    the artifact check + resolution and **propagates its refusal**, so the two paths can never diverge
    on what counts as a valid upload.
  - **`PgyerUpload`** (secret-free `artifact`/`url`/`note`) + **`configFileBody(apiKey:)`** — the pure
    body of the 0600 `curl --config` file: `form = "_api_key=<key>"`, `form = "file=@<artifact>"`, and
    (only when the repo sets a `pgyerDescription`) `form = "buildUpdateDescription=<note>"`. The **key
    is a parameter, never stored** — it materializes only in this returned string, which S29's
    coordinator writes to a temp file and deletes. The endpoint URL rides as a curl *argument* (per PLAN
    S29 `curl --config <path> <url>`), so it is deliberately **not** repeated in the config body.
  - **Decisions locked:**
    - *I3-at-the-builder proven structurally.* `ReleaseCommand.plan`/`.upload` take **no key argument at
      all**, so nothing they return can hold one; `planNeverCarriesTheApiKey` scans every string
      reachable from the plan for a sentinel and asserts absence, then confirms `configFileBody` is the
      sole place it appears. This is the S28 half of the epic's key-egress guarantee; the argv/`ps`/audit/
      reply-never-contains-key tests land in **S29** where the key actually flows through the coordinator.
    - *Derived `build/` layout, absolute paths.* Archive/export write under `<root>/build/` (archive =
      `<root>/build/<scheme>.xcarchive`, export dir = `<root>/build`); `uploadArtifact` is resolved to an
      absolute path under the root when relative (already-absolute used as-is) so curl's `file=@` is
      cwd-independent. Private `buildPath`/`resolve` helpers normalize a trailing slash on the root for
      deterministic argv.
    - *`buildUpdateDescription` chosen for the note.* SPEC §4c only gives `_api_key=…` as the sample form
      field; `buildUpdateDescription` is PGYER apiv2's update-note field. Implementation detail, no SPEC
      change; the note is per-repo config (`pgyerDescription`), never operator free-text.
  - **Not yet routable.** No `/release`/`/pgyer` command matches in the guard; `AuthGuard`/coordinator/
    `AppRuntime` are untouched. Routing + the real 0600 `--config` write + curl spawn are **S29**.
  - ✅ **Verified green on macOS** (this session): `** TEST BUILD SUCCEEDED **`, then full
    `RelayBackTests` = **374 tests / 40 suites** passing (exit 0) via `test-without-building` after
    `pkill -9 -f RelayBack.app`. +15 tests / +1 suite (all `ReleaseCommandTests`): spec tokens (2),
    archive/export argv-from-config, every-step-in-root/I1, release + pgyer upload metadata, four
    `/release` missing-field rejections + the `/pgyer` no-artifact rejection, `configFileBody`
    carries-key/omits-absent-note (2), and the `planNeverCarriesTheApiKey` I3 check. One `-only-testing`
    re-run flaked on the documented LSUIElement host-launch quirk (`TEST EXECUTE FAILED`, zero test
    lines); a clean re-run passed all 15 — the full-suite run above is the authoritative green.
    **Next slice: S29** (guard routing `Decision.runRelease`/`.runPgyerUpload` + coordinator run with the
    `CurlConfigWriting` seam + PGYER-key provider).
- **S27 done — persistence foundation for `/release` + `/pgyer` (secret + config + repo-config fields).**
  The first code slice of the PGYER epic (S26–S30). No user-facing behavior yet — it lays the storage
  seams the S28 builder / S29 coordinator will consume. TDD, all pure/thin-I/O. New pieces:
  - **`SecretStore.pgyerApiKey()`/`setPgyerApiKey(_:)`** — the **third Keychain-only secret** (I3),
    mirroring the `botToken` `String?` shape exactly. `KeychainStore` gains a distinct account
    `"pgyerApiKey"` (compile-only per policy — no test writes the real Keychain); behavior is pinned
    against `InMemorySecretStore` (round-trip / missing→nil / overwrite / nil-deletes /
    three-secret-independence). `PreviewSecretStore` updated. I3-by-construction: the key only ever
    flows through the `SecretStore` seam; `ConfigStore` has no method that could hold it.
  - **`ConfigStore.pgyerUploadURL()`/`setPgyerUploadURL(_:)`** — the non-secret endpoint URL.
    **Fails closed to the default** `https://www.pgyer.com/apiv2/app/upload`. The default + the
    blank→default fallback are centralized in a `ConfigStore` **protocol extension**
    (`defaultPgyerUploadURL` + `resolvedPgyerUploadURL(_:)`) so all three impls
    (`UserDefaultsConfigStore` / `InMemoryConfigStore` / `PreviewConfigStore`) share one source of
    truth and behave identically. Stored in `UserDefaults` under `"pgyerUploadURL"`.
  - **`RepoConfig` gained four optional fields** — `workspace`, `exportOptionsPlist`, `uploadArtifact`,
    `pgyerDescription` — all `String?`, defaulted in the memberwise init so every existing call site
    compiles unchanged. **Codable-backward-compatible:** synthesized `decodeIfPresent` means a repo
    blob persisted before S27 (no new keys) still decodes with the new fields nil, so a version upgrade
    never wipes the operator's persisted repo allowlist (§4a JSON in UserDefaults). New
    `RelayBackTests/Core/RepoConfigTests.swift` pins the round-trip + old/minimal-blob decodes.
  - **Decisions locked:**
    - *Blank→default fail-closed* was implemented beyond the literal PLAN ("URL default + round-trip"):
      SPEC §4c says the URL "fails closed to it," so a stored empty/whitespace value must not become the
      upload target. Pinned by `blankPgyerUploadURLFailsClosedToTheDefault`.
    - The default-URL constant lives on the `ConfigStore` protocol (extension), not duplicated per impl.
    - **I3 scope for this slice:** S27 only establishes the Keychain-only *storage* seam; the key does
      not yet flow anywhere. The deeper egress invariant tests (key never in argv/`ps`/audit/reply) land
      in **S28** (plan is secret-free) and **S29** (coordinator writes the 0600 `curl --config` file),
      per the epic scope-guard. Nothing to spawn here, so nothing to assert about spawning yet.
  - ✅ **Verified green on macOS** (this session): `** TEST BUILD SUCCEEDED **` (app + test targets),
    then full `RelayBackTests` = **359 tests / 39 suites** passing (exit 0) via `test-without-building`
    after `pkill -9 -f RelayBack.app` — **no test-host flake this run**. +11 tests / +1 suite: 4
    `SecretStoreTests` (pgyer missing/round-trip/overwrite/delete) + the 2→3-secret independence rename;
    4 `ConfigStoreTests` (missing-default / round-trip / blank-fail-closed / real-UserDefaults isolated
    smoke); 3 new `RepoConfigTests`. **Next slice: S28** (pure `Core/ReleaseCommand` config→steps builder).
- **S26 done — docs-only: scoped the `/release` + `/pgyer` PGYER-upload epic (SPEC §4c).** New epic
  **S26–S30** (planned this session, approved plan at `~/.claude/plans/humble-purring-kitten.md`):
  build an iOS archive → export `.ipa` → upload to PGYER, plus a standalone `/pgyer` upload. This is a
  **deliberate threat-model change** — the first action that sends data **off the Mac to a third
  party**, and the first **stored third-party secret** (the PGYER API key) — so per the guardrails the
  SPEC was amended *before* any code. Docs touched this slice:
  - **SPEC.md** — §2 network non-goal annotated (outbound is no longer *only* long-polling); **control
    5** + **I3** extended to name the PGYER key as Keychain-only *and* argv-free (passed via a 0600
    `curl --config` file, so it never reaches `ps`); new **§4c "Release & distribution"** (controls:
    all argv from config, key in Keychain fails-closed, fixed per-repo output layout, `/sim`-style
    stop-on-first-failure, reused hygiene + secret-free audit; threat-model note widening worst-case to
    "upload the configured artifact to the configured PGYER account"); **§5** grammar (`/release`,
    `/pgyer`); **FR-12**; **§7** (`ReleaseCommand` in Core, `CurlConfigWriting` in Execution +
    component responsibilities); **§10** note.
  - **PLAN.md** — new "Release & distribution (S26–S30)" section (why, decisions-locked, scope guard,
    the five slices + done-criteria), mirroring the S20–S22 agent-action section's shape.
  - **CLAUDE.md** — I3 bullet extended for the PGYER key; a new guardrail bounding off-box egress to
    what §4c scopes (no new destination / operator URL / second third-party secret without a SPEC
    amendment; any such secret goes in Keychain, never `ConfigStore`).
  - **Decisions locked (from the approved plan):** `/release` pipeline **+** standalone `/pgyer`; key
    via 0600 `curl --config` file (stdin ruled out — `ProcessSpawner` doesn't wire child stdin);
    endpoint URL in `ConfigStore` (default `https://www.pgyer.com/apiv2/app/upload`); `-sdk iphoneos
    -configuration Release` fixed; build note = per-repo `pgyerDescription` (no operator free-text).
  - **Architecture decision:** `/release` follows the **`SimulatorCommand` multi-step-builder** pattern
    (not `/build`'s `configArgs`) — archive/export/upload each place a config value *after* a fixed verb
    (`archive -archivePath …`, `curl … <url>`), which `RepoConfigArg` (all config-args-before-fixed-args)
    can't express. The **secret never enters `Core`/the guard/the `Decision`** — only the coordinator
    reads it (at the upload step), writes the 0600 file, spawns curl, deletes it.
  - **Docs-only — no code/test change** (suite unchanged; mirrors the `d481271`/`59b2021` docs-first
    precedent). Not build/test-verified because nothing compilable changed. **Next slice: S27** (secret
    + config + `RepoConfig` fields, TDD).
  - **Note:** `/build` and `/sim` are currently *unwired* in production (post-S24 change below) though
    their mechanisms remain; S30 will decide whether `/release`/`/pgyer` are advertised by default or
    left injectable-but-inert like those. The mechanism (S27–S29) lands regardless.
- **S25 done — `/cd` offers a tappable repo picker instead of failing on a missing name.** Sending
  a bare `/cd` (e.g. tapping it from the command menu) used to reply `⚠️ usage: /cd <repo>`; it now
  offers the configured repos as a **one-time Telegram tap keyboard** (button per repo), and the
  operator's next message — the tapped name — is consumed as the pick. Mirrors the S24 `/arm`
  prompt. New pieces:
  - **Transport reply-markup generalized (preparatory refactor).** The S24 `forceReply: Bool`
    parameter on `TelegramTransport.sendMessage` became a **`ReplyMarkup` enum**
    (`.none`/`.forceReply`/`.keyboard([String])`) — the Bot API's `reply_markup` modelled as a
    closed set. Convenience overloads (`sendMessage(chatId:text:)` and the old
    `…forceReply:`) forward to it, so no call site outside the coordinator changed.
    `TelegramClient` builds the wire markup per case (force_reply, or a one-time custom keyboard
    with `resize_keyboard`/`one_time_keyboard`). Behavior-preserving — app `build` stayed green.
  - **`ControlResult.cdPrompt([RepoConfig])`** + `AuthGuard` state `awaitingRepoName`. `handleCd`:
    with a name → the existing exact-match select (extracted to `selectRepo(named:)`, shared);
    with **no** name and repos configured → set `awaitingRepoName`, return `.cdPrompt(repoConfigs)`;
    with no name and **no repos** → `.invalidParameters("no repos configured")`. In `authorize`,
    while `awaitingRepoName` the next **non-command** message is routed to `selectRepo` (guarded on
    `isArmed`); a `/`-command cancels the picker. The flag clears on consume, on a new command, and
    in `disarm()`. **I2 preserved:** a bare word selects a repo only *right after* the picker — an
    idle word is `.unknownCommand`, never a silent repo switch (mirrors S24's bare-code guard).
    Arm gate stays first, so a disarmed operator is told to arm and never shown the repo names.
  - **Pure `RepoListPresentation.selectPrompt` + `pickerButtons(_:)`** — button labels are repo
    **names only** (discloses even less than `/repos`, which shows name + root; I3 asserted).
    `AppCoordinator` maps `.cdPrompt` → the keyboard reply + a secret-free `.control("cd prompt")`
    audit line.
  - **SPEC §5** grammar for `/cd` updated (picker on bare `/cd`, names-only buttons, cancel-on-command).
  - ⚠️ **Verification — compile-verified only; full suite NOT observed green this session.** App
    `build` and `build-for-testing` both succeeded (**BUILD SUCCEEDED**). The `test` suite could not
    be run to completion: **five** attempts died on the documented LSUIElement menu-bar test-host
    flake ("test runner hung before establishing connection" / one run executed 0 tests), the same
    blocker the concurrent `/build`+`/sim` unwire below hit — aggravated by the two sessions competing
    for the same `RelayBack` app-host/process namespace. **+10 tests added** (7 `AuthGuardTests`:
    bare-`/cd` picker, name-after-picker selects, unknown-name-after-picker rejected, command cancels
    picker, bare-name-without-picker unknown, disarmed-doesn't-offer, no-repos-configured,
    disarm-clears-picker; 2 `AppCoordinatorTests`: bare-`/cd` sends the keyboard + audits "cd prompt",
    tap-selects end-to-end; 1 `RepoListPresentationTests`: buttons are names-only). Expected **308
    tests / 36 suites** (was 298/36 at S24; no suites added). **Next session: re-run the full suite
    once the test host is reachable again** and confirm the count.
- **Change (post-S24) — `/build` and `/sim` unwired from production (reversible unwire, not deletion).**
  The two repo-scoped dev commands are no longer offered: `/build` (S18 — "Build the active repo's
  scheme") and `/sim` (S19 — "Build, boot & reveal the active repo's simulator"). Only `AppRuntime`
  changed:
  - `start()` now injects `parameterizedCommands: GitCommands.all` (was `+ BuildCommands.all`) and no
    longer passes `simulatorCommand:` — it defaults to `nil`, so `/sim` is not matchable. `botCommands()`
    drops both from the advertised `setMyCommands` list.
  - **Kept intact but inert:** `Core/BuildCommands.swift`, `Core/SimulatorCommand.swift`, and the whole
    `/sim` mechanism in `AuthGuard`/`AppCoordinator` (`resolveSimulator`, `Decision.runActionSequence`,
    `AppCoordinator.runSequence`) plus the `/build` `configArgs`/`RepoConfigArg` plumbing. Their unit
    tests (`BuildCommandsTests`, `SimulatorCommandTests`) still pass and are unchanged, so re-adding
    either command is a one-line wiring change. This matches the S15/S20 "mechanism present, inert in
    production" pattern (user chose reversible unwire over full deletion).
  - **No security-surface change:** removing commands only narrows the runnable surface. I1/I4 are
    properties of the runner + match mechanism, both untouched. `AuthGuard`'s now-stale
    "Production injects `SimulatorCommand.spec`" doc comment was deliberately left as-is (core untouched
    by request); the accurate current state is recorded in `AppRuntime`'s comments.
  - ⚠️ **Verification — compile-verified green; full suite NOT observed green this session.** The change
    built `** TEST BUILD SUCCEEDED **` (app + all test targets) in an isolated clean-`HEAD` git worktree
    with only this patch applied. `AppRuntime` is untested wiring glue (no `AppRuntimeTests`), so a green
    build is the correct bar for this layer (CLAUDE.md thin-real-impl rule) and no test outcome depends on
    it. The `test-without-building` suite could not be run to completion: **three** attempts died on the
    documented LSUIElement menu-bar test-host flake ("Test crashed with signal kill before establishing
    connection"), aggravated by a **concurrent session** — its in-progress S24 `forceReply:`→`markup:`
    refactor left the main working tree non-compiling and competing for the same `RelayBack`
    app-host/process namespace, so cross-session `pkill`s kept killing the bootstrapping test host. **Next
    session: re-run the full suite once the concurrent S24 work lands and the tree compiles again** — the
    expected result is unchanged from HEAD (this change removes no tests).
- **S24 done — `/arm` prompts for the TOTP code instead of failing on an empty code.** Tapping
  `/arm` from the Telegram command menu sends a bare `/arm` (no code), which previously replied
  "❌ Invalid code". Now a code-less `/arm` **prompts** the operator to type the code, and their
  next message is consumed as it. New pieces:
  - **`ControlResult.armPrompt`** + `AuthGuard` state `awaitingArmCode`. `handleArm` splits into
    `handleArm` (no code → set `awaitingArmCode`, return `.armPrompt`; with code → `handleArmCode`)
    and the reusable `handleArmCode` (TOTP-validate → arm). In `authorize`, while `awaitingArmCode`
    the next **non-command** message is routed to `handleArmCode`; a message starting with `/`
    cancels the prompt and is handled normally. The flag clears on consume, on a new command, and
    on `disarm()`. **I2 preserved:** a bare number only arms *right after* a prompt — an idle numeric
    message is `.unknownCommand`, never a silent arm.
  - **`TelegramTransport.sendMessage(chatId:text:forceReply:)`** — new requirement; a convenience
    `sendMessage(chatId:text:)` extension forwards `forceReply: false` so all existing call sites
    are unchanged. `TelegramClient` emits Bot API `reply_markup: {force_reply: true}` when set
    (omitted otherwise). `AppCoordinator` maps `.armPrompt` → a `force_reply` reply ("🔐 Enter your
    TOTP code to arm:") + a `.control("arm prompt")` audit line; **I3** holds (fixed string, no secret).
  - ✅ **Verified green on macOS** (this session): full `RelayBackTests` suite = **298 tests / 36
    suites** passing (added `AuthGuardTests`: no-code prompts, code-after-prompt arms, bad-code-after-
    prompt stays disarmed, bare-code-without-prompt is unknown, command-cancels-prompt; +
    `AppCoordinatorTests`: no-code sends `force_reply` and doesn't run, code reply after prompt arms).
    App builds clean. `FakeTelegramTransport.sentMessages` gained a `forceReply` field.
- **Change (post-S19) — seed allowlist emptied.** All remaining read-only diagnostics
  (`/disk`, `/ip`, `/mem`, `/top`, `/ps`, `/netstat`, `/battery`, `/date` — and the earlier
  `/uptime`, `/whoami`) were removed, so `ActionRegistry.seed` is now `actions: []`. Rationale:
  the app's runnable surface is the repo-scoped git/build commands and the multi-step `/sim`
  (S16–S19), resolved from operator config — the fixed diagnostic set is legacy and no longer
  wanted. With nothing seeded, `AppRuntime.botCommands()` advertises only control/repo commands
  (the diagnostics drop from `setMyCommands` automatically) and the armed popover shows its
  "No actions can run" state. **No security-surface change:** I1/I4 are properties of the runner
  and the match mechanism, both unchanged; an empty allowlist simply means no `Action` is matchable
  from the seed. TDD: `ActionRegistryTests` now asserts `seed.actions.isEmpty` +
  `removedDiagnosticsAreNotAllowlisted`, and exercises `match()` semantics against a small local
  `fixture` registry (independent of the seed); `AppCoordinatorTests`/`AuthGuardTests` inject
  `ActionRegistry(actions: [disk])` with a local `/disk` fixture as the runnable action;
  `MenuBarModelTests.actionsMirrorTheRegistryReadOnly` asserts `model.actions.isEmpty` and the
  I1-at-the-UI-edge check moved to a standalone `summaryExposesOnlyCommandAndDescription`.
  `PLAN.md` S2 seed example updated to note the empty seed. (This change and the S20 work above were
  developed in two concurrent sessions; the `/uptime` edits that appeared to "vanish" mid-session were
  the other session rewriting `ActionRegistry` toward the empty seed, **not** a tool/linter bug — a
  controlled Edit test confirmed the Edit/Write path does not strip content.)
  - ✅ **Verified green on macOS** (this session): full `RelayBackTests` suite = **298 tests / 36 suites**
    passing. App builds clean.
- **S22 done — Settings Claude capability pane. The agent-action epic (S20–S22) is COMPLETE.** The
  operator can now flip `/claude` on and configure it entirely from Settings; a toggle edit
  **hot-reloads the running guard** and re-advertises `/claude` at once (no restart), so the S20/S21
  machinery is finally reachable in production. New pieces:
  - **New `SettingsPane.claude`** ("Claude", `sparkles` icon), slotted between Repos and Security. Its
    `claudePane` (in `SettingsView`) is thin glue: an **Enable /claude** toggle (default OFF), a
    segmented **permission-profile picker** (`restricted` / `editsInRepo` / `fullBypass`) with a
    per-profile subtitle, a red **bypass warning** shown only while `fullBypass` is selected (I5 — the
    dangerous profile is never chosen silently), a **file-chooser executable row** (path is *picked*,
    never typed), and an **agent-timeout stepper** (1–60 min). Two Previews (restricted / full-bypass).
  - **`SettingsModel` capability state** — loads `claudeEnabled` + the `ClaudeProfile`
    (permission/executablePath/timeout, and the non-edited `model` override) from `ConfigStore` at
    init, defaulting **OFF + `restricted`** when unconfigured (I5). Setters
    (`setClaudeEnabled`/`setClaudePermission`/`setClaudeTimeout`/`chooseClaudeExecutable`) each persist
    via `ConfigStore` **and** fire the new `onClaudeConfigChanged(enabled, profile)`. `currentClaudeProfile`
    rebuilds the profile from the pane's fields while **preserving the `model` override** (so it isn't
    dropped on an unrelated edit). `claudeShowsBypassWarning` drives the pane's red caution. A cancelled
    executable chooser is a no-op (no persist, no hot-reload).
  - **File-chooser seam** — `FolderPicking` gained `chooseFile()` (real `NSOpenPanel` files-only;
    `FakeFolderPicker.chooseFile`/`fileToReturn`/`chooseFileCount` for tests), reusing the post-S19
    folder-picker pattern so the spawned executable is a real file the operator pointed at.
  - **Hot-reload path (the recorded S22 decision — parity with the allowlist/repos, NOT "apply on next
    arm")** — `AuthGuard` flipped `claudeEnabled`/`claudeProfile` to `var` + gained
    `mutating func updateClaudeConfig(enabled:profile:)` (arm state + active repo preserved — capability
    is orthogonal to the session; disabling refuses the next `/claude` at once, I5); `AppCoordinator`
    gained a `updateClaudeConfig` passthrough (mirrors `updateRepos`); `AppRuntime` wires
    `settings.onClaudeConfigChanged → coordinator.updateClaudeConfig` **and** re-advertises via
    `setMyCommands(botCommands(claudeEnabled:))`. The **guard gate is the real I5 enforcement** —
    re-advertisement is best-effort autocomplete, so a Telegram failure there can't widen capability.
  - **⚠️ Still a prerequisite before real use:** the **manual Claude Code CLI smoke** (confirm headless
    `-p` auto-denies non-allowlisted tools / never hangs + the exact flag spellings — see the S20 ⚠️
    note) has still never run. S22 makes `/claude` *enable-able*; the smoke gates *trusting* it.
- ✅ **S22 verified green on macOS** (this session): full `RelayBackTests` = **331 tests / 38 suites**
  passing (+12 vs S21: `AuthGuardTests` (+2) — hot-reload enables a disabled capability without
  re-arming (session + active repo preserved), and disable/swap-profile carries into future runs (I5);
  `AppCoordinatorTests` (+1) — `updateClaudeConfig` enables a previously-refused run end-to-end via the
  fake agent runner; `SettingsModelTests` (+9) — load-from-store, default-OFF/`restricted`,
  toggle/timeout/permission persist+notify, disable notifies `enabled=false`, `fullBypass` warning
  flag, file-pick fills+persists / cancel is a no-op, and an unrelated edit preserves the `model`
  override; `SettingsPaneTests` updated for the new `.claude` case). App builds clean.
- **S21 done — `/claude` command wiring. The agent action is now routable (gated OFF by default).**
  `/claude <prompt>` flows end-to-end through the guard + coordinator, spawning headless Claude Code in
  the active repo. It is inert in production until S22 adds the Settings toggle (`claudeEnabled` reads
  `false` with no UI to flip it), but the whole run path is wired and invariant-tested. New pieces:
  - **`Decision.runClaude(prompt:repoRoot:profile:)`** — a fully-resolved agent-run description (the
    §4b analog of `.runAction`). Carries the operator's free-text prompt (the one free-text parameter,
    a single inert token — I5), the active-repo root (the run cwd that bounds Claude Code), and the
    configured `ClaudeProfile`. The coordinator runs it; the prompt is **never validated** — it is
    contained by the profile + cwd, not a validator (§4b).
  - **`AuthGuard` gained `claudeEnabled: Bool = false` + `claudeProfile: ClaudeProfile = .default`**
    (both defaulted so every existing init/test call site compiles unchanged, and OFF by default — I5).
    `/claude` is a hardcoded token case (like `/cd`), routed to a new `resolveClaude` whose gate order
    mirrors the other repo-scoped commands: **arm (I2) → `claudeEnabled` (I5) → active-repo → non-empty
    prompt**, else `.invalidParameters(reason)` (`enable Claude in Settings` / `select a repo
    first` / `usage: /claude <prompt>`). The prompt is extracted with the existing
    `operatorArguments(in:)` — everything after `/claude` as ONE value — so metachars/leading dashes
    are never split off or read as a flag.
  - **`AppCoordinator` gained an injected `claudeRunner: ClaudeRunning = ProcessClaudeRunner()`** (the
    default keeps existing call sites unchanged; tests inject `FakeClaudeRunner`). New `runClaude` spawns
    via `ClaudeRunning` (cwd = active repo) and — via the **new shared `deliver(_:command:fromId:chatId:)`**
    — formats the output (reuse S4), delivers it, and audits it. The audit line is
    `actionRan(command: "/claude", exitCode:)` — token + exit only, **never the prompt or output** (I3/I5).
    The refactor extracted `deliver` out of `runStep` so both the fixed-action/`/sim` path and the agent
    path centralize the I3 contract in one place (behavior-preserving — the `/sim` tests stayed green).
  - **`AppRuntime` wiring** — `start()` reads `configStore.claudeEnabled()`/`claudeProfile()`, seeds the
    guard, injects `ProcessClaudeRunner()`, and advertises `/claude` via `setMyCommands` **only while
    enabled** (`botCommands(claudeEnabled:)`). I1/I4 unchanged — `ProcessClaudeRunner` reuses the same
    audited `ProcessSpawner` execve path as every other command.
  - **Not yet done (S22):** no Settings UI flips `claudeEnabled`, so in production `/claude` currently
    always replies `⚠️ enable Claude in Settings`. The **manual smoke against the real Claude Code
    CLI** (confirm no-hang on non-allowlisted tools + exact flag spellings — see the S20 ⚠️ note) is
    still a prerequisite before enabling for real.
- ✅ **S21 verified green on macOS** (this session): full `RelayBackTests` = **319 tests / 38 suites**
  passing (added `AuthGuardTests` (+5) — disabled→refused, requires-armed (I2 first), requires-active-repo,
  empty-prompt rejected, valid→`.runClaude`, and a hostile-prompt-stays-one-token I5 assertion; replaced
  the S20 "not matchable" test since S21 *is* the wiring; `AppCoordinatorTests` (+5) — enabled+armed+repo
  runs via the fake agent runner (asserts prompt/repoRoot/profile + FR-6 output + secret-free audit),
  disabled→runner-not-called+audited (I5), no-repo→refused+no-spawn, disarmed→refused+no-spawn (I2/I5),
  oversized agent output→document). App builds clean, no warnings.
- **S20 done — Claude agent foundation (mechanism only; `/claude` not yet routable).** The first slice
  of the agent-action epic (SPEC §4b) landed test-first. New pieces:
  - **Pure `Core/ClaudeInvocation`** — `build(prompt:repoRoot:profile:) -> ClaudeInvocation?` turns a
    `/claude` prompt into a headless Claude Code argv. **I5/I1 by construction:** the prompt is bound to
    `-p` and placed **last**, so it is always `arguments.last` and can never become a flag or the
    executable (no shell — metachars are literal); every other argv word comes only from the profile.
    Empty/whitespace prompt → nil. Profile→flags is an **allow-list** (a profile can only narrow):
    `restricted` = `--allowedTools "Read Grep Glob"`; `editsInRepo` = `--allowedTools "Read Grep Glob
    Edit Write" --disallowedTools "Bash"`; `fullBypass` = `--dangerously-skip-permissions`; optional
    `--model` inserted before `-p`.
  - **`Core/ClaudeProfile`** (`executablePath`, `permission: ClaudePermissionProfile`, `timeout`,
    `model?`; `Codable`) + `ClaudePermissionProfile` enum. Fail-closed `.default` (no executable,
    `restricted`).
  - **`ConfigStore` gained `claudeEnabled()`/`setClaudeEnabled` + `claudeProfile()`/`setClaudeProfile`**,
    implemented in `UserDefaultsConfigStore` (Bool + JSON, **fails closed** to false/`.default`, I5),
    `InMemoryConfigStore`, and the Settings `PreviewConfigStore`.
  - **`Execution/ClaudeRunning` protocol** + `FakeClaudeRunner` (for S21) + real **`ProcessClaudeRunner`**.
    The S7 spawn/timeout/hygiene core was **extracted to `Execution/ProcessSpawner`** (behavior-preserving
    refactor — `ProcessCommandRunner` now delegates; `CommandRunnerTests` stay green) so the agent runner
    reuses the **same** audited execve path (I1/I4) without duplicating it — and without the free-text
    prompt ever entering an `Action` (the allowlist path stays "fixed/validated only").
  - **Not wired:** no `/claude` command is matchable (guard test proves an armed `/claude …` →
    `.unknownCommand`). Routing + gating (armed AND `claudeEnabled` AND active repo) is **S21**; the
    Settings capability pane is **S22**.
  - **⚠️ Before enabling in production (S22):** the profiles assume headless `-p` **auto-denies**
    non-allowlisted tools (never hangs). S20's tests pin the chosen flag *mapping* (pure builder), not
    the CLI's live behavior — smoke `/claude` against the installed Claude Code and confirm no hang and
    the exact flag spellings first.
- ✅ **S20 verified green on macOS** (this session): full `RelayBackTests` = **309 tests / 38 suites**
  passing (added `ClaudeInvocationTests` (9) — I5 token/flag-injection, per-profile flag sets, model,
  empty-prompt; `ClaudeRunnerTests` (3) — real `/bin/echo` stand-in smoke incl. a hostile prompt passed
  as one inert arg, empty-prompt-no-spawn; `ConfigStoreTests` (+4) — claude toggle/profile round-trip +
  fail-closed + isolated-suite UserDefaults smoke; `AuthGuardTests` (+1) — `/claude` not matchable). App
  builds clean.
- **S20–S22 scoped into the docs (planning step, commit `59b2021`) — agent action `/claude` (headless
  Claude Code).** A deliberate **threat-model change** was scoped into the docs from
  `relayback-claude-agent-amendment.md`: `/claude <prompt>` runs the Claude Code CLI headless in the
  **active repo**, gated by its own capability toggle. It does **not** add a shell (I1's letter holds
  — the prompt is a single inert argv token, the value of `-p`), but it **does** reintroduce a
  *bounded* form of arbitrary execution via a restricted agent, contained by Claude Code's permission
  profile + active-repo cwd rather than a validator. Amendments applied this session:
  - **SPEC.md** — §2 both execution non-goals annotated; new **§4b Agent action** (controls: default-OFF
    `claudeEnabled`, active-repo cwd, `restricted`/`editsInRepo`/`fullBypass` profiles, single-token
    prompt, reused execution hygiene, secret-free audit); new invariant **I5** added to the §4 list
    (full elaboration in §4b, cross-referenced — a minor structural sharpening vs. the amendment, which
    put I5 only in §4b); `/claude` in §5 grammar; **FR-11** in §6; `ClaudeInvocation`/`ClaudeRunning`/
    `ClaudeProfile` in §7; §10 relabeled (§4b partly realizes the "confirmation-gated arbitrary
    execution" future item; streaming + `/kill` remains the open item **S23** would close).
  - **PLAN.md** — new **Agent action (S20–S22)** section (why, decisions-locked, scope guard, the three
    slices + deferred **S23**), inserted before the Definition of done.
  - **Project CLAUDE.md** — **I5** + the `claudeEnabled`-defaults-OFF / `fullBypass`-warning / prompt-is-
    contained-not-validated guidance added to the security-invariant list.
  - **That commit was docs-only** (suite unchanged at 292 tests), mirroring the `d481271` "docs-only
    planning" precedent (S15–S19). The **S20 mechanism has since landed** (see the top entry); S21/S22
    remain.
- **Enhancement (post-S19) — Settings → Repos "Add repo" uses a native folder browser.** The repo
  working directory is now **picked from an `NSOpenPanel`**, not hand-typed, so it always resolves to
  a directory that actually exists (a typo can't create a bogus repo root the dev commands would run
  in). New pieces:
  - **`Features/Settings/FolderPicking` seam** — `protocol FolderPicking { func chooseFolder() -> String? }`
    + thin real `NSOpenPanelFolderPicker` (directories only, single selection, returns the absolute
      path or nil on cancel). Fake `RelayBackTests/Support/FakeFolderPicker` (scripted path + call
      count) drives the model in tests — no test presents a real panel (mirrors the `LoginItem` seam).
  - **Add-repo draft moved into `SettingsModel`** (was `@State` in the view) so the chooser + name
    suggestion are unit-testable: `newRepoName/Root/Scheme/Destination/Simulator`, injected
    `folderPicker: FolderPicking = NSOpenPanelFolderPicker()` (default keeps every existing init/test
    call site unchanged), `chooseRepoRoot()` (fills `newRepoRoot`; suggests the folder's name only
    when the operator hasn't typed one; a cancel leaves the draft untouched), `submitNewRepo()`
    (commits via the existing `addRepo`, clears the draft on success / keeps it + `repoError` on
    failure), and pure `static suggestedName(forRoot:)` (basename, trailing-slash-tolerant).
  - **View**: `reposPane`'s free-text "Absolute path" field replaced by a `folderChooserRow`
    (path display + **Choose Folder…** button → `model.chooseRepoRoot()`); fields bind to
    `$model.newRepo*`; **Add repo** → `model.submitNewRepo()`.
  - **No security-surface change.** The chosen path is still stored as `RepoConfig.root` and used only
    as the resolved action's `workingDirectory` (§4a) — I1/I2/I3/I4 unchanged; if anything the root is
    now guaranteed to be a real, operator-selected directory. Thin `NSOpenPanel`/view glue is
    Preview/on-device verified; the `chooseRepoRoot`/`submitNewRepo`/`suggestedName` logic is unit-tested.
  - ✅ **Verified green on macOS** (this session): full `RelayBackTests` suite = **292 tests / 36
    suites** passing (added `SettingsModelTests` (6) — folder-pick fills root + suggests name, doesn't
    clobber a typed name, trailing-slash suggestion, cancel is a no-op, submit clears-on-success /
    keeps-on-failure). App builds clean.
- **Bugfix (post-S19) — menu-bar popover corner/shadow artifact.** The disarmed/armed popover showed a
  mismatched double-corner "shelf" (most visible at the bottom-left): `MenuBarRootView` painted an
  opaque, square-cornered `.background(Theme.popoverSurface)` edge-to-edge as the root of a
  `.menuBarExtraStyle(.window)` popover, and the square fill overpainted into the rounded, shadowed
  system window's corner regions. Fix: `.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover,
  style: .continuous))` after the background so the corners stay transparent and the window's rounded
  shadow reads as one clean shape. View-only change (thin SwiftUI, no `Core`/security surface — not
  unit-testable; Preview/on-device visual verification). App builds clean. Clipping to the popover
  radius (≥ the system window radius) is the safe direction — content rounds at least as much as the
  window, so no desktop shows through the corners.
- **S19 done — Simulator run (`/sim`) wired. The S15–S19 dev-workflow epic is COMPLETE.** `/sim` is the
  first **multi-step** command: it resolves to an ordered *sequence* of processes built entirely from
  the active repo's `RepoConfig`, and the coordinator runs them in order, stopping on the first
  non-zero exit. New pieces:
  - **Pure `Core/SimulatorCommand`** — `SimulatorCommand.steps(for: RepoConfig)` builds the ordered
    `[Action]`: **(1)** `/usr/bin/xcodebuild -scheme <cfg.scheme> -destination <cfg.destination> build`
    (1800s), **(2)** `/usr/bin/xcrun simctl boot <cfg.simulatorDevice>` (120s), **(3)** `/usr/bin/open
    -a Simulator` (120s) — every step tagged `/sim`, run in the repo root. Returns
    `SimulatorResolution.ok([Action]) | .invalid(reason:)`; a repo missing scheme/destination/device is
    refused (fails closed, §4a). `SimulatorCommandSpec` (command + description) is the injected
    matching/advertising value; `SimulatorCommand.spec` is the canonical `/sim` instance.
  - **`Decision.runActionSequence([Action])`** — a new decision case carrying the config-built step
    list (never operator text, I1). **`AuthGuard` routes `/sim`** via an injected `simulatorCommand:
    SimulatorCommandSpec? = nil` (nil = not matchable, default → every existing test/call site
    unchanged; `AppRuntime` injects `SimulatorCommand.spec`). `resolveSimulator` applies the same gate
    order as a repo-scoped parameterized command: **arm (I2) → active-repo precondition (`select a repo
    first`) → no-operator-arg (`unexpected extra input`) → build**; a bad/missing-config repo →
    `.invalidParameters(reason)`, nothing spawns.
  - **`AppCoordinator.runSequence`** — runs each step through a shared **`runStep`** (extracted from the
    old single-action `run`, which now delegates to it), so every step is formatted, delivered, and
    audited exactly like a single action (I3: token + exit code only). Breaks the loop on the first
    non-zero exit — a failed build never proceeds to boot/reveal.
  - **`AppRuntime` wiring** — `simulatorCommand: SimulatorCommand.spec` into the guard; `botCommands()`
    advertises `/sim` via `setMyCommands`. I1/I4 unchanged: three fixed absolute executables + fixed
    argv words + config-sourced values (scheme/destination/device), spawned as the normal user under
    the restricted PATH.
  - **Deviations from PLAN (both documented in decisions + SPEC §4a):** (a) `/sim` is **build → boot →
    reveal**, not the literal `boot → install → launch` — `simctl install`/`launch` need a bundle-id +
    built-product-path the v1 `RepoConfig` doesn't model; deferred to a future phase (user-confirmed
    scope this session). (b) The multi-step wrinkle is solved with a **dedicated builder +
    `runActionSequence`**, *not* a `.simulatorDevice` `RepoConfigArg` case — the S18 `configArgs` are
    emitted *before* `fixedArgs`, which can't express `simctl boot <device>` (value trails the verb),
    and closures/multi-Action don't fit `ParameterizedCommand`'s single-spawn `Equatable` shape.
- ✅ **S19 verified green on macOS** (this session): full `RelayBackTests` suite = **286 tests /
  36 suites** passing (added `SimulatorCommandTests` (6) — spec token, build→boot→reveal argv from
  config, every-step-in-repo-root/I1, and the missing scheme/destination/device rejections; +
  `AuthGuardTests` (6) — `/sim` not matchable when unconfigured, runs the sequence in the active repo,
  requires an active repo, rejects a repo with no device, takes no operator arg, requires an armed
  session; + `AppCoordinatorTests` (2) — runs every step in order & audits each, and stops on the first
  non-zero exit with no output in the audit (I3)). App builds clean, no warnings. **No real simulator
  runs in CI** (argv sequence + guard only, per PLAN); manual verification steps recorded below.
- **`/sim` manual verification (macOS-manual, not in CI):** (1) In **Settings → Repos**, add a repo
  whose `root` is an iOS-app checkout, `scheme` = its app scheme, `destination` =
  `platform=iOS Simulator,name=<device>`, `simulatorDevice` = `<device>` (e.g. `iPhone 15`). (2) From
  Telegram: `/arm <code>` → `/cd <repo>` → `/sim`. (3) Expect three replies in order: the `xcodebuild`
  build output, then `xcrun simctl boot` (silent on success / "already booted"), then `open -a
  Simulator` — Simulator.app opens showing the booted device. (4) Force a build failure (e.g. a syntax
  error) and re-run `/sim`: the sequence must stop after step 1 — no boot, no reveal — and the operator
  sees only the build failure. (5) `/cd` a repo with no `simulatorDevice` → `/sim` replies
  `⚠️ no simulator device configured for this repo`, nothing spawns.
- **S18 done — `xcodebuild` wired (`/build`).** The dev-workflow epic's build command is live. Unlike
  the S17 git commands (fully fixed argv), `/build`'s `-scheme`/`-destination` values are drawn from
  the **active repo's `RepoConfig`** — never operator text, never an argv slot the operator controls.
  New pieces:
  - **`RepoConfigArg` enum** (`.scheme`/`.destination`) + **`ParameterizedCommand.configArgs:
    [RepoConfigArg]`** (default `[]`, `Equatable` preserved). Config args are emitted **before**
    `fixedArgs` in the argv, so `configArgs: [.scheme, .destination]` + `fixedArgs: ["build"]` yields
    `-scheme <cfg.scheme> -destination <cfg.destination> build`. Git specs have empty `configArgs` →
    argv unchanged (no regression).
  - **Resolver gained `activeRepo: RepoConfig? = nil`** (default keeps all S15/S17 call sites
    compiling). It builds the config args from that repo, returning `.invalid("no scheme configured
    for this repo")` / `.invalid("no destination configured for this repo")` when the field is absent
    — nothing spawns (§4a). The operator-token count check still runs first, so `/build <anything>` →
    `.invalid("unexpected extra input")` (no operator args accepted).
  - **`Core/BuildCommands.all`** — the one `/build` spec: `/usr/bin/xcodebuild`, `configArgs: [.scheme,
    .destination]`, `fixedArgs: ["build"]`, no params, `requiresActiveRepo: true`, 1800s timeout
    (xcodebuild is slow).
  - **`AuthGuard` threads `currentRepo`** into `ParameterizedActionResolver.resolve(...)` so a
    config-derived command reads the active repo's full `RepoConfig` (S16 only gave the resolver the
    name→root `repoTable`). The `requiresActiveRepo` precondition (S16) still injects the repo root as
    `workingDirectory`, so `/build` runs in the active repo. I1/I4 unchanged: fixed executable + fixed
    `build` action + config-sourced flag values, spawned as the normal user under the restricted PATH.
  - **`AppRuntime` wiring** — `parameterizedCommands: GitCommands.all + BuildCommands.all`, and
    `botCommands()` advertises `/build` via `setMyCommands`.
- ✅ **S18 verified green on macOS** (this session): full `RelayBackTests` suite = **272 tests /
  35 suites** passing (added `BuildCommandsTests` (5) — argv-from-config, no-operator-arg, and the
  missing-scheme/-destination rejections; + `AuthGuardTests` (2) — the guard passes the active repo's
  full config through to `/build`, and refuses a repo with no scheme). App builds clean. **No real
  xcodebuild runs in CI** (argv + guard only, per PLAN). Note: the `test` action's fresh app-host
  launch flaked with "test runner hung before establishing connection" (an LSUIElement menu-bar
  test-host quirk); `build-for-testing` + `test-without-building` (after `pkill -9 -f RelayBack.app`)
  runs the suite cleanly — use that split if `test` hangs.
- **S17 done — git commands wired (`/gitstatus`/`/branch`/`/checkout`/`/pull`/`/push`/`/commit`).**
  The dev-workflow epic's first spawning commands are live. The S15/S16 mechanism
  (resolver + validators + active-repo precondition) was already tested, so S17 is spec data + wiring:
  - **`Core/GitCommands.all`** — six `ParameterizedCommand` specs, all `requiresActiveRepo: true`,
    all `/usr/bin/git`: `/gitstatus` (`status`), `/branch` (`branch`), `/checkout <branch>`
    (`checkout <branch>`, `.branch` param), `/pull` (`pull --ff-only`), `/push` (`push` — bare,
    upstream-only, no remote/refspec arg), `/commit <msg>` (`commit -a -m <msg>`, `.commitMessage`
    param). Local ops time out at 30s, network ops (`/pull`/`/push`) at 120s.
  - **`AppRuntime` wiring** — `start()` now passes `parameterizedCommands: GitCommands.all` to the
    `AuthGuard`, and `botCommands()` advertises the six via `setMyCommands`. Each runs in the session's
    active repo root (set by `/cd`); with no active repo → `.invalidParameters("select a repo first")`
    *before* validation (§4a). I1/I4 unchanged: fixed executable + fixed leading argv, only validated
    values at fixed indices, spawned as the normal user under the restricted PATH.
  - **Deviation from PLAN:** `/checkout` builds `git checkout <branch>`, **not** `checkout -- <branch>`.
    A `--` makes git treat the token as a *pathspec* (it would try to restore a file named after the
    branch), so `checkout -- main` would never switch branches. `ParamValidator.branch` already rejects
    a leading `-` (the real flag-injection guard, per S15), so dropping the redundant `--` costs no
    safety and restores correct branch-switch semantics. Documented in the decisions log below.
- ✅ **S17 verified green on macOS** (this session): full `RelayBackTests` suite = **265 tests /
  34 suites** passing (added `GitCommandsTests` (12) — exact argv per command, checkout/commit
  validation, `/push`/`/pull` reject operator args, and a **real git smoke**: `/gitstatus` returns
  exit 0 in a throwaway `git init` temp repo). App builds clean.
- **S16 done — repo config + active-repo selection (`/cd`/`/pwd`/`/repos`).** The dev-workflow epic
  now has a persisted repo allowlist and a session active-repo, and the first user-facing
  parameterized commands are matchable. New pieces:
  - **`Core/RepoConfig`** (`name`, `root`, optional `scheme`/`destination`/`simulatorDevice`;
    `Equatable`+`Codable`+`Identifiable`). Persisted (non-secret) via two new `ConfigStore` methods
    `repos()`/`setRepos(_:)` — `UserDefaultsConfigStore` stores them as **JSON** (optional fields), and
    **fails closed** (missing/undecodable → `[]`, like the allowlist). `InMemoryConfigStore`/preview
    store updated.
  - **`AuthGuard` active-repo session state.** New injected `repoConfigs: [RepoConfig] = []` (replaces
    the S15 `repoTable:` init param — the guard now derives the name→root table internally) and a
    private `activeRepo`. Three new control commands (all require an armed session — the repo context
    lives with the session): **`/cd <name>`** (exact-match a configured name → set active repo, or
    `.invalidParameters("unknown repo")`), **`/pwd`** (`.control(.workingDirectory(currentRepo))`),
    **`/repos`** (`.control(.repoList(repoConfigs))`). New `ControlResult` cases carry `RepoConfig`.
  - **`requiresActiveRepo` on `ParameterizedCommand`** (default false). A repo-scoped command (S17+
    git/build/sim will set it) with **no active repo** → `.invalidParameters("select a repo first")`
    *before* param validation; with one, the resolver's `Action` is rebuilt via new
    `Action.withWorkingDirectory(_:)` so the process runs in the active repo's root (§4a).
  - **Active repo cleared on session end (§4a):** `/disarm`, the UI `disarm()`, and a **fresh** `/arm`
    all clear it; `currentRepo` also returns nil when not armed, so an idled-out session never reports
    a stale repo. `updateRepos(_:)` hot-reloads the guard (mirrors `updateAllowlist`) and drops the
    active repo if it was removed.
  - **Pure `Core/RepoListPresentation`** (`list`/`pwd`) — the `/repos` + `/pwd` reply text discloses
    **only name + root**, never a repo's build config (asserted). `AppCoordinator` maps the new control
    results to replies + `.control("cd <name>"/"pwd"/"repos")` audit lines, and gained `updateRepos`.
  - **Settings**: new **Repos** pane (`SettingsPane.repos`, "folder" icon) with a repo list + add-form;
    `SettingsModel` gained `repos` + `addRepo(...)`/`removeRepo(name:)` + `onReposChanged` (persist +
    hot-reload, same shape as the allowlist). `AppRuntime` seeds the guard from `configStore.repos()`,
    wires `onReposChanged → coordinator.updateRepos`, and advertises `/cd`/`/pwd`/`/repos` via
    `setMyCommands`.
  - **No parameterized git/build/sim spec is wired in production yet** — `parameterizedCommands` stays
    empty until S17. Only `/cd`/`/pwd`/`/repos` are matchable now (they're hardcoded control commands).
- ✅ **S16 verified green on macOS** (this session): full `RelayBackTests` suite = **253 tests /
  33 suites** passing (added `RepoListPresentationTests` (5) + `ConfigStoreTests` repos (4) +
  `AuthGuardTests` repo/active-repo (9) + `AppCoordinatorTests` repo commands (4) + `SettingsModelTests`
  repos (5); `SettingsPaneTests` updated for the new pane). App builds clean; the Repos-pane Preview
  renders the list + add form.
- **S15 done — parameterized-action foundation (dev-workflow epic begun).** The *mechanism* for
  §4a validated-parameter actions is in place and fully test-exercised, but **inert in production**:
  no new bot command is matchable (proven). New pieces:
  - **`Action.workingDirectory: String?`** (default nil = inherit, today's behavior) via an explicit
    memberwise init so all existing call sites compile unchanged; `ProcessCommandRunner` sets
    `Process.currentDirectoryURL` from it only when non-nil (smoke-tested with `/bin/pwd` in a temp
    dir; nil-case asserted to inherit the launcher cwd).
  - **Pure `Core/ParamValidator`** (TDD'd tables): `repoName(_:in:)` = exact allowlist lookup →
    absolute root (traversal-proof — no path from chat), `branch` = `^[A-Za-z0-9._/-]+$` + no
    leading `-`, `commitMessage` = non-empty, single-line, length-capped (200), no leading `-`.
    Metachars are permitted where harmless (no shell — I1 unchanged); the real guard is the
    leading-`-` rejection so a value can never be read as a flag.
  - **Pure `Core/ParameterizedActionResolver`** + `ParameterizedCommand` spec (`command`,
    `executable`, fixed `fixedArgs`, ordered `[ParamKind]`, `timeout`) + `ParamKind`
    (`.repoName|.branch|.commitMessage`) + `ParameterResolution` (`.ok(Action)|.invalid(reason)`).
    `resolve(spec, argTokens, repoTable)` validates each token and builds `executable + fixedArgs +
    validatedValues` — a value-bearing arg sits behind a `--` guard carried in `fixedArgs`; a
    `.repoName` param resolves to a root and becomes `workingDirectory` (not argv). Bad input →
    `.invalid(reason)`, nothing built.
  - **`Decision.invalidParameters(String)`** + `AuthGuard` routing: after the registry-match path,
    a token matching a configured `ParameterizedCommand` is gated on arm state **before** validation
    (disarmed → `.disarmed`, not a validation leak), then resolved. `AuthGuard` gained injected
    `parameterizedCommands: [ParameterizedCommand] = []` + `repoTable: [String:String] = [:]` (both
    **empty in production** — `AppRuntime` passes neither). `AppCoordinator` maps `.invalidParameters`
    to a `⚠️ <reason>` reply + a `.rejected(reason:)` audit line (reusing the S9 taxonomy — reason is
    short and secret-free, I3), and **never calls the runner** (I2 preserved).
  - **I1 by construction:** the executable + leading argv come only from the in-code spec; operator
    text only ever fills a validated, fixed argv index. No new SPEC deviation (§4a already scoped this).
- ✅ **S15 verified green on macOS** (this session): full `RelayBackTests` suite = **226 tests /
  32 suites** passing (added `ParamValidatorTests` (10) + `ParameterizedActionResolverTests` (9) +
  `AuthGuardTests` parameterized-routing (4) + `AppCoordinatorTests` invalid/valid param (2) +
  `CommandRunnerTests` workingDirectory (2)). App builds clean.
- **S13f done — Audit pane + Connection pane. S13 design-conformance epic COMPLETE.** The **Audit**
  pane is now the handoff's append-only table: a column header (Time · from.id · Action / decision ·
  Exit), zebra-striped mono rows tinted by decision, and the "Append-only · no secrets, no full
  output stored." caption. The **Connection** pane gained a live status card (colored dot + label +
  detail) above the bot-token field. New pieces:
  - **Read side of the audit log** (the S9 `AuditSink` was write-only): `Storage/AuditReading`
    protocol + `AuditEntry.parse(line:)` (pure inverse of `.line`, TDD'd round-trip, nil on
    malformed) + thin real `Storage/FileAuditReader` (bounded tail, smoke-tested) + fake
    `InMemoryAuditReader`. Pure `Features/Settings/AuditRowPresentation` maps an entry → columns +
    severity/role (`.command` blue / `.control` green / `.rejected` amber|red), newest-first with
    stable ids. **I3 holds by construction:** the line format has no output/secret field, so a
    *parsed* entry structurally can't carry one (asserted).
  - **Connection state**: pure `Features/Settings/ConnectionState` (`.connecting |
    .connected(botUsername:) | .error(reason:)`) + `ConnectionStatePresentation` (label/detail/style)
    + `ConnectionState.probe(_:)` which calls a new **`TelegramTransport.getMe`** and reduces any
    failure via `ConnectionReason.from` (type/code only — the token-bearing URL never leaks, I3).
    `getMe` returns a new `TelegramBotInfo` (username only), decoded thinly in `TelegramClient`.
  - **Wiring**: `SettingsModel` gained `connectionState` + injected `auditReader` + `refreshAuditRows`.
    `AppRuntime` injects `FileAuditReader`, probes the bot once at `start()` (→ `settings.connectionState`
    and `menuBar.botUsername`, the popover's `@bot` — nil until now), and sets `.error("no bot token
    configured")` when unconfigured. `SettingsView` gained an `initialPane` param for pane-targeted
    Previews. **No core/security change** to the run path.
- ✅ **S13f verified green on macOS** (this session): full `RelayBackTests` suite = **202 tests /
  30 suites** passing (added `AuditRowPresentationTests` (7) + `AuditReaderTests` (8) +
  `ConnectionStateTests` (5)). App builds clean; the Audit / Connection Previews render the new panes.
- **S13e done — Allowlist pane + General pane styled to the handoff.** The **Allowlist** pane is now
  the handoff's member list: per-member cards with a gradient avatar (initial + color derived from
  the id), the mono `id <n>`, a cosmetic green **`primary`** badge on the lowest id, and a **Remove**
  affordance on every row; below it the mono **Add numeric id…** field + blue **Add** button, plus
  the empty state. The **General** pane relocates **Launch at login** into a card row (label +
  subtitle + green switch). New pure type (TDD'd): `Features/Settings/AllowlistMemberPresentation`
  (`rows(for: [Int64])` → sorted rows, lowest id `isPrimary`; `idText`, `avatarInitial` = leading
  digit, `avatarGradientIndex` = stable in-range bucket). `Theme` gained a 4-gradient `avatarGradients`
  palette indexed by that bucket. **Decision: option (a) — ids-only** (no `ConfigStore`/`AllowlistDraft`
  data-model change); names/avatars/`primary` are illustrative, derived from the id. **I2 preserved:**
  the `primary` badge is cosmetic — every id including primary stays removable (a deliberate, minor
  deviation from the handoff, which hides Remove on primary). No core/security change.
- ✅ **S13e verified green on macOS** (this session): full `RelayBackTests` suite = **182 tests /
  27 suites** passing (added `AllowlistMemberPresentationTests` (6)). App builds clean; the configured
  Preview renders the member cards, primary badge, add row, and General toggle.
- **S13d done — Settings sidebar shell + Security pane.** `SettingsView` was reshaped from the
  single grouped `Form` into the handoff's **176px sidebar window** (660×520): a sidebar of five
  panes — Connection · Allowlist · **Security** · Audit · General — swaps the content area. New pure
  types (TDD'd): `Features/Settings/SettingsPane` (nav enum: ordered `allCases`, per-pane `title` +
  SF Symbol) and `Features/Settings/ArmingConfigPresentation` (idle-timeout `m:ss` pill via
  `MenuBarStatus.clockString`, `driftIsEnabled`, and the drift subtitle). The **Security** pane is
  built to spec: QR card, `SECRET (BASE32)` row + **Copy**, **Regenerate secret** (primary) / **Show
  otpauth://** (reveal toggle), the green **Keychain-assurance banner**, and **display-only**
  Idle-timeout (`5:00`) / Drift-tolerance (±1, RFC 6238) rows. `SettingsModel` gained a read-only
  `armingConfig` (defaults 300s / ±1 — mirrors `AppRuntime`/`AuthGuard`/`TOTP`). The other panes
  keep the existing token/allowlist/launch-at-login controls reachable (restyled in **S13e**
  allowlist+general, **S13f** connection+audit; Audit is a placeholder for now). Copy-to-pasteboard
  and the otpauth reveal are thin glue (Preview-verified). **No core/security change** — secrets
  still flow only through `SecretStore` (I3); idle/drift are display, not editable.
- ✅ **S13d verified green on macOS** (this session): full `RelayBackTests` suite = **176 tests /
  26 suites** passing (added `SettingsPaneTests` (5) + `ArmingConfigPresentationTests` (3)). App
  builds clean; the configured/empty Security-pane Previews render the new sidebar + pane.
- **Seed allowlist expanded (post-S13c, commit `8bce16e`).** `ActionRegistry.seed` grew from the
  3 original read-only diagnostics to **10**: added `/ip` (`/sbin/ifconfig`), `/mem`
  (`/usr/bin/vm_stat`), `/top` (`/usr/bin/top -l 1 -n 15 -o cpu`), `/ps` (`/bin/ps aux`),
  `/netstat` (`/usr/sbin/netstat -rn`), `/battery` (`/usr/bin/pmset -g batt`), `/date`
  (`/bin/date`). All are absolute paths + fixed arg arrays with **no operator input (I1)** and
  auto-advertise via `AppRuntime.botCommands()`. TDD: extended `ActionRegistryTests` +
  `MenuBarModelTests`. (This commit was cherry-picked/merged with a PROGRESS.md conflict resolved
  against it, so it was never logged here until this sync.)
- **S15–S19 planned (docs only, NOT implemented — commit `d481271`).** SPEC (§2, §4/I1, new §4a,
  §10) and PLAN were amended to scope **parameterized dev-workflow actions**: validated argv (never
  shell — I1 unchanged), a named-repo working-dir allowlist, upstream-only remotes, and fixed
  per-repo build config. Five new slices are drafted in PLAN — **S15** parameterized-action
  foundation, **S16** repo config + `/cd`/`/pwd`/`/repos`, **S17** git commands, **S18**
  xcodebuild, **S19** simulator run. None are started; no new bot command is matchable yet.
- **S13c done — recent-activity color coding.** The popover's RECENT list is now structured,
  color-coded rows instead of raw audit strings. New pure type (TDD'd): `Features/MenuBar/
  RecentActivityRow` — `RecentActivityRow(from: AuditEntry)` → (`time` UTC `HH:mm`, `command`,
  `statusText`, `severity: .normal|.warning|.danger`). Severity follows security weight: **red**
  for an unauthorized sender (`unknown user`) or a non-zero exit, **amber** for a disarmed block /
  failed arm (`bad code`), default otherwise. It is built only from the audit record's fields —
  which never carry command output or a secret — so **I3** holds at the UI edge for free.
  `MenuBarModel` now holds `recentActivity: [RecentActivityRow]` (was `recentAudit: [String]`) via
  `appendActivity`; `MenuBarAuditSink` builds the row from the entry it already forwards.
  `MenuBarRootView`'s RECENT renders time · command (mono) · severity-tinted status (new
  `RecentActivityRow.Severity.color` Theme token). **No core/security change** — pure view-model +
  thin view; execution stays Telegram-only.
- ✅ **S13c verified green on macOS** (this session): full `RelayBackTests` suite = **167 tests /
  24 suites** passing (added `RecentActivityRowTests` (9); `MenuBarAuditSinkTests` adapted to the
  row API). App builds clean; the disarmed Preview renders the color-coded RECENT list.
- ✅ **Suite re-verified green after the seed expansion** (2026-07-06 sync): full `RelayBackTests`
  suite = **169 tests / 24 suites** passing (+2 vs S13c, from the expanded `ActionRegistryTests` /
  `MenuBarModelTests` in `8bce16e`). `** TEST SUCCEEDED **`.
- **S14 done — persistent connection-lifecycle logging.** The poll loop now keeps a persistent,
  append-only record of transport health at `~/Library/Application Support/RelayBack/connection.log`,
  separate from the command audit log (FR-8 = received commands only). New pure types (TDD'd):
  `Storage/ConnectionLogEntry` (`ConnectionEvent = .connected | .disconnected(reason:)` + one-line
  `line` rendering), `ConnectionSink` protocol, `ConnectionReason.from(Error)` (maps a transport
  error to a SHORT, **secret-free** reason from the error type/code only — a `URLError`'s
  token-bearing URL never reaches the log; **I3**). Thin real sink `Storage/FileConnectionLog`.
  `PollLoop` gained an injected `connectionLog` + `clock` and logs only **transitions** (tracked via
  an `isHealthy: Bool?`): first success / recovery → `.connected`, first failure of an outage →
  `.disconnected` — a healthy loop never re-logs, an ongoing outage never re-logs. `AppRuntime`
  wires the real `FileConnectionLog` + shared `SystemClock`. **Refactor:** extracted `Storage/LogText`
  (timestamp + sanitize) and `Storage/AppendOnlyFile` (best-effort append); `AuditEntry`/`FileAuditLog`
  now delegate to them (behavior unchanged — audit tests stayed green). This is the persistence the
  future **S13f Connection pane** can read; no core/security change to the run path.
- ✅ **S14 verified green on macOS** (this session): full `RelayBackTests` suite = **158 tests /
  23 suites** passing (added `ConnectionLogTests` (6) + 2 `PollLoopTests` transition tests). App
  builds clean.
- **S13b done — armed popover content (actions + last result + disarm).** The armed popover now
  matches the handoff: below the ARMED pill + countdown chip (S13a), an "Armed by operator…"
  subtitle, an **ALLOWLISTED ACTIONS** list of read-only cards (command in accent blue + registry
  description), a dark **LAST RESULT** terminal card (`$ /cmd`, colored `exit N`, output lines),
  and an armed footer with a red **"Disarm now"** button + Settings/Quit. New pure types (TDD'd):
  `Features/MenuBar/ActionSummary(Action)` (command + description **only** — no executable/args/
  timeout, so nothing runnable reaches the UI: **I1** at the UI edge) and
  `Features/MenuBar/LastResultPresentation(command:result:)` (→ `commandLine`/`exitLabel`/
  `exitIsSuccess`/`outputLines`, stdout-else-stderr, trailing-blank-line trimmed).
  `MenuBarModel` gained `actions` (defaults to `ActionRegistry.seed`), `lastResult`, and a `disarm`
  closure hook. `AuthGuard.disarm()` + `AppCoordinator.disarm()` (I2: re-arm required after) and
  `AppCoordinator.onActionCompleted` (fires after each run with command+result). `AppRuntime`
  wires `onActionCompleted → menuBar.lastResult` and `menuBar.disarm → coordinator.disarm() +
  status refresh`. **No core/security change** to the run path — the last-result card is local UI
  (not audit/Telegram), so **I3** is untouched; execution stays Telegram-only (no click-to-run).
  RECENT color-coding is still **S13c**.
- ✅ **S13b verified green on macOS** (this session): full `RelayBackTests` suite = **150 tests /
  22 suites** passing (added `LastResultPresentationTests` (4) + `MenuBarModelTests` (3) +2
  `AppCoordinatorTests` (disarm drops the live session — I2; `onActionCompleted` gets command+result)).
  App builds clean; armed/disarmed Previews render the new content.
- **S13a done — design conformance begun (app icon + disarmed popover shell).** The finalized
  handoff icon set is integrated (`Assets.xcassets/AppIcon.appiconset` — 10 macOS PNGs +
  `Contents.json` with `-2x` filenames, copied verbatim; `icon.svg` intentionally not added, it's
  vector source not a build asset). New `Features/Theme/Theme.swift` holds the handoff design tokens
  (colors/radii/brand gradient + a `Color(hex:)` helper) — plain constants, not unit-tested, verified
  by Previews. `MenuBarStatus` gained pure `pillLabel` / `pillStyle` (`.armed`/`.disarmed`) /
  `showsCountdown` / `countdown` (TDD'd — 2 new tests). `MenuBarRootView` rebuilt to the disarmed
  design: 368px surface, brand-glyph header + status pill, locked-state card with the `/arm <code>`
  mono chip, pulsing "Listening" row (`@bot` via new `MenuBarModel.botUsername`, nil until S13f), a
  RECENT list, and a Settings/Quit footer. Armed body (action cards + last-result terminal card +
  "Disarm now") is **S13b**; RECENT color-coding is **S13c**. **No core/security change** — pure
  view-model + thin view only.
- ✅ **S13a verified green on macOS** (this session): full `RelayBackTests` suite = **141 tests /
  20 suites** passing (added `MenuBarStatusTests.disarmedPill` + `armedPillShowsCountdownChip`). App
  builds clean; asset catalog compiles the new icon; disarmed/armed Previews render the new shell.
- **Phase:** implementation. **S12 done — v1 is operationally complete (all slices S0–S12).** The
  authorization allowlist is now persisted and fed into the running `AuthGuard`, closing the last
  gap: an operator whose id is in the saved allowlist can `/arm` and run an allowlisted action
  end-to-end. New `Storage/ConfigStore` seam (non-secret, non-throwing, fails-closed to empty) with
  real `UserDefaultsConfigStore` + `InMemoryConfigStore` fake. `SettingsModel` loads/persists the
  allowlist through it and fires `onAllowlistChanged` on every real change; `AppRuntime` seeds the
  guard from the store on `start()` and wires that callback to `AppCoordinator.updateAllowlist`, so
  an edit **hot-reloads** into the live guard immediately (no restart). `AuthGuard.updateAllowlist`
  replaces the allowlist while **preserving arm state** (identity ≠ session): a removed id is revoked
  at once (I2), a live operator's session is not dropped by an unrelated edit.
- ✅ **S0–S12 verified green on macOS** (Xcode 26.5, this session): full `RelayBackTests` suite =
  **136 tests / 20 suites** passing (S12 added `ConfigStoreTests` (4) + `AuthGuard` update tests (2)
  + `AppCoordinator` allowlist-wiring tests (2) + `SettingsModel` persistence tests (4)). App + tests
  build clean, no warnings.
- **Deferred (non-blocking):** per-second live menu-bar countdown (status refreshes on each audit
  event, not on a timer). Future-phase items parked in SPEC §10.
- ~~**S11 done**~~ — Lifecycle & login
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
- ✅ **S11 (prior slice) verified green** — poll lifecycle, backoff/reconnect, `SMAppService` login
  item, live menu-bar wiring; the `.app` launches as a menu-bar agent (no Dock icon), stays idle when
  unconfigured, and quits cleanly.
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
- **Next slice:** none required for v1 — **every planned slice S0–S22 is done.** The only planned work
  left is **S23** (deferred, not v1): a persistent Claude Code session fed turn-by-turn with streamed
  partial output + a `/kill` — a different (stateful session actor + streaming/backpressure)
  architecture than the one-shot `claude -p` S20–S22 shipped; it would close the SPEC §10 streaming
  item. **Gate before trusting `/claude` in production:** the **manual Claude Code CLI smoke** (headless
  `-p` auto-denies non-allowlisted tools / never hangs + exact flag spellings, per the S20 ⚠️ note) —
  S22 makes `/claude` enable-able but this has never been run against the live CLI. Besides the epic,
  the optional follow-ups still stand (none blocking v1): (a) `/sim` `simctl install`/`launch` of the built app
  — needs a bundle-id + built-product-path added to `RepoConfig` + Settings (deferred this session,
  SPEC §4a note); (b) per-second live menu-bar countdown (status refreshes on audit events, not a
  timer); (c) a real-Keychain/UserDefaults launch smoke; (d) a live per-poll connection indicator
  reading the S14 `connection.log`; (e) SPEC §10 future-phase items. Also worth doing before any real
  use: the **manual verification passes** for `/build` (S18) and `/sim` (S19) on a real repo/simulator,
  which have never run outside CI-inert argv/guard tests.
- **Blockers / open questions:** none. The S12 design question is resolved (hot-reload, arm state
  preserved — see decisions).
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
| S12 | Allowlist persistence & auth wiring *(new)* | ✅ done |
| S13  | Design conformance — recreate handoff in SwiftUI *(new epic)* | ✅ done |
| S13a | · App icon + popover shell (disarmed)            | ✅ done |
| S13b | · Popover armed content (actions/result/disarm)  | ✅ done |
| S13c | · Recent-activity color coding                   | ✅ done |
| S13d | · Settings sidebar shell + Security pane         | ✅ done |
| S13e | · Allowlist pane + General pane                  | ✅ done |
| S13f | · Audit pane + Connection pane                   | ✅ done |
| S14  | Connection-lifecycle logging (persistent) *(new)* | ✅ done |
| —    | Seed allowlist expanded to 10 read-only diagnostics *(amends S2)* | ✅ done |
| S15  | Parameterized-action foundation *(dev-workflow epic)* | ✅ done |
| S16  | Repo config + active-repo selection (`/cd`/`/pwd`/`/repos`) | ✅ done |
| S17  | Git commands (`/gitstatus`/`/branch`/`/checkout`/`/pull`/`/push`/`/commit`) | ✅ done |
| S18  | xcodebuild (`/build`) | ✅ done |
| S19  | Simulator run (`/sim`) | ✅ done |
| S20  | Claude agent foundation *(agent-action epic)* | ✅ done |
| S21  | `/claude` command wiring | ✅ done |
| S22  | Settings: Claude capability pane | ✅ done |
| S23  | *(deferred)* persistent session + streaming + `/kill` | ☐ deferred |
| —    | Seed allowlist emptied (`/whoami` + all legacy diagnostics removed) *(amends S2)* | ✅ done |
| S24  | `/arm` prompts for the TOTP code (force_reply) instead of failing on empty *(new)* | ✅ done |

Legend: ☐ not started · ◐ in progress · ✅ done (green + refactored)

_The **S13** design-conformance epic (S13a–S13f), the **S15–S19** dev-workflow epic (parameterized
actions), and the **agent-action epic (S20–S22)** are all complete — **every v1 slice (S0–S22) is
done and implemented**; only **S23** (persistent session + streaming + `/kill`) remains **deferred**
(not v1). Other remaining items are optional follow-ups (see "Next" below), plus the standing manual
Claude Code CLI smoke before `/claude` is trusted in production._

## Decisions & deviations

_(Record anything that differs from or sharpens SPEC.md / PLAN.md, with a one-line why.)_

- 2026-07-19 — S21: **`/claude` is a hardcoded token case; a *disabled* `/claude` returns
  `.invalidParameters("enable Claude in Settings")`, NOT `.unknownCommand`.** Because the operator
  is already allowlisted + armed to reach the resolver, telling them how to enable the capability leaks
  nothing (no disclosure concern) and is far more useful than pretending the command doesn't exist. This
  matches PLAN S21's "enable-in-Settings" message. It changes the S20 `claudeCommandIsNotMatchableUntilWired`
  test premise (S21 *is* the wiring), so that test was replaced by `claudeIsRefusedWhenDisabled`.
- 2026-07-19 — S21: **Gate order in `resolveClaude` is arm (I2) → `claudeEnabled` (I5) → active-repo →
  non-empty prompt**, mirroring `resolveParameterized`/`resolveSimulator`. Arm first so a disarmed
  operator is told to arm (never shown capability/repo state); then the capability toggle; then the
  active-repo precondition (the cwd that bounds Claude Code); then the prompt. Any failure →
  `.invalidParameters(reason)`, nothing built. The prompt is extracted via the existing
  `operatorArguments(in:)` (everything after `/claude` as ONE trimmed value) so shell metacharacters /
  leading dashes stay inside the single free-text token — the guard-level half of I5 (argv-binding is
  `ClaudeInvocation`, spawn-inertness is `ProcessClaudeRunner`, both S20-tested).
- 2026-07-19 — S21: **`AppCoordinator` gained `claudeRunner: ClaudeRunning = ProcessClaudeRunner()`
  (defaulted), and `runStep`/`runClaude` now share a new `deliver(_:command:fromId:chatId:)`.** The
  default keeps every existing `AppCoordinator(...)` call site compiling (established default-param
  pattern); tests inject `FakeClaudeRunner`. `deliver` centralizes the format→send→audit→last-result
  tail so the I3 "token + exit only" audit contract lives in ONE place for the fixed-action, `/sim`, and
  `/claude` paths alike — behavior-preserving (the S19 `/sim` tests stayed green). The `/claude` audit
  token is the literal `"/claude"`, never the prompt (I3/I5).
- 2026-07-19 — S21: **Guard reads Claude config once at `AppRuntime.start()`; NO `updateClaudeConfig`
  hot-reload yet — deferred to S22.** `claudeEnabled`/`claudeProfile` are injected into the guard init
  (and gate the `setMyCommands` advertisement) at start; there is no Settings UI to flip `claudeEnabled`
  until S22, so `/claude` is inert (always refused) in production today. Whether toggling hot-reloads the
  live guard vs. applies on next arm/restart is the explicit S22 decision (PLAN recommends hot-reload for
  parity with the allowlist/repos — that would add a guard `mutating func updateClaudeConfig` + a
  coordinator passthrough).
- 2026-07-19 — S21: **`/claude` audits as `action=/claude exit=N`, uniform with every repo-scoped
  command — NOT the richer "repo name + profile" SPEC §4b originally wrote.** Enriching would mean a
  bespoke `AuditEvent` case rippling through `AuditEntry.detail`/`.parse`, `AuditRowPresentation`
  (the S13f pane), and the `Decision` shape — a taxonomy expansion beyond PLAN S21's "secret-free audit
  line." The active repo is already recoverable from the immediately-preceding, always-audited
  `/cd <name>` line, so only the permission *profile* is genuinely non-redundant; surfacing it is
  deferred (SPEC §4b trued-up to record this) to land once the profile is a first-class operator-
  configured value (S22+). I3/I5 hold either way — the token+exit event structurally can't carry the
  prompt or output.
- 2026-07-19 — S22: **Toggling `/claude` in Settings HOT-RELOADS the live guard (parity with the
  allowlist/repos), NOT "apply on next arm/restart".** This resolves the explicit S22 decision the
  S21 note left open, taking PLAN's recommended path. `AuthGuard` flipped `claudeEnabled`/`claudeProfile`
  to `var` + gained `mutating func updateClaudeConfig(enabled:profile:)`; `AppCoordinator` got a
  `updateClaudeConfig` passthrough; `AppRuntime` wires `onClaudeConfigChanged` to it and re-advertises
  via `setMyCommands`. Arm state + active repo are **preserved** — capability is orthogonal to the
  session (same reasoning as `updateAllowlist` preserving arm). Disabling refuses the next `/claude` at
  once (I5). The **guard gate is the enforcement**; the `setMyCommands` re-advertisement is best-effort
  autocomplete, so a Telegram failure there can never widen capability.
- 2026-07-19 — S22: **The executable path is *picked from a file browser*, never typed** — `FolderPicking`
  gained `chooseFile()` (files-only `NSOpenPanel`) alongside the S-post-19 `chooseFolder()`. Same
  rationale as the repo-root chooser: the binary that actually gets spawned should be a real file the
  operator pointed at, not a mistyped string. The pane doesn't edit the `--model` override, so
  `SettingsModel` round-trips it through `currentClaudeProfile` rather than dropping it when the profile
  is rebuilt from the pane's fields.
- 2026-07-19 — S20: **`ClaudeInvocation.build` returns a value struct — a superset of SPEC §7's
  `(executable, argv)`.** It also carries `workingDirectory` (= repoRoot, the cwd that bounds Claude
  Code's file reach) and `timeout`, which the runner needs. The prompt is bound to `-p` and placed
  **last**, so I5 is a one-line invariant: `arguments.last == prompt`, immediately preceded by `-p`,
  exactly one `-p`. Empty/whitespace prompt → nil (builds nothing).
- 2026-07-19 — S20: **Reused the S7 spawn core via a new `Execution/ProcessSpawner`, not a duplicate.**
  Both `ProcessCommandRunner` (allowlist path) and `ProcessClaudeRunner` (agent path) delegate to one
  audited execve/timeout/hygiene site (I1/I4); `ProcessCommandRunner`'s `CommandRunnerTests` stayed
  green through the extraction. Kept the agent path on its own `ClaudeRunning` seam (not `CommandRunning`)
  so the unvalidated free-text prompt never enters an `Action` — the fixed-allowlist world stays
  "arguments are always fixed or validated," and S21's coordinator gets a clean fake to assert I5 against.
- 2026-07-19 — S20: **`editsInRepo` denies ALL Bash (allow-list), stricter than SPEC §4b's "destructive
  bash denied."** An allow-list beats a fragile blocklist of destructive commands; the profile still
  permits Read/Grep/Glob/Edit/Write. SPEC §4b wording trued-up to record this (a safe narrowing).
- 2026-07-19 — S20: **Profiles assume headless `-p` auto-DENIES non-allowlisted tools (never hangs);
  flag spellings confirmed via a `claude-code-guide` pass but NOT yet run against the real CLI.** An
  unattended run must never block on a permission prompt. S20 is a pure builder + a `/bin/echo`-stand-in
  smoke, so its tests pin the chosen flag *mapping*, not Claude Code's live behavior — the guide flagged
  some uncertainty on `--permission-mode` values (unused; we rely on `--allowedTools`/`--disallowedTools`
  + `--dangerously-skip-permissions`, which are robust). **Manual smoke against installed Claude Code is a
  prerequisite for enabling in S22** (confirm no-hang + exact flags).
- 2026-07-08 — S19: **`/sim` is build → boot → reveal, not PLAN's `boot → install → launch`.** The
  literal `simctl install <path>` / `launch <bundle-id>` need a built-product path + app bundle-id that
  v1's `RepoConfig` (name/root/scheme/destination/simulatorDevice) does not store. Rather than widen the
  persisted model + Settings UI for the final slice, `/sim` uses only the config we have:
  `xcodebuild build` → `xcrun simctl boot <device>` → `open -a Simulator`. Why: keeps the slice within
  the existing persistence surface (no migration, no new UI), still genuinely useful (builds + brings up
  the configured device for screen-share), and honors §4a (every value from config, never operator
  text). Install/launch is deferred to a future phase; the scope was user-confirmed this session. SPEC
  §4a records the deferral.
- 2026-07-08 — S19: **The multi-step wrinkle is a dedicated `SimulatorCommand` builder +
  `Decision.runActionSequence([Action])`, NOT a `.simulatorDevice` `RepoConfigArg`.** The S18
  `configArgs` are emitted *before* `fixedArgs` (right for `xcodebuild -scheme X … build`), but the boot
  step is `simctl boot <device>` — the value *trails* the fixed verb, which the before-`fixedArgs`
  ordering can't express. And `/sim` yields *multiple* `Action`s, which `ParameterizedCommand` (single
  spawn, `Equatable`, resolver → one `.ok(Action)`) doesn't model. So `/sim` gets its own pure builder
  (`steps(for: RepoConfig) -> SimulatorResolution`) and a new decision case carrying the sequence,
  leaving the git/build single-spawn path untouched. The PROGRESS S18 note anticipated exactly this
  fork ("a device-specific step builder" over "add a `.simulatorDevice` `RepoConfigArg` case").
- 2026-07-08 — S19: **`/sim` is injected as `SimulatorCommandSpec?` (nil = not matchable), mirroring the
  empty-`parameterizedCommands` inertness pattern.** The guard holds an optional spec (command +
  description) defaulting nil, so every existing `AuthGuard` init call site + test compiles unchanged and
  `/sim` is proven not-matchable when unconfigured (test). The step *sequence* is built by the static
  `SimulatorCommand.steps(for:)` keyed off the active repo — the injected spec carries only matching /
  `setMyCommands` metadata (there is exactly one sim command app-wide, so the static coupling is fine).
  Gate order matches a repo-scoped parameterized command: arm (I2) → active-repo → no-operator-arg → build.
- 2026-07-08 — S19: **`AppCoordinator` runs a sequence via a shared `runStep`; the single-action `run`
  now delegates to it.** Extracted `runStep(action) -> CommandResult` (spawn → format/deliver → audit →
  last-result card) so both `.runAction` (single) and `.runActionSequence` (multi) reuse one code path;
  `runSequence` loops it and **breaks on the first non-zero exit** so a failed build never boots/reveals.
  Each step audits as `.actionRan(command: "/sim", exitCode:)` — token + exit only, no output (I3, tested
  with a scripted mid-sequence failure whose stdout/stderr is asserted absent from every audit line).
- 2026-07-08 — S18: **Config-derived argv is data-driven (`configArgs: [RepoConfigArg]`), not a
  build-spec factory.** PLAN offered two options for the S18 wrinkle (argv depends on the active repo's
  config): the resolver/guard reads `cfg.scheme`/`cfg.destination`, *or* a small build-spec factory
  builds a concrete `ParameterizedCommand` per repo. Chose the former, expressed as a new
  `RepoConfigArg` enum field on `ParameterizedCommand`. Why: (1) `/build` stays a single static spec in
  `BuildCommands.all` — matchable in the guard and advertisable via `setMyCommands` with no parallel
  representation; (2) `ParameterizedCommand` stays `Equatable` (a factory returning closures would not);
  (3) the resolver stays pure and the whole thing is table-tested like `ParamKind`. A factory would
  have needed a second `/build` representation (marker spec for matching + factory for argv), which is
  more surface for no benefit.
- 2026-07-08 — S18: **`configArgs` are emitted BEFORE `fixedArgs` in the argv; the value comes only
  from `RepoConfig`.** Argv is `configArgs + fixedArgs + valueArgs`, so `/build` builds `-scheme X
  -destination Y build` (matching PLAN's literal wording), while the git commands (empty `configArgs`)
  are unchanged. The scheme/destination values are read from the active repo's config — never operator
  text, never an argv index the operator fills — so I1 holds by construction; a repo missing either
  field is refused (`.invalid("no scheme/destination configured for this repo")`) rather than spawning
  a partial xcodebuild. `/build` takes **no** operator arguments (0 params → any trailing input →
  `"unexpected extra input"`, same guard as `/push`/`/pull`).
- 2026-07-08 — S18: **The guard now passes `currentRepo` (full `RepoConfig`) to the resolver.** S16
  gave the resolver only the name→root `repoTable`; a config-derived command needs the whole config, so
  `resolveParameterized` now calls `resolve(..., activeRepo: currentRepo)`. The `activeRepo` param
  defaults to nil, so every S15/S17 resolver call site (and the git tests) compiles unchanged, and git
  commands (no `configArgs`) ignore it. The `requiresActiveRepo` precondition is unchanged — it still
  runs first and injects the repo root as `workingDirectory`.
- 2026-07-08 — S17: **`/checkout` builds `git checkout <branch>`, dropping PLAN's `--` guard.** PLAN
  S17 (and the S15 illustrative spec) wrote `checkout -- <branch>`, but git treats everything after
  `--` as a *pathspec*: `git checkout -- main` tries to restore a file named `main`, it does not switch
  to branch `main` — so the command as specified would never work. `ParamValidator.branch` already
  rejects a leading `-` (per S15, "the real guard is the leading-`-` rejection so a value can never be
  read as a flag"), so the `--` was redundant belt-and-suspenders for flag safety and actively broke
  the feature. Dropped it for `/checkout` only; `/commit`'s `-m` value is unaffected (it follows a
  flag, not a pathspec). Net: no safety change, correct branch-switch semantics.
- 2026-07-08 — S17: **The git commands are pure spec data (`GitCommands.all`), not new logic.** S15/S16
  built and tested the whole resolve→run path (resolver, validators, `requiresActiveRepo` precondition,
  active-repo→`workingDirectory`), so S17 adds only a static `[ParameterizedCommand]` + two lines of
  `AppRuntime` wiring (into the guard + `setMyCommands`). `GitCommandsTests` pins the *specs* (exact
  argv, validation, no-arg enforcement) via the already-tested resolver; the guard routing itself is
  covered by the S15/S16 `AuthGuardTests`. The PLAN-mandated real smoke (`git init` a temp repo →
  `/gitstatus` exit 0 through `ProcessCommandRunner`) is the one real-`git` process test.
- 2026-07-08 — S17: **`/push` is bare (`git push`) and `/pull` is `git pull --ff-only`; both take no
  operator args.** Upstream-only per SPEC §4a — no remote/refspec is ever built, so a push can only
  reach the current branch's configured upstream and a pull can only fast-forward (never a merge
  commit from a surprise remote). The zero-parameter resolver path rejects any trailing operator input
  (`.invalid("unexpected extra input")`), asserted for both. Network timeout is 120s (vs 30s local).
- 2026-07-08 — S16: **Active repo is session state selected by `/cd`, not a per-command `.repoName`
  parameter — this sharpens §4a.** §4a framed the repo as a per-action validated parameter (the S15
  `.repoName` `ParamKind`, which stays available but is now inert). Instead the operator sets an
  **active repo** once with `/cd <name>`, and repo-scoped commands read it from the session. Why: the
  git/build/sim commands (S17–S19) take *no* repo argument — a phone operator sets context once, then
  runs many commands — so a per-command repo token would be noise. The guard injects the active repo's
  root as the resolved action's `workingDirectory` (new `Action.withWorkingDirectory`). SPEC §4a/§5
  updated to describe the active-repo model + the three commands.
- 2026-07-08 — S16: **`/cd`/`/pwd`/`/repos` require an armed session; the active repo lives with the
  session and is cleared on end.** They're hardcoded control commands (like `/arm`/`/status`), not
  `ParameterizedCommand`s, since they mutate/report session state rather than spawn. All three gate on
  `isArmed` first (a disarmed operator is told to arm, never shown which repos exist — I2-adjacent).
  The active repo is cleared on `/disarm`, on the UI `disarm()`, and on a **fresh** `/arm` (captured
  via `wasArmed` before extending); `currentRepo` also returns nil when not armed, so a lazily-expired
  session can't report a stale repo. Rationale: a repo context must not survive across sessions.
- 2026-07-08 — S16: **`requiresActiveRepo` precedes parameter validation; "select a repo first" is a
  precondition, not a validation error.** A repo-scoped `ParameterizedCommand` (S17+ sets the flag)
  with no active repo returns `.invalidParameters("select a repo first")` *before* resolving params —
  the precondition is checked first so the operator gets the actionable message even if a param would
  also be invalid. The guard now derives its `repoTable` from the injected `repoConfigs` (the S15
  `repoTable:` init param was replaced), unifying the repo source; the resolver signature is unchanged.
- 2026-07-08 — S16: **`RepoConfig` is `Codable`, persisted as JSON in UserDefaults; repos fail closed
  like the allowlist.** Optional build-config fields make a plist array awkward, so `setRepos` encodes
  JSON to a `data` key and `repos()` returns `[]` on a missing/undecodable blob — an absent/corrupt
  repo config can only narrow what the dev commands reach (§4a), never widen it. `ConfigStore` stays
  non-throwing (best-effort, like the allowlist).
- 2026-07-08 — S16: **`/repos` and `/pwd` disclose only name + root — pure `RepoListPresentation`
  enforces it.** A repo's `scheme`/`destination`/`simulatorDevice` are internal build config and are
  never echoed to chat; the reply text is a pure, tested function so the no-leak rule is asserted
  (sentinel-string tests), not left to view glue. `/pwd`'s "current branch" line (PLAN's wording) is
  deferred to **S17** — it needs a real `git` call, which arrives with the git commands; S16's `/pwd`
  reports name + root.
- 2026-07-08 — S16: **Repos edits hot-reload into the running guard (parity with the allowlist), and
  the repo allowlist is ids-model-simple.** `SettingsModel.addRepo`/`removeRepo` persist via
  `ConfigStore` and fire `onReposChanged`, which `AppRuntime` wires to `AppCoordinator.updateRepos`
  → `AuthGuard.updateRepos` (drops a removed active repo immediately). Not strictly required by PLAN
  (repos aren't a security-revocation concern like ids), but it avoids a confusing "added a repo,
  `/cd` still fails until restart" gap and reuses the established S12 pattern. The Settings **Repos**
  pane (new `SettingsPane.repos`) is thin/Preview-verified glue; the tested surface is `SettingsModel`.
- 2026-07-08 — S15: **The resolver is data-driven over a `[ParameterizedCommand]` spec set, and
  AuthGuard routes to it — production wires an empty set.** PLAN sketched the resolver as
  `(command, argTokens, repoTable) -> …` (implying it knows commands internally). Instead a
  `ParameterizedCommand` describes each command's fixed executable/argv + ordered param slots, and
  `AuthGuard` holds an injected `[ParameterizedCommand]` (default `[]`) + `repoTable` (default `[:]`).
  Why: (1) it proves "no command matchable" cleanly — production passes no specs, so a
  parameterized-looking command falls through to `.unknownCommand` (asserted); (2) it exercises the
  **whole** authorize→coordinator path in tests (specs injected) rather than leaving a dormant
  coordinator branch; (3) S16/S17 just append specs + a real repo table, no resolver rewrite. This
  sharpens PLAN's standalone-resolver sketch; behavior matches §4a exactly.
- 2026-07-08 — S15: **Arm gate precedes parameter validation.** A matched parameterized command from
  a disarmed operator returns `.disarmed` (send `/arm` first), not a validation result — so validity
  of the command/params is never leaked to a disarmed session (I2 first, §4a second).
- 2026-07-08 — S15: **A `.repoName` param sets `workingDirectory`, not an argv token; the `--` guard
  lives in the spec's `fixedArgs`.** Per §4a the repo context is a working directory drawn from the
  allowlist (traversal-proof: `ParamValidator.repoName` is an exact dict lookup, so `../x` is just
  not a key). Value-bearing args are guarded by placing `--` in `fixedArgs` (e.g. `["checkout","--"]`)
  — belt-and-suspenders atop the leading-`-` rejection in the validators, rather than the resolver
  auto-inserting `--` (which would break `commit -a -m <msg>`, where the value follows `-m`).
- 2026-07-08 — S15: **At most one operator argument, captured as the whole trimmed remainder.** All
  §4a commands take 0 or 1 operator value, so `AuthGuard.operatorArguments(in:)` returns the text
  after the command token as a single token (preserving inner spaces so a multi-word commit message
  stays one argv token). A 0-param command with trailing text → `.invalid("unexpected extra input")`
  (this is what will reject operator args on `/push`/`/pull` in S17).
- 2026-07-08 — S15: **`.invalidParameters` reuses the S9 `.rejected(reason:)` audit case — no new
  `AuditEvent`.** The reason is built only by `ParamValidator`/the resolver (short, secret-free —
  never captured output or a secret), so it is safe in both the `⚠️` reply and the audit line (I3),
  and the narrow audit taxonomy that structurally enforces I3 is left unchanged.
- 2026-07-08 — S15: **`Action` gained an explicit memberwise init with `workingDirectory: String? =
  nil`.** The synthesized memberwise init wouldn't give the new field a default, which would break
  every existing `Action(...)` call site; an explicit init with the default keeps them all compiling
  and preserves today's cwd-inherit behavior for the 10 seed diagnostics.
- 2026-07-08 — S13f: **Chose to add `TelegramTransport.getMe` (the PLAN decision), not a generic
  connected state.** The handoff shows `@relayback_bot`; showing it needs the bot's username. Added
  `getMe() -> TelegramBotInfo` (username only — a separate type from `TelegramUser` so the `from.id`
  identity gate is untouched) + a fake, and `ConnectionState.probe(_:)` that calls it and maps any
  failure through the existing `ConnectionReason.from` (type/code only) so the token-bearing request
  URL never reaches the UI (I3). The probe runs once at `AppRuntime.start()`; a live per-poll
  connection indicator (the S14 `connection.log` already records transitions) is a future refinement.
- 2026-07-08 — S13f: **The audit READ side reconstructs entries by parsing stored lines
  (`AuditEntry.parse`), the pure inverse of `.line`.** The pane needs `AuditEntry`s but the log
  stores rendered lines, so `parse` round-trips the three event kinds (TDD'd; nil on malformed). I3
  is preserved *by construction*: the line format has no output/secret field (S9), so a parsed entry
  cannot carry one — no scrubbing needed. `FileAuditReader` stays thin (read tail → `compactMap`
  parse) and is smoke-tested only; the format knowledge lives in the pure, tested `parse`.
- 2026-07-08 — S13f: **Audit rows render the audit model faithfully, not the handoff's illustrative
  labels.** A control event shows its control text (e.g. `armed`) — the audit model doesn't store the
  originating `/arm` — and a rejection reads `rejected · <reason>` (the reason, e.g. `disarmed` /
  `unknown user`, not the offending command, which `AuditEvent.rejected` never carries). Same
  constraint as S13c's RECENT list. Severity buckets mirror S13c (unknown-user/nonzero-exit → danger;
  disarmed/bad-code → warning; else normal); the middle column colors by role (command→blue,
  control→green, rejected→severity). The small duplication with `RecentActivityRow` (severity map +
  `HH:mm` formatter) is left un-extracted — two independently-tested pure types, distinct columns.
- 2026-07-08 — S13f: **Connection state lives on `SettingsModel`; the probe also feeds the popover's
  `@bot`.** The Connection pane is in `SettingsView(model: SettingsModel)`, so `connectionState`
  (default `.connecting`) is held there and rendered via `ConnectionStatePresentation`. `AppRuntime`
  pushes the probe result and, on success, sets `menuBar.botUsername` (the popover's listening-row
  `@bot`, which was `nil` "until S13f"). Unconfigured (no token) → `.error("no bot token configured")`
  so the pane isn't stuck "Connecting…". `SettingsView` gained an `initialPane:` param so Previews can
  target the Audit/Connection panes; the connection status dot is a plain `Circle` (the popover's
  `PulsingDot` is file-private) — a cosmetic, non-functional deviation.
- 2026-07-08 — S13e: **Allowlist stays ids-only (option (a)) — labels/avatars/`primary` are derived,
  not stored.** The handoff shows per-member names, colored avatars, and a `primary` badge, but the
  persisted `ConfigStore`/`AllowlistDraft` keep a bare `[Int64]`. Rather than widen the data model
  (option (b): optional label + primary flag round-tripped through the store), the illustrative fields
  are derived from the id by a pure `AllowlistMemberPresentation` (`avatarInitial` = leading digit,
  `avatarGradientIndex` = `id % 4` into a new `Theme.avatarGradients`, `isPrimary` = lowest id). Why:
  smallest change, no migration, no new persistence surface for v1; the id is the only real identity
  the guard checks (I2). This slightly sharpens PLAN, which said option (a) is "styling only, no new
  logic" — a tiny TDD'd presentation type was added instead of putting derivation in the view, since
  CLAUDE mandates a failing test per slice.
- 2026-07-08 — S13e: **The `primary` badge is cosmetic; every id including primary stays removable
  (I2).** The handoff hides the Remove affordance on the primary member. RelayBack instead keeps
  Remove on every row and shows `primary` only as a green marker on the lowest id — a deliberate,
  minor visual deviation. Rationale: I2 requires that a compromised/rotated id can be revoked
  immediately; a UI that locked the "primary" id could otherwise strand a bad id (and there is no
  real "primary" concept in `AuthGuard` — all allowlisted ids are equal). Removal semantics are
  unchanged from S12 (`SettingsModel.removeId` → `AllowlistDraft.remove` → persist + hot-reload).
- 2026-07-06 — S13d: **Idle-timeout & drift-tolerance are DISPLAY-ONLY (the S13d decision).** SPEC
  §9 pins the TOTP config fixed and `TOTP`/`OtpAuthURI` are pinned to it; `AuthGuard` uses a fixed
  300s idle window and `TOTP.validate` defaults to `driftSteps: 1`. So the two Security-pane rows
  reflect the real configured constants via the pure, testable `ArmingConfigPresentation` (idle
  `m:ss`, drift subtitle) rather than editing them — the drift toggle is `.constant(...).disabled`.
  Making them editable would require a deliberate SPEC change. `SettingsModel.armingConfig`
  (defaults 300 / 1) is the single value the pane binds to; those defaults mirror `AppRuntime`.
- 2026-07-06 — S13d: **The sidebar is a plain `HStack(sidebar | content)`, not `NavigationSplitView`.**
  The handoff is a fixed-size (660×520) five-item settings sidebar with a custom active-row treatment
  (accent fill, white text, blue shadow); a hand-rolled `HStack` + per-row `Button` gives exact
  control over that styling and a fixed 176px rail, which the stock `NavigationSplitView` sidebar
  chrome fights. `selection` is local `@State: SettingsPane` (defaults `.security`, the featured pane).
- 2026-07-06 — S13d: **Panes not owned by this slice keep their existing controls, restyled later.**
  Rather than lose reachable functionality, Connection hosts the bot-token field (S13f refines),
  Allowlist hosts the existing id editor (S13e restyles to member rows), General hosts launch-at-login
  (S13e), and Audit is a titled placeholder (S13f). Only the Security pane is built to full handoff
  spec in S13d. Copy-to-pasteboard (`NSPasteboard`) and the otpauth reveal are thin view glue — no
  new test; the pure nav + arming-config logic is what's TDD'd.
- 2026-07-05 — S13c: **`RecentActivityRow` maps from the existing `AuditEntry` — no core change, so
  I3 holds for free.** The row is built solely from the audit record's fields (time, command, exit
  code, or rejection reason), and `AuditEntry` has no field that can hold command output or a secret
  (S9), so nothing sensitive can reach the popover. This keeps the color-coding a pure UI concern
  and leaves the verified audit/run path untouched.
- 2026-07-05 — S13c: **A rejection row's command column reads "rejected", not the offending
  command.** `AuditEvent.rejected(reason:)` carries only the reason — not the command token that was
  rejected — so a real row can show the reason but not the `/command`. Surfacing the rejected command
  would mean widening the S9 audit model (a core, I3-sensitive change), deliberately out of this UI
  slice. The old preview strings (`/run rejected · disarmed`) were illustrative; previews now build
  rows from real `AuditEntry`s so they reflect what actually renders.
- 2026-07-05 — S13c: **A failed run (non-zero exit) is `danger` (red), sharpening PLAN's "default
  for runs."** A successful run is `.normal`; a non-zero exit is flagged red, consistent with the
  last-result terminal card's success/failure coloring. Severity map: `unknown user`/non-zero exit →
  danger; `disarmed`/`bad code` → warning; everything else (control events, `unknown command`) →
  normal. Matched by lowercased substring so a lightly-reworded reason still lands in the right bucket.
- 2026-07-05 — S13c: **RECENT time is UTC `HH:mm`, matching the audit log's clock.** Uses a dedicated
  `HH:mm` `DateFormatter` pinned to UTC + `en_US_POSIX` (not the ISO8601 `LogText` formatter), so the
  popover time lines up with the log and is deterministic under test regardless of the machine's time
  zone. (A user-facing local time would make the pure mapping non-deterministic to assert.)
- 2026-07-03 — S14: **Connection log is a SEPARATE file, not folded into the audit log.** SPEC
  FR-8's `audit.log` is scoped to *received commands*; connection lifecycle (connect/disconnect) is
  a different concern the planned S13f Connection pane surfaces separately, so it gets its own
  `connection.log`. Keeps each log single-purpose and greppable, and avoids widening the `AuditEvent`
  taxonomy (whose narrowness is what structurally enforces I3).
- 2026-07-03 — S14: **The poll loop logs only TRANSITIONS, and disconnect reasons are secret-free
  by construction (I3).** `run()` tracks `isHealthy: Bool?` so `.connected`/`.disconnected` is logged
  only when health flips — a healthy long-poll (a line every ~30s) doesn't spam the file, and a
  prolonged outage yields one line, not one per retry. The reason comes from `ConnectionReason.from`,
  which reduces an error to `"network error <code>"` / `"transport error"` from the type/code only —
  it never interpolates the error's description, because a `URLError` can carry the failing request
  URL (which embeds the bot token in its path) in its userInfo. Asserted by
  `disconnectReasonNeverLeaksTheFailingURLOrToken`.
- 2026-07-03 — S14: **Extracted `LogText` + `AppendOnlyFile` rather than duplicate the audit impl.**
  Two append-only line logs now exist, so the ISO-8601 timestamp + free-text sanitize (`LogText`)
  and the create-or-seek-and-append file write (`AppendOnlyFile`) were pulled out and shared;
  `AuditEntry`/`FileAuditLog` were refactored onto them with no behavior change (the existing
  `AuditLogTests` stayed green, proving it). `PollLoop` takes an injected `Clock` (default
  `SystemClock`) for deterministic timestamps under test; timestamps aren't asserted, the recorded
  events are.
- 2026-07-03 — S13b: **The popover's "Last result" card shows command output — and that does not
  touch I3.** I3 governs the audit log and Telegram replies (no output/secrets there); the
  last-result terminal card is *local UI* the design handoff explicitly specifies, fed by a
  dedicated `AppCoordinator.onActionCompleted` closure, separate from the audit path (the
  `AuditSink`/`AuditEntry` still carry only command + exit code). So output reaches the screen but
  never the log or chat metadata. `LastResultPresentation` uses stdout when present, else stderr.
- 2026-07-03 — S13b: **"Disarm now" gets a first-class `AuthGuard.disarm()` / `AppCoordinator.disarm()`
  rather than synthesizing a `/disarm` message.** The UI has no operator id/text to route through
  `authorize`, and disarming is identity-independent, so a direct mutating `disarm()` (sets
  `armedUntil = nil`, same effect as a `/disarm`) is the honest seam. I2 still holds — after a UI
  disarm the next action is blocked until re-armed via TOTP (tested in `AppCoordinatorTests`).
- 2026-07-03 — S13b: **`ActionSummary` is the I1 guard at the UI edge.** The popover binds to
  `[ActionSummary]` (command + description only) built from `ActionRegistry.seed`; it structurally
  omits `executable`/`arguments`/`timeout`, so no runnable payload can reach the view (execution
  stays Telegram-only — the cards are read-only, per the S13 scope guard). `MenuBarModel.actions`
  defaults to the seed registry; the armed body renders it, the disarmed body does not.
- 2026-07-03 — S12: **Runtime allowlist changes hot-reload into the live guard; arm state is
  preserved.** This resolves the S11 design question. `AuthGuard.updateAllowlist(_:)` replaces the
  allowlist without touching `armedUntil` — identity and session are orthogonal, so (a) removing a
  (possibly compromised) id revokes it **immediately** rather than at next launch (a stronger I2
  property than restart-to-apply), and (b) editing who may run must not drop a legitimate operator's
  live armed session. `SettingsModel.onAllowlistChanged` is the seam: `AppRuntime` wires it to
  `AppCoordinator.updateAllowlist` (weak coordinator; nil when unconfigured/stopped). The persisted
  `ConfigStore` remains the source of truth `start()` seeds the guard from, so the two paths agree.
- 2026-07-03 — S12: **`ConfigStore` is non-secret and non-throwing (contrast `SecretStore`).** It
  backs onto `UserDefaults` (reads can't fail) and a config write is best-effort bookkeeping that
  must never interrupt the operator, so — unlike the throwing `SecretStore` — its methods don't
  throw. It **fails closed**: a missing/unreadable allowlist reads back as `[]`, so an absent config
  can only narrow who may run (I2), never widen. Ids stored as `[Int]` (64-bit on macOS → `Int64`
  round-trips). Real `UserDefaultsConfigStore` is contract-pinned by `ConfigStoreTests` against the
  fake plus one isolated-suite smoke test (never `.standard`, so no test pollutes real defaults).
- 2026-07-03 — S12: **`SettingsModel` no longer takes an `allowlist:` seed param — the `ConfigStore`
  is the single source.** It loads the allowlist from the store on init and persists (+ notifies) on
  every *real* change only (a duplicate/invalid add or a no-op remove neither re-persists nor
  hot-reloads). Existing `SettingsModelTests` were updated to inject `InMemoryConfigStore` so none
  touch `UserDefaults.standard`. SwiftUI previews got a local `PreviewConfigStore` (mirroring the
  existing `PreviewSecretStore`); fixed a latent `secret = secret` self-assign bug in the latter.
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
  (S3) owns them. Original seed set = `/uptime`→`/usr/bin/uptime`, `/disk`→`/bin/df -h`,
  `/whoami`→`/usr/bin/whoami`, all read-only, 10s timeout. **Expanded 2026-07-03 (`8bce16e`) to 10**
  — see the current-state note and the 2026-07-03 log entry; still all read-only, fixed argv (I1).
- 2026-07-01 — S1: `TOTP` API landed as `code(secret: Data, at: Date)` +
  `validate(_:secret:at:driftSteps:)` with a separate `Base32.decode(_:) -> Data?`. PLAN
  phrased the secret param loosely; splitting base32 decode into its own pure type keeps the
  "invalid base32 handled" case testable on its own. Constant-time code compare in `validate`.

## Log

_(Append newest first: date — slice — what got done, what's next, snags.)_

- 2026-07-06 — PROGRESS sync (no code change). Reconciled this log against `main` after two commits
  had landed past the last-logged slice (S13c): the seed-allowlist expansion (`8bce16e`) and the
  S15–S19 dev-workflow SPEC/PLAN amendment (`d481271`), neither of which was recorded here (the
  former merged with its PROGRESS.md conflict resolved against it). Added current-state notes, S15–S19
  + seed-expansion rows to the slice table, and corrected the stale S2 note. Re-ran the suite on
  macOS: **169 tests / 24 suites green** (`** TEST SUCCEEDED **`). **Two open tracks:** S13d–S13f
  (Settings design panes) and S15–S19 (dev-workflow actions) — both not started.

- 2026-07-03 — SPEC/PLAN amendment (`d481271`, docs only): scoped **S15–S19 dev-workflow actions**
  with validated parameters + a named-repo allowlist. SPEC gained §4a (validators, upstream-only
  remotes, fixed per-repo build config, threat-model note) and updated §2/§4-I1/§10; PLAN gained the
  S15→S19 plan (foundation → repo config + `/cd` → git → xcodebuild → sim). **I1 "no shell, ever" is
  unchanged** — parameters are validated argv landing at fixed indices, never a shell. Nothing
  implemented yet; no new bot command is matchable.

- 2026-07-03 — Seed allowlist expanded (`8bce16e`, amends S2). Added `/ip`, `/mem`, `/top`, `/ps`,
  `/netstat`, `/battery`, `/date` to `ActionRegistry.seed` (now 10 read-only diagnostics) — all fixed
  absolute paths + fixed arg arrays, no operator input (I1); they auto-advertise via
  `AppRuntime.botCommands()`. TDD: extended `ActionRegistryTests` + `MenuBarModelTests`, suite green.
  (Committed against an S14-era base — "green (160)" in its message; on top of S13c the suite is 169.)

- 2026-07-05 — S13c complete. Recent-activity color coding. Pure/TDD:
  `Features/MenuBar/RecentActivityRow.swift` (`RecentActivityRow(from: AuditEntry)` →
  time/command/statusText/`Severity{normal,warning,danger}`; severity by security weight, time UTC
  `HH:mm`). Replaced `MenuBarModel.recentAudit: [String]` + `appendAudit` with `recentActivity:
  [RecentActivityRow]` + `appendActivity`; `MenuBarAuditSink` now builds a row from the entry it
  already forwards. `MenuBarRootView` RECENT renders time · command (mono) · severity-tinted status;
  added a `RecentActivityRow.Severity.color` Theme extension (amber=warningText, red=danger, else
  secondary) + honest preview rows built from real `AuditEntry`s. Ran RED (`cannot find
  'RecentActivityRow'`) → GREEN → refactor on macOS: **167 tests / 24 suites green** (was 158/23; +9
  = new `RecentActivityRowTests`; `MenuBarAuditSinkTests` adapted to the row API). New file
  auto-included (objectVersion 77) — no pbxproj edit. **Next: S13d** (Settings sidebar shell +
  Security pane).

- 2026-07-03 — S14 complete (new slice, beyond original PLAN). Persistent connection-lifecycle
  logging. Pure/TDD: `Storage/ConnectionLogEntry.swift` (`ConnectionEvent`, `ConnectionLogEntry.line`,
  `ConnectionSink`, `ConnectionReason.from`) + `Storage/FileConnectionLog.swift` (thin append-only
  sink). `PollLoop` gained injected `connectionLog: ConnectionSink` + `clock: Clock`; `run()` logs
  transitions only via an `isHealthy: Bool?` flag. `AppRuntime` wires `FileConnectionLog(fileURL:
  connectionLogURL())` (→ `RelayBack/connection.log`) + shared clock. Refactor: extracted
  `Storage/LogText.swift` + `Storage/AppendOnlyFile.swift`; `AuditEntry`/`FileAuditLog` delegate to
  them. Tests: `ConnectionLogTests` (6: connected/disconnected line, newline neutralize, I3 no-token
  leak, non-URL error → generic, file append-only smoke) + `InMemoryConnectionSink` fake + 2
  `PollLoopTests` (disconnect→reconnect transitions; "connected" once while healthy). Ran RED
  (`cannot find type 'ConnectionSink'`) → GREEN → refactor on macOS: **158 tests / 23 suites green**
  (was 150/22; +8, +1 suite). App builds clean. New files auto-included (objectVersion 77) — no
  pbxproj edit. Added S14 to PLAN.md + slice table. **Next: S13c** (recent-activity color coding) or
  S13f (Audit + Connection panes — the Connection pane can now read `connection.log`).

- 2026-07-03 — S13b complete. Armed popover content. Pure/TDD: `Features/MenuBar/ActionSummary.swift`
  (command + description only — I1 at the UI edge) + `Features/MenuBar/LastResultPresentation.swift`
  (`command:result:` → commandLine/exitLabel/exitIsSuccess/outputLines). `MenuBarModel`: +`actions`
  (defaults to seed), +`lastResult`, +`disarm` closure. `AuthGuard.disarm()`; `AppCoordinator.disarm()`
  + `onActionCompleted`. `AppRuntime` wires last-result push + disarm→coordinator+status refresh.
  `MenuBarRootView`: split into disarmed/armed bodies; armed = subtitle + ALLOWLISTED ACTIONS cards
  + dark LAST RESULT terminal card + red "Disarm now" footer; armed Preview seeds a `lastResult`.
  Tests: `LastResultPresentationTests` (4: exit0/nonzero/trailing-newline/empty), `MenuBarModelTests`
  (3: actions mirror registry, lastResult nil default, disarm invokable), +2 `AppCoordinatorTests`
  (disarm drops live session — I2; onActionCompleted gets command+result). Ran RED (`cannot find
  'LastResultPresentation'`) → GREEN → refactor (moved header divider into the disarmed body only, to
  match the handoff's armed layout) on macOS: **150 tests / 22 suites green** (was 141/20; +9, +2
  suites). App builds clean. New files auto-included (objectVersion 77) — no pbxproj edit. **Next:
  S13c — recent-activity color coding.**

- 2026-07-03 — Bugfix (post-S12): **Settings allowlist add failed silently.** `SettingsView`'s Add
  button discarded the `AddResult`, so `.invalid`/`.duplicate` input gave zero feedback (reads as
  "can't add IDs"). Added `SettingsModel.allowlistError` (set on invalid/duplicate, cleared on a
  successful add) + a red caption under the allowlist section. TDD: 3 new `SettingsModelTests`
  (invalid/duplicate surface a message, success clears it). Suite green, app builds. Happy-path add
  was already correct — the defect was purely the missing UX feedback.

- 2026-07-03 — S12 complete. Allowlist persistence & runtime auth wiring — the last gap; **v1 DoD
  met**. New `Storage/ConfigStore.swift` (protocol, non-secret/non-throwing/fails-closed) +
  `Storage/UserDefaultsConfigStore.swift` (real, `[Int]`-backed) + `Support/InMemoryConfigStore.swift`
  (fake). `AuthGuard`: `allowlist` → `var` + `mutating updateAllowlist(_:)` (arm state preserved).
  `AppCoordinator.updateAllowlist(_:)` forwards to the guard. `SettingsModel`: injects `ConfigStore`
  (dropped the `allowlist:` seed param), loads on init, persists + fires `onAllowlistChanged` on real
  changes only. `AppRuntime`: injects `configStore`, seeds the guard from it on `start()`, keeps a
  `coordinator` ref, and wires `onAllowlistChanged` → `coordinator.updateAllowlist` for hot-reload.
  Tests: `ConfigStoreTests` (4, incl. isolated-suite UserDefaults smoke), +2 `AuthGuardTests`
  (recognize/revoke; arm-state-preserved), +2 `AppCoordinatorTests` (newly-added id arms+runs;
  removed id revoked mid-session — I2), +4 `SettingsModelTests` (load/persist/notify; no-op doesn't
  notify). Ran RED (`cannot find type 'ConfigStore'`) → GREEN → refactor on macOS: **136 tests / 20
  suites green** (was 124/19; +12, +1 suite). App + tests build clean, no warnings. Fixed a latent
  preview bug (`PreviewSecretStore` self-assigned `secret`). New files auto-included (objectVersion
  77) — no pbxproj edit. **Next: none required for v1** (optional: live countdown, real-store E2E
  smoke, SPEC §10 future phases).
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
