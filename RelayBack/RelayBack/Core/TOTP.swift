//
//  TOTP.swift
//  RelayBack
//
//  RFC 6238 time-based one-time passwords. Pure Core type: deterministic in `at:`,
//  no clock/I/O of its own so it is fully testable against RFC 6238 Appendix B vectors.
//
//  Algorithm is fixed to HMAC-SHA-1 / 6 digits / 30s per SPEC §9. SHA-1 is REQUIRED here,
//  not a choice: RFC 6238 mandates it and it is what standard authenticator apps generate.
//  HMAC-SHA-1 is not affected by SHA-1's collision weakness (HMAC needs no collision
//  resistance), so this is safe despite generic "avoid SHA-1" lint.
//

import Foundation
import CryptoKit

enum TOTP {
    /// Number of digits in a generated code.
    static let digits = 6
    /// Time step in seconds.
    static let period: TimeInterval = 30

    /// Generates the TOTP code for `secret` (raw key bytes) at `date`.
    static func code(secret: Data, at date: Date) -> String {
        let counter = UInt64(floor(date.timeIntervalSince1970 / period))
        return code(secret: secret, counter: counter)
    }

    /// Validates `candidate` against the codes within `driftSteps` windows of `date`.
    /// Default ±1 step tolerates minor clock skew (SPEC FR-3); ±2 or more is rejected.
    static func validate(_ candidate: String, secret: Data, at date: Date, driftSteps: Int = 1) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == digits, trimmed.allSatisfy(\.isNumber) else { return false }

        let center = Int64(floor(date.timeIntervalSince1970 / period))
        for step in (-driftSteps)...driftSteps {
            let counter = UInt64(bitPattern: center + Int64(step))
            if constantTimeEquals(trimmed, code(secret: secret, counter: counter)) {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    private static func code(secret: Data, counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }

        let key = SymmetricKey(data: secret)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)
        let hash = Array(mac)

        // Dynamic truncation (RFC 4226 §5.3).
        let offset = Int(hash[hash.count - 1] & 0x0f)
        let binary = (UInt32(hash[offset] & 0x7f) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])

        let modulus = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)u", binary % modulus)
    }

    /// Length-constant comparison to avoid leaking match position via timing.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
