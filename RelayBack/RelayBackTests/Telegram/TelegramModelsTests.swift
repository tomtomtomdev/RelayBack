//
//  TelegramModelsTests.swift
//  RelayBackTests
//
//  S6 — the Telegram wire contract (FR-1). These are the pure, TDD-first part of the transport
//  slice: decoding real `getUpdates` JSON into models and computing the next poll offset so no
//  update is ever reprocessed. No network — fixtures are decoded directly. The URLSession client
//  is thin and verified separately (see `TelegramClientSmokeTests`).
//

import Foundation
import Testing
@testable import RelayBack

struct TelegramModelsTests {

    // MARK: - decodeBatch: a normal getUpdates response

    @Test func decodesMessageUpdates() throws {
        let json = """
        {
          "ok": true,
          "result": [
            {
              "update_id": 100000001,
              "message": {
                "message_id": 42,
                "from": { "id": 111, "is_bot": false, "first_name": "Tom" },
                "chat": { "id": 555, "type": "private" },
                "date": 1700000000,
                "text": "/uptime"
              }
            },
            {
              "update_id": 100000002,
              "message": {
                "message_id": 43,
                "from": { "id": 111, "is_bot": false, "first_name": "Tom" },
                "chat": { "id": 555, "type": "private" },
                "date": 1700000005,
                "text": "/status"
              }
            }
          ]
        }
        """
        let updates = try TelegramUpdate.decodeBatch(from: Data(json.utf8))

        #expect(updates.count == 2)
        #expect(updates[0].updateId == 100000001)
        #expect(updates[0].message?.from?.id == 111)   // auth checks from.id (I2)
        #expect(updates[0].message?.chat.id == 555)     // replies go to chat.id
        #expect(updates[0].message?.text == "/uptime")
        #expect(updates[1].message?.text == "/status")
    }

    // MARK: - decodeBatch: updates we ignore still decode cleanly (no crash)

    @Test func nonMessageUpdateDecodesWithNilMessage() throws {
        // e.g. an edited_message / callback_query — key "message" is absent.
        let json = """
        {
          "ok": true,
          "result": [
            { "update_id": 200000001, "edited_message": { "message_id": 9, "text": "x" } }
          ]
        }
        """
        let updates = try TelegramUpdate.decodeBatch(from: Data(json.utf8))

        #expect(updates.count == 1)
        #expect(updates[0].updateId == 200000001)
        #expect(updates[0].message == nil)   // coordinator ignores these
    }

    @Test func messageWithoutFromDecodesWithNilSender() throws {
        // Channel posts carry no `from`; such a message can never be authorized (from.id is nil).
        let json = """
        {
          "ok": true,
          "result": [
            {
              "update_id": 300000001,
              "message": {
                "message_id": 7,
                "chat": { "id": -100200, "type": "channel" },
                "date": 1700000000,
                "text": "hi"
              }
            }
          ]
        }
        """
        let updates = try TelegramUpdate.decodeBatch(from: Data(json.utf8))

        #expect(updates[0].message?.from == nil)
        #expect(updates[0].message?.chat.id == -100200)
    }

    @Test func emptyResultDecodesToNoUpdates() throws {
        let updates = try TelegramUpdate.decodeBatch(from: Data(#"{"ok":true,"result":[]}"#.utf8))
        #expect(updates.isEmpty)
    }

    // MARK: - decodeBatch: malformed payload throws instead of crashing

    @Test func malformedPayloadThrows() {
        // update_id is the wrong type — decode must throw, never trap.
        let json = #"{"ok":true,"result":[{"update_id":"not-a-number"}]}"#
        #expect(throws: (any Error).self) {
            try TelegramUpdate.decodeBatch(from: Data(json.utf8))
        }
    }

    @Test func truncatedPayloadThrows() {
        #expect(throws: (any Error).self) {
            try TelegramUpdate.decodeBatch(from: Data(#"{"ok":true,"result":["#.utf8))
        }
    }

    // MARK: - nextOffset: FR-1, never reprocess an update

    @Test func nextOffsetIsHighestUpdateIdPlusOne() throws {
        let updates = makeUpdates(ids: [10, 11, 12])
        #expect(TelegramUpdate.nextOffset(after: 0, in: updates) == 13)
    }

    @Test func nextOffsetUsesMaxRegardlessOfOrder() throws {
        let updates = makeUpdates(ids: [12, 10, 11])
        #expect(TelegramUpdate.nextOffset(after: 0, in: updates) == 13)
    }

    @Test func nextOffsetIsUnchangedForEmptyBatch() throws {
        #expect(TelegramUpdate.nextOffset(after: 77, in: []) == 77)
    }

    @Test func nextOffsetNeverMovesBackward() throws {
        // A stale/out-of-order batch below the current offset must not rewind polling.
        let updates = makeUpdates(ids: [10, 11, 12])
        #expect(TelegramUpdate.nextOffset(after: 100, in: updates) == 100)
    }

    // MARK: - Helpers

    private func makeUpdates(ids: [Int64]) -> [TelegramUpdate] {
        ids.map { id in
            let json = "{\"update_id\":\(id)}"
            return try! TelegramUpdate.decodeBatch(from: Data("{\"ok\":true,\"result\":[\(json)]}".utf8))[0]
        }
    }
}
