//
//  Base32.swift
//  RelayBack
//
//  RFC 4648 base32 decoding — turns a stored/entered TOTP secret string into key bytes.
//  Pure Core type: no I/O, no framework beyond Foundation.
//

import Foundation

enum Base32 {
    /// The RFC 4648 base32 alphabet, indexed by 5-bit value (used for encoding).
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Maps each base32 character (both cases) to its 5-bit value. Built once.
    private static let values: [Character: UInt8] = {
        var table = [Character: UInt8]()
        for (value, upper) in alphabet.enumerated() {
            table[upper] = UInt8(value)
            table[Character(upper.lowercased())] = UInt8(value)
        }
        return table
    }()

    /// Encodes bytes to an uppercase, **unpadded** RFC 4648 base32 string. Unpadded because that
    /// is the form `otpauth://` provisioning URIs and authenticator apps expect (the S10 QR);
    /// `decode` ignores padding anyway, so `decode(encode(x)) == x` holds.
    static func encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt = 0
        var bitsInBuffer = 0

        for byte in data {
            buffer = (buffer << 8) | UInt(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                bitsInBuffer -= 5
                output.append(alphabet[Int((buffer >> UInt(bitsInBuffer)) & 0x1f)])
            }
        }
        // Flush the remaining <5 bits, left-padded with zeros to a full 5-bit group.
        if bitsInBuffer > 0 {
            output.append(alphabet[Int((buffer << UInt(5 - bitsInBuffer)) & 0x1f)])
        }
        return output
    }

    /// Decodes a base32 string to bytes. Case-insensitive; ignores whitespace and `=` padding.
    /// Returns `nil` if the string contains any character outside the base32 alphabet.
    static func decode(_ string: String) -> Data? {
        var buffer: UInt = 0
        var bitsInBuffer = 0
        var bytes = [UInt8]()

        for character in string {
            if character == "=" || character.isWhitespace {
                continue
            }
            guard let value = values[character] else {
                return nil
            }
            buffer = (buffer << 5) | UInt(value)
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                bitsInBuffer -= 8
                bytes.append(UInt8((buffer >> UInt(bitsInBuffer)) & 0xFF))
            }
        }

        return Data(bytes)
    }
}
