//
//  Base32Tests.swift
//  RelayBackTests
//
//  S1 — Base32 (RFC 4648) decode used to turn a stored TOTP secret into key bytes.
//

import Foundation
import Testing
@testable import RelayBack

struct Base32Tests {

    // RFC 6238 Appendix B SHA-1 seed is ASCII "12345678901234567890",
    // whose RFC 4648 base32 encoding is this string.
    @Test func decodesRFCSeedToASCIIBytes() throws {
        let data = try #require(Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
        #expect(data == Data("12345678901234567890".utf8))
    }

    @Test func decodeIsCaseInsensitive() throws {
        let upper = try #require(Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
        let lower = try #require(Base32.decode("gezdgnbvgy3tqojqgezdgnbvgy3tqojq"))
        #expect(upper == lower)
    }

    @Test func ignoresPaddingAndSpaces() throws {
        // "MY======" is base32 for a single byte 0x66 ('f').
        let padded = try #require(Base32.decode("MY======"))
        #expect(padded == Data([0x66]))
        let spaced = try #require(Base32.decode("MZXW 6==="))
        #expect(spaced == Data("foo".utf8))
    }

    @Test func emptyStringDecodesToEmptyData() throws {
        let data = try #require(Base32.decode(""))
        #expect(data.isEmpty)
    }

    @Test func invalidCharactersReturnNil() {
        // '1', '8', '0', '9' are not in the RFC 4648 base32 alphabet.
        #expect(Base32.decode("ABC10189") == nil)
        #expect(Base32.decode("!!!!") == nil)
    }

    // MARK: - Encode (S10 — needed for the otpauth QR)

    @Test func encodesRFC4648TestVectors() {
        // RFC 4648 §10 vectors, unpadded (the form otpauth/authenticator apps expect).
        #expect(Base32.encode(Data("".utf8)) == "")
        #expect(Base32.encode(Data("f".utf8)) == "MY")
        #expect(Base32.encode(Data("fo".utf8)) == "MZXQ")
        #expect(Base32.encode(Data("foo".utf8)) == "MZXW6")
        #expect(Base32.encode(Data("foob".utf8)) == "MZXW6YQ")
        #expect(Base32.encode(Data("fooba".utf8)) == "MZXW6YTB")
        #expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")
    }

    @Test func encodesRFCSeedToTheKnownString() {
        // The RFC 6238 Appendix B SHA-1 seed round-trips to its canonical base32.
        let seed = Data("12345678901234567890".utf8)
        #expect(Base32.encode(seed) == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    }

    @Test func encodeThenDecodeRoundTrips() throws {
        let bytes = Data([0x00, 0x0f, 0x10, 0x7f, 0x80, 0xff, 0xa5, 0x5a, 0x13])
        let round = try #require(Base32.decode(Base32.encode(bytes)))
        #expect(round == bytes)
    }
}
