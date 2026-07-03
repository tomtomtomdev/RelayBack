//
//  OtpAuthURI.swift
//  RelayBack
//
//  S10 — builds the `otpauth://totp/...` provisioning URI the Settings UI renders as a QR code
//  for the operator to scan into their authenticator app (FR-9). Pure string construction: no
//  I/O, framework-light, fully testable against a fixed expected string.
//
//  The parameters are pinned to this app's fixed TOTP configuration (HMAC-SHA-1, 6 digits, 30s —
//  SPEC §9, and the same values `TOTP` uses), so a scanned secret produces exactly the codes
//  `AuthGuard` validates. The algorithm is spelled per the otpauth key-uri spec.
//

import Foundation

enum OtpAuthURI {
    /// Builds an `otpauth://totp/<issuer>:<account>?...` URI for `secret` (raw key bytes).
    /// The secret is base32-encoded; `issuer`/`account` are percent-encoded for the label and
    /// query. Mirrors `TOTP`'s fixed digits/period so the QR and validation stay in sync.
    static func totp(secret: Data, issuer: String, account: String) -> String {
        let label = "\(percentEncoded(issuer)):\(percentEncoded(account))"
        let query = [
            "secret=\(Base32.encode(secret))",
            "issuer=\(percentEncoded(issuer))",
            "algorithm=SHA1",
            "digits=\(TOTP.digits)",
            "period=\(Int(TOTP.period))",
        ].joined(separator: "&")
        return "otpauth://totp/\(label)?\(query)"
    }

    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// RFC 3986 §2.3 unreserved characters; everything else in a label/issuer is escaped.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
