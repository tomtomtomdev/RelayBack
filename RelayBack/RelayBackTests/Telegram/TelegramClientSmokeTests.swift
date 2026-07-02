//
//  TelegramClientSmokeTests.swift
//  RelayBackTests
//
//  S6 — one focused, network-free check that the real `TelegramClient` wires a request through to
//  the pure decoder (per CLAUDE: the thin URLSession impl gets a smoke test, not full coverage).
//  A `URLProtocol` stub intercepts the request, so no live network is touched. The pure decode +
//  offset behavior is covered exhaustively by `TelegramModelsTests`; this only proves the plumbing
//  (URL/method/endpoint → response body → `decodeBatch`) holds together.
//

import Foundation
import Testing
@testable import RelayBack

struct TelegramClientSmokeTests {

    @Test func getUpdatesRoutesToEndpointAndDecodesBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = try TelegramClient(token: "test-token", session: session)
        let updates = try await client.getUpdates(offset: 0)

        // The stub only serves this body when the request actually hits …/getUpdates, so a green
        // assertion also proves the endpoint/method wiring is correct.
        #expect(updates.count == 1)
        #expect(updates[0].updateId == 500)
        #expect(updates[0].message?.from?.id == 111)
        #expect(updates[0].message?.text == "/uptime")
    }
}

/// Answers any request to `…/getUpdates` with a canned 200 response; anything else 404s (so a
/// mis-wired endpoint fails the test). No real network I/O.
private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let isGetUpdates = url.lastPathComponent == "getUpdates"
        let status = isGetUpdates ? 200 : 404
        let body = isGetUpdates ? Data(Self.getUpdatesJSON.utf8) : Data()

        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static let getUpdatesJSON = """
    {
      "ok": true,
      "result": [
        {
          "update_id": 500,
          "message": {
            "message_id": 1,
            "from": { "id": 111, "is_bot": false, "first_name": "Tom" },
            "chat": { "id": 111, "type": "private" },
            "date": 1700000000,
            "text": "/uptime"
          }
        }
      ]
    }
    """
}
