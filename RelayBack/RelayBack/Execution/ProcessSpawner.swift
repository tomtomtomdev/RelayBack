//
//  ProcessSpawner.swift
//  RelayBack
//
//  S20 — the shared process spawn / capture / timeout core, extracted verbatim from the S7
//  `ProcessCommandRunner` so both the fixed-allowlist runner and the agent runner
//  (`ProcessClaudeRunner`, §4b) spawn through ONE audited code path rather than two divergent
//  copies. It takes primitive parameters (never an `Action`, never operator text as the executable)
//  and is the concrete site of:
//    • I1 (no shell, ever): `executable` + the fixed `arguments` array are handed straight to
//      `Process` (execve). Operator text is never concatenated into a command line and `/bin/sh -c`
//      is never used, so shell injection is impossible by construction.
//    • I4 (never elevate): the child inherits this (normal, non-root) process's privileges — no
//      privilege-escalation API — and runs with a restricted PATH and no inherited operator env.
//
//  Behavior is unchanged from the S7 runner; `CommandRunnerTests` still pin it via `ProcessCommandRunner`.
//

import Foundation

enum ProcessSpawner {
    /// The only PATH exposed to spawned children. Executables are absolute, so this is for any
    /// sub-processes they launch — kept minimal, and deliberately excludes user-writable dirs.
    static let restrictedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Exit code reported when a run is killed for exceeding its timeout. 124 matches coreutils
    /// `timeout(1)`, so it reads unambiguously in output/audit.
    static let timeoutExitCode: Int32 = 124

    /// Exit code reported when the executable could not be launched at all (bad path, not
    /// executable). 127 mirrors the shell "command not found" convention.
    static let launchFailureExitCode: Int32 = 127

    static func run(executable: String,
                    arguments: [String],
                    workingDirectory: String?,
                    timeout: TimeInterval) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments                        // I1: fixed array → execve, never a shell.
        process.environment = ["PATH": restrictedPath]       // I4 / hygiene: no inherited env.
        if let workingDirectory {                            // §4a / §4b: only an allowlisted repo root.
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                exitCode: launchFailureExitCode,
                stdout: "",
                stderr: "failed to launch \(executable): \(error.localizedDescription)")
        }

        // Drain both pipes concurrently, off the cooperative pool: a chatty child could otherwise
        // fill a pipe's buffer and block on write forever while we wait for it to exit (deadlock).
        async let stdoutData = drain(stdoutPipe)
        async let stderrData = drain(stderrPipe)

        let timedOut = await waitForExitOrTimeout(process, timeout: timeout)

        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        var stderr = String(decoding: await stderrData, as: UTF8.self)

        if timedOut {
            if !stderr.isEmpty && !stderr.hasSuffix("\n") { stderr += "\n" }
            stderr += "[timed out after \(describe(timeout))s; process terminated]"
            return CommandResult(exitCode: timeoutExitCode, stdout: stdout, stderr: stderr)
        }
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - Helpers

    /// Wait for the process to exit, or terminate it once `timeout` elapses. Returns `true` iff the
    /// timeout fired. Either way the process is dead by the time this returns, so the pipes reach EOF
    /// and the drain tasks complete.
    private static func waitForExitOrTimeout(_ process: Process, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waitUntilExit(process); return false }   // exited first
            group.addTask {
                // Sleep returns normally → timeout fired; throws (cancelled) → process won the race.
                (try? await Task.sleep(nanoseconds: nanoseconds(timeout))) != nil
            }

            let timedOut = await group.next() ?? false
            if timedOut {
                process.terminate()   // SIGTERM — lets the exit-waiter finish so the group drains.
            } else {
                group.cancelAll()     // process already gone; wake the sleeper.
            }
            return timedOut
        }
    }

    /// Bridge `Process.waitUntilExit()` (blocking) onto async without tying up the cooperative pool.
    private static func waitUntilExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// Read a pipe to EOF on a background queue, bridged to async.
    private static func drain(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }

    /// Trim a trailing ".0" so whole-second timeouts read as "10" not "10.0" in the stderr note.
    private static func describe(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}
