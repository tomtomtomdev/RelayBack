//
//  OtpAuthURITests.swift
//  RelayBackTests
//
//  S10 — the otpauth:// provisioning URI the Settings QR encodes (FR-9). Pinned to an exact
//  string so the QR a phone scans yields codes AuthGuard validates (same secret, digits, period).
//

import Foundation
import Testing
@testable import RelayBack

struct OtpAuthURITests {

    @Test func buildsCanonicalURIForRFCSeed() {
        let secret = Data("12345678901234567890".utf8)
        let uri = OtpAuthURI.totp(secret: secret, issuer: "RelayBack", account: "mac")
        #expect(uri == "otpauth://totp/RelayBack:mac"
            + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
            + "&issuer=RelayBack&algorithm=SHA1&digits=6&period=30")
    }

    @Test func percentEncodesIssuerAndAccount() {
        let uri = OtpAuthURI.totp(secret: Data([0x00]), issuer: "Relay Back", account: "my mac")
        #expect(uri.contains("otpauth://totp/Relay%20Back:my%20mac?"))
        #expect(uri.contains("&issuer=Relay%20Back&"))
    }

    @Test func secretIsBase32OfTheRawBytes() {
        let secret = Data("foobar".utf8)   // base32 (unpadded) = MZXW6YTBOI
        let uri = OtpAuthURI.totp(secret: secret, issuer: "R", account: "a")
        #expect(uri.contains("secret=MZXW6YTBOI&"))
    }
}
