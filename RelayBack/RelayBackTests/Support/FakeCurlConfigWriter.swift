//
//  FakeCurlConfigWriter.swift
//  RelayBackTests
//
//  A `CurlConfigWriting` fake for the coordinator's `/release`/`/pgyer` tests (S29). It records every
//  body it was asked to write (so a test can prove the PGYER key went into the config FILE — the
//  intended I3 channel — and nowhere else) and every path it was asked to remove (so a test can prove
//  the key file does not outlive the spawn). It returns a fixed, key-free path. No real filesystem I/O.
//

import Foundation
@testable import RelayBack

final class FakeCurlConfigWriter: CurlConfigWriting {
    /// The path every `writeConfig` returns — a fixed, secret-free stand-in for the temp file.
    let pathToReturn: String
    /// When true, `writeConfig` throws — lets a test drive the "could not prepare the upload" branch.
    var failWrite = false

    private(set) var writtenBodies: [String] = []
    private(set) var removedPaths: [String] = []

    init(pathToReturn: String = "/tmp/relayback-upload-fake.conf") {
        self.pathToReturn = pathToReturn
    }

    func writeConfig(_ body: String) throws -> String {
        if failWrite { throw CocoaError(.fileWriteUnknown) }
        writtenBodies.append(body)
        return pathToReturn
    }

    func removeConfig(at path: String) {
        removedPaths.append(path)
    }
}
