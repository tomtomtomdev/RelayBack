//
//  AuthGuard.swift
//  RelayBack
//
//  S3 — the arm/disarm state machine and the gate for invariant I2.
//
//  I2 (no run unless authorized AND armed): `authorize` returns `.runAction` only when the
//  sender's `from.id` is on the allowlist AND the session is currently armed. Identity is
//  always checked first, against `from.id` (never a chat id). The TOTP secret is held only in
//  memory for `/arm` validation and is never logged or echoed (I3) — that is the coordinator's
//  contract; this type never emits it.
//

import Foundation

/// The outcome of routing one operator message. The coordinator (S8) turns this into a reply
/// and an audit entry; only `.runAction` ever leads to spawning a process.
enum Decision: Equatable {
    /// `from.id` is not on the allowlist — drop silently (invariant I2, FR-2).
    case rejectedUnknownUser
    /// A control command was handled (arm / disarm / status). Never executes an action.
    case control(ControlResult)
    /// Authorized sender requested an action while the session is not armed (invariant I2).
    case disarmed
    /// Authorized sender, armed session, matched action — safe to run (invariant I2).
    case runAction(Action)
    /// Authorized sender, but the text matches no action and no control command.
    case unknownCommand
}

/// The result of a control command.
enum ControlResult: Equatable {
    case armAccepted        // valid TOTP → session now armed
    case armRejected        // missing / invalid TOTP → still disarmed
    case disarmAccepted     // session dropped to disarmed
    case status(isArmed: Bool)
}

struct AuthGuard {
    private var allowlist: Set<Int64>
    private let totpSecret: Data
    private let registry: ActionRegistry
    private let clock: Clock
    private let idleTimeout: TimeInterval

    /// End of the armed window; nil means never armed. Armed iff `clock.now < armedUntil`.
    /// Expiry is derived lazily from this instant — no background timer needed (pure type).
    private var armedUntil: Date?

    init(allowlist: Set<Int64>,
         totpSecret: Data,
         registry: ActionRegistry,
         clock: Clock,
         idleTimeout: TimeInterval) {
        self.allowlist = allowlist
        self.totpSecret = totpSecret
        self.registry = registry
        self.clock = clock
        self.idleTimeout = idleTimeout
    }

    /// Replaces the authorization allowlist at runtime (S12 — hot-reload from Settings). Arm state
    /// is intentionally preserved: identity and session are orthogonal, so editing who may run
    /// commands must neither drop a legitimate operator's live session nor keep a removed id armed.
    /// A removed id is revoked immediately — its next message fails the identity gate (invariant I2).
    mutating func updateAllowlist(_ ids: Set<Int64>) {
        allowlist = ids
    }

    /// Drops the session to disarmed immediately (S13b — the popover's "Disarm now" button). Same
    /// effect as a `/disarm` message, without routing through `authorize`; identity is not involved.
    mutating func disarm() {
        armedUntil = nil
    }

    /// True while the armed window is still open.
    var isArmed: Bool {
        guard let armedUntil else { return false }
        return clock.now < armedUntil
    }

    /// Seconds left in the armed window, clamped to 0 (never negative); 0 when disarmed.
    var remainingArmedTime: TimeInterval {
        guard let armedUntil else { return 0 }
        return max(0, armedUntil.timeIntervalSince(clock.now))
    }

    /// Routes one operator message to a `Decision`, updating arm state as a side effect.
    mutating func authorize(fromId: Int64, text: String) -> Decision {
        // I2 / FR-2: identity gate first — check from.id (never chat id). Non-members dropped.
        guard allowlist.contains(fromId) else { return .rejectedUnknownUser }

        guard let token = text.split(whereSeparator: \.isWhitespace).first?.lowercased() else {
            return .unknownCommand   // empty / whitespace-only message from an allowlisted user
        }

        switch token {
        case "/arm":
            return .control(handleArm(text))
        case "/disarm":
            armedUntil = nil
            return .control(.disarmAccepted)
        case "/status":
            return .control(.status(isArmed: isArmed))   // read-only: never touches arm state
        default:
            guard let action = registry.match(text) else { return .unknownCommand }
            guard isArmed else { return .disarmed }       // I2: actions run only while armed
            extendArmedWindow()                            // authorized action resets idle timer
            return .runAction(action)
        }
    }

    // MARK: - Private

    private mutating func handleArm(_ text: String) -> ControlResult {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return .armRejected }         // "/arm" with no code
        guard TOTP.validate(String(parts[1]), secret: totpSecret, at: clock.now) else {
            return .armRejected
        }
        extendArmedWindow()
        return .armAccepted
    }

    private mutating func extendArmedWindow() {
        armedUntil = clock.now.addingTimeInterval(idleTimeout)
    }
}
