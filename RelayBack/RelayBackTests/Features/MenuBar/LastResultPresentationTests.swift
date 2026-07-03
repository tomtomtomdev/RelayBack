//
//  LastResultPresentationTests.swift
//  RelayBackTests
//
//  S13b — the pure mapping from a finished command run to the popover's "Last result" terminal
//  card (FR-9). It frames the command line, an exit-code label (success vs. failure), and the
//  output split into lines the dark card renders. No I/O; tested directly.
//

import Foundation
import Testing
@testable import RelayBack

struct LastResultPresentationTests {

    @Test func exitZeroIsFramedAsSuccessWithOutputLines() {
        let result = CommandResult(exitCode: 0,
                                   stdout: "14:32 up 6 days, 2:11\nload avg 1.42 1.20 1.08",
                                   stderr: "")
        let p = LastResultPresentation(command: "/uptime", result: result)

        #expect(p.commandLine == "$ /uptime")
        #expect(p.exitLabel == "exit 0")
        #expect(p.exitIsSuccess)
        #expect(p.outputLines == ["14:32 up 6 days, 2:11", "load avg 1.42 1.20 1.08"])
    }

    @Test func nonzeroExitIsFramedAsFailure() {
        let result = CommandResult(exitCode: 1, stdout: "", stderr: "df: /nope: No such file")
        let p = LastResultPresentation(command: "/disk", result: result)

        #expect(p.exitLabel == "exit 1")
        #expect(p.exitIsSuccess == false)
        // With no stdout, the card falls back to stderr so the operator sees the failure text.
        #expect(p.outputLines == ["df: /nope: No such file"])
    }

    @Test func trailingNewlineDoesNotAddABlankLine() {
        let p = LastResultPresentation(command: "/whoami",
                                       result: CommandResult(exitCode: 0, stdout: "tommy\n", stderr: ""))
        #expect(p.outputLines == ["tommy"])
    }

    @Test func emptyOutputHasNoLines() {
        let p = LastResultPresentation(command: "/uptime",
                                       result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        #expect(p.outputLines.isEmpty)
    }
}
