//
//  RelayBackTests.swift
//  RelayBackTests
//
//  S0 bootstrap smoke test. Real Core/ tests arrive in S1+.
//

import Testing
@testable import RelayBack

struct RelayBackTests {

    @Test func bootstrapSmoke() async throws {
        // Proves the test target links against the app module and runs.
        #expect(Bool(true))
    }

}
