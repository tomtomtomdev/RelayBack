//
//  OutputFormatter.swift
//  RelayBack
//
//  S4 — turns a CommandResult into the messages to send back to the operator (FR-6). Pure and
//  deterministic: no I/O, no transport. It frames exit code + stdout + stderr, then either
//  chunks the text at Telegram's 4096-char limit or, when the output is large enough that
//  chunking would spam the chat, emits a single .txt document instead.
//

import Foundation

/// A message ready to hand to the transport (S6): either inline text or a file attachment.
enum OutgoingMessage: Equatable {
    case text(String)
    case document(name: String, data: Data)
}

enum OutputFormatter {
    /// Telegram's hard limit for a text message; chunks never exceed this.
    static let telegramTextLimit = 4096
    /// Above this many characters, send one document instead of many text chunks.
    /// Sits well above the text limit so moderately long output still arrives as a few messages.
    static let documentThreshold = 4096 * 4

    /// Frames the result and returns the message(s) to send, in order.
    static func format(_ result: CommandResult) -> [OutgoingMessage] {
        let framed = frame(result)

        if framed.count > documentThreshold {
            return [.document(name: "output.txt", data: Data(framed.utf8))]
        }
        return chunk(framed, limit: telegramTextLimit).map { .text($0) }
    }

    // MARK: - Framing

    /// Builds the human-readable body: a status line, then stdout, then a labeled stderr block.
    private static func frame(_ result: CommandResult) -> String {
        var text = "exit \(result.exitCode)"
        if result.stdout.isEmpty && result.stderr.isEmpty {
            text += "\n(no output)"
        } else {
            if !result.stdout.isEmpty { text += "\n" + result.stdout }
            if !result.stderr.isEmpty { text += "\n\nstderr:\n" + result.stderr }
        }
        return text
    }

    // MARK: - Chunking

    /// Splits `text` into pieces of at most `limit` characters, preferring newline boundaries.
    /// A single line longer than `limit` is hard-split. Always returns at least one chunk.
    private static func chunk(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSplit(line, limit: limit))
                continue
            }
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > limit {
                chunks.append(current)
                current = line
            } else {
                current = candidate
            }
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }

    /// Breaks a single over-long line into fixed-size pieces.
    private static func hardSplit(_ line: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(line)
        while !rest.isEmpty {
            let piece = rest.prefix(limit)
            pieces.append(String(piece))
            rest = rest.dropFirst(piece.count)
        }
        return pieces
    }
}
