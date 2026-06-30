# RelayBack — Progress Log

> Source of truth for "where are we." Written to survive context clears. Update this at the
> end of every slice (see `CLAUDE.md` → "Ending a slice"). Newest note at the top of the log.

## Current state

- **Phase:** pre-implementation. Design docs written (`SPEC.md`, `PLAN.md`, `CLAUDE.md`).
- **Next slice:** **S0 — Project bootstrap** (see `PLAN.md`).
- **Blockers / open questions:** none. (Future-phase items parked in SPEC §10.)

## Slice status

| Slice | Title | Status |
|-------|-------|--------|
| S0  | Project bootstrap            | ☐ not started |
| S1  | TOTP core                    | ☐ not started |
| S2  | Action allowlist & registry  | ☐ not started |
| S3  | AuthGuard state machine      | ☐ not started |
| S4  | Output formatter             | ☐ not started |
| S5  | Keychain store               | ☐ not started |
| S6  | Telegram transport           | ☐ not started |
| S7  | Command runner               | ☐ not started |
| S8  | AppCoordinator               | ☐ not started |
| S9  | Audit log                    | ☐ not started |
| S10 | Menu bar + Settings UI       | ☐ not started |
| S11 | Lifecycle & login item       | ☐ not started |

Legend: ☐ not started · ◐ in progress · ✅ done (green + refactored)

## Decisions & deviations

_(Record anything that differs from or sharpens SPEC.md / PLAN.md, with a one-line why.)_

- 2026-06-30 — Design locked: allowlist-only execution, TOTP arm/disarm, personal local
  (non-sandboxed) install. Build split into TDD slices S0–S11.

## Log

_(Append newest first: date — slice — what got done, what's next, snags.)_

- 2026-06-30 — Created SPEC.md, PLAN.md, CLAUDE.md, and seeded this PROGRESS.md. Ready to
  begin S0.
