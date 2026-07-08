//
//  LogText.swift
//  RelayBack
//
//  Shared, pure helpers for the append-only local logs (the command audit log and the
//  connection-lifecycle log). Both render one line per event as `<ISO8601-UTC> …`, and both must
//  neutralize free text so a single event can only ever produce a single line — an attacker (or a
//  noisy error) can't inject a forged extra line or break a quoted field (append-only integrity, I3).
//

import Foundation

enum LogText {
    /// Fixed UTC ISO-8601 (`2026-07-03T15:04:05Z`). Stable across locales/timezones so log lines
    /// are comparable and greppable.
    static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// The inverse of `timestamp` — parses a `<ISO8601-UTC>` field back to a `Date` (nil if it
    /// doesn't match). Used by the audit-log read side (S13f) to rebuild entries from stored lines.
    static func date(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    /// Neutralizes characters that would break the one-line-per-entry guarantee or a quoted field:
    /// newlines/CR/tab collapse to a space, and inner double quotes become single quotes.
    static func sanitized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\n", "\r", "\t":
                result.append(" ")
            case "\"":
                result.append("'")
            default:
                result.append(character)
            }
        }
        return result
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
