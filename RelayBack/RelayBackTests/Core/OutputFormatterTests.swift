//
//  OutputFormatterTests.swift
//  RelayBackTests
//
//  S4 — turning a CommandResult into Telegram-ready messages (FR-6): frame exit code + stdout
//  + stderr, chunk at the 4096-char limit, and fall back to a single .txt document when the
//  output is too large to be worth chunking.
//

import Foundation
import Testing
@testable import RelayBack

struct OutputFormatterTests {

    private func result(exit: Int32 = 0, out: String = "", err: String = "") -> CommandResult {
        CommandResult(exitCode: exit, stdout: out, stderr: err)
    }

    /// Convenience: the text of a message, or fails the test if it isn't `.text`.
    private func textOf(_ message: OutgoingMessage, _ comment: Comment = "expected .text") -> String {
        guard case .text(let s) = message else { Issue.record(comment); return "" }
        return s
    }

    // MARK: - Short output

    @Test func shortOutputProducesSingleText() {
        let msgs = OutputFormatter.format(result(exit: 0, out: "up 3 days, 2 users"))
        #expect(msgs.count == 1)
        let s = textOf(msgs[0])
        #expect(s.contains("up 3 days, 2 users"))
        #expect(s.contains("exit 0"))
    }

    @Test func emptyOutputIsHandled() {
        let msgs = OutputFormatter.format(result(exit: 0, out: "", err: ""))
        #expect(msgs.count == 1)
        let s = textOf(msgs[0])
        #expect(s.contains("exit 0"))
        #expect(s.contains("(no output)"))
    }

    // MARK: - Exit code + stderr framing

    @Test func nonzeroExitAndStderrAreShown() {
        let msgs = OutputFormatter.format(result(exit: 2, out: "partial output", err: "kaboom"))
        #expect(msgs.count == 1)
        let s = textOf(msgs[0])
        #expect(s.contains("exit 2"))
        #expect(s.contains("partial output"))
        #expect(s.contains("kaboom"))
    }

    @Test func stderrOnlyIsShownWithoutNoOutputPlaceholder() {
        let msgs = OutputFormatter.format(result(exit: 1, out: "", err: "permission denied"))
        let s = textOf(msgs[0])
        #expect(s.contains("exit 1"))
        #expect(s.contains("permission denied"))
        #expect(!s.contains("(no output)"))   // there IS output (on stderr)
    }

    // MARK: - Chunking

    @Test func outputOverLimitSplitsIntoChunksNoneOverLimit() {
        // ~8040 chars: over the 4096 text limit, but under the document threshold.
        let line = String(repeating: "x", count: 200)
        let body = Array(repeating: line, count: 40).joined(separator: "\n")
        let msgs = OutputFormatter.format(result(exit: 0, out: body))
        #expect(msgs.count >= 2)
        for m in msgs {
            #expect(textOf(m).count <= OutputFormatter.telegramTextLimit)
        }
    }

    @Test func aSingleLineLongerThanTheLimitIsHardSplit() {
        // One newline-free line just over the limit but under the document threshold.
        let body = String(repeating: "a", count: OutputFormatter.telegramTextLimit + 500)
        let msgs = OutputFormatter.format(result(exit: 0, out: body))
        #expect(msgs.count >= 2)
        for m in msgs {
            #expect(textOf(m).count <= OutputFormatter.telegramTextLimit)
        }
    }

    @Test func chunkingPreservesContent() {
        let line = String(repeating: "z", count: 100)
        let body = Array(repeating: line, count: 60).joined(separator: "\n")
        let msgs = OutputFormatter.format(result(exit: 0, out: body))
        let reassembled = msgs.map { textOf($0) }.joined(separator: "\n")
        #expect(reassembled.contains(line))
        #expect(reassembled.contains("exit 0"))
    }

    // MARK: - Document fallback

    @Test func veryLargeOutputBecomesSingleDocument() {
        let body = String(repeating: "y", count: OutputFormatter.documentThreshold + 1)
        let msgs = OutputFormatter.format(result(exit: 0, out: body))
        #expect(msgs.count == 1)
        guard case .document(let name, let data) = msgs[0] else {
            Issue.record("expected a single .document")
            return
        }
        #expect(name.hasSuffix(".txt"))
        // The document carries the full framed output, not a truncation.
        let contents = String(data: data, encoding: .utf8)
        #expect(contents?.contains(body) == true)
        #expect(contents?.contains("exit 0") == true)
    }
}
