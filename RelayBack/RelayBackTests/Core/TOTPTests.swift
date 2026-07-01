//
//  TOTPTests.swift
//  RelayBackTests
//
//  S1 — RFC 6238 TOTP (HMAC-SHA-1, 6 digits, 30s). Oracle: RFC 6238 Appendix B vectors.
//

import Foundation
import Testing
@testable import RelayBack

struct TOTPTests {

    // RFC 6238 Appendix B SHA-1 seed ("12345678901234567890"), base32-encoded.
    private let secret = Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")!

    private func date(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

    // MARK: - Known-answer vectors (last 6 digits of the RFC's 8-digit SHA-1 values)

    @Test(arguments: [
        (TimeInterval(59), "287082"),
        (TimeInterval(1_111_111_109), "081804"),
        (TimeInterval(1_111_111_111), "050471"),
        (TimeInterval(1_234_567_890), "005924"),
        (TimeInterval(2_000_000_000), "279037"),
        (TimeInterval(20_000_000_000), "353130"),
    ])
    func rfc6238Vectors(unix: TimeInterval, expected: String) {
        #expect(TOTP.code(secret: secret, at: date(unix)) == expected)
    }

    @Test func codeIsAlwaysSixDigits() {
        // Value 1234567890 -> 8-digit 89005924 -> zero-padded 6-digit "005924".
        let code = TOTP.code(secret: secret, at: date(1_234_567_890))
        let allDigits = code.allSatisfy { $0.isNumber }
        #expect(code.count == 6)
        #expect(allDigits)
    }

    // MARK: - validate

    @Test func validateAcceptsCurrentCode() {
        #expect(TOTP.validate("287082", secret: secret, at: date(59)))
    }

    @Test func validateRejectsWrongCode() {
        #expect(!TOTP.validate("000000", secret: secret, at: date(59)))
    }

    @Test func validateAcceptsOneStepDrift() {
        // Code from the previous window (t=29, one 30s step back) still validates at t=59.
        let prev = TOTP.code(secret: secret, at: date(29))
        #expect(TOTP.validate(prev, secret: secret, at: date(59)))
        // Code from the next window (t=89) also validates.
        let next = TOTP.code(secret: secret, at: date(89))
        #expect(TOTP.validate(next, secret: secret, at: date(59)))
    }

    @Test func validateRejectsTwoStepDrift() {
        // Two windows back (t=0..29 vs t=59) must be rejected with default ±1 drift.
        let twoBack = TOTP.code(secret: secret, at: date(0))
        #expect(!TOTP.validate(twoBack, secret: secret, at: date(89)))
    }

    @Test func validateRejectsNonNumericCode() {
        #expect(!TOTP.validate("abcdef", secret: secret, at: date(59)))
    }
}
