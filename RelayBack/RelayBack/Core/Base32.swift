//
//  Base32.swift
//  RelayBack
//
//  RFC 4648 base32 decoding — turns a stored/entered TOTP secret string into key bytes.
//  Pure Core type: no I/O, no framework beyond Foundation.
//

import Foundation

enum Base32 {
    /// Maps each base32 character (both cases) to its 5-bit value. Built once.
    private static let values: [Character: UInt8] = {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var table = [Character: UInt8]()
        for (value, upper) in alphabet.enumerated() {
            table[upper] = UInt8(value)
            table[Character(upper.lowercased())] = UInt8(value)
        }
        return table
    }()

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
