//
//  TelegramClient.swift
//  RelayBack
//
//  S6 — the real `TelegramTransport`, backed by `URLSession` (FR-1, FR-6).
//
//  Deliberately thin: it builds one request per Bot API call, checks the response, and hands the
//  body to the pure decoder in `TelegramModels`. It holds no polling state — the offset-advancing
//  long-poll loop lives above it (S8/S11) and is tested against the protocol fake, not this type.
//  Per CLAUDE, the real impl is verified by compilation plus one focused, network-free smoke test
//  (`TelegramClientSmokeTests`, via a `URLProtocol` stub); no test hits the live network.
//
//  I3: the bot token is embedded in every request URL. That URL (and the token) must never be
//  logged or written to the audit log. The token is supplied from the Keychain by the caller.
//

import Foundation

/// A Bot API call failed. Carries only a status code or Telegram's own `description` — never the
/// request URL or the token (invariant I3).
enum TelegramError: Error, Equatable {
    case emptyToken
    case invalidResponse
    case httpStatus(Int)
    case api(description: String)
}

struct TelegramClient: TelegramTransport {
    private let baseURL: URL
    private let session: URLSession
    private let longPollTimeout: Int

    /// - Parameters:
    ///   - token: the bot token read from the Keychain (I3). Not logged.
    ///   - session: injectable so tests can supply a `URLProtocol`-stubbed session.
    ///   - longPollTimeout: seconds Telegram holds a `getUpdates` request open with no updates.
    init(token: String, session: URLSession? = nil, longPollTimeout: Int = 25) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(trimmed)") else {
            throw TelegramError.emptyToken
        }
        self.baseURL = url
        self.longPollTimeout = longPollTimeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            // The request must outlive the server-side long poll, or it cancels mid-poll.
            config.timeoutIntervalForRequest = TimeInterval(longPollTimeout + 15)
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - TelegramTransport

    func getUpdates(offset: Int64) async throws -> [TelegramUpdate] {
        struct Params: Encodable {
            let offset: Int64
            let timeout: Int
            let allowedUpdates: [String]
        }
        let body = Params(offset: offset, timeout: longPollTimeout, allowedUpdates: ["message"])
        let data = try await perform(jsonRequest(method: "getUpdates", body: body))
        return try TelegramUpdate.decodeBatch(from: data)
    }

    func sendMessage(chatId: Int64, text: String) async throws {
        struct Params: Encodable {
            let chatId: Int64
            let text: String
        }
        _ = try await perform(jsonRequest(method: "sendMessage",
                                          body: Params(chatId: chatId, text: text)))
    }

    func setMyCommands(_ commands: [BotCommand]) async throws {
        struct Params: Encodable { let commands: [BotCommand] }
        _ = try await perform(jsonRequest(method: "setMyCommands", body: Params(commands: commands)))
    }

    func sendDocument(chatId: Int64, filename: String, data: Data) async throws {
        _ = try await perform(multipartRequest(chatId: chatId, filename: filename, fileData: data))
    }

    // MARK: - Request building

    private func url(for method: String) -> URL {
        baseURL.appendingPathComponent(method)
    }

    private func jsonRequest<Body: Encodable>(method: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url(for: method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase   // chatId → chat_id, allowedUpdates → …
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// `sendDocument` needs `multipart/form-data`: the chat id as a field and the file bytes.
    private func multipartRequest(chatId: Int64, filename: String, fileData: Data) -> URLRequest {
        let boundary = "RelayBack-\(UUID().uuidString)"
        var request = URLRequest(url: url(for: "sendDocument"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        append("\(chatId)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"document\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    // MARK: - Response handling

    /// Runs a request, validates the HTTP status and Telegram's `ok` flag, and returns the body.
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TelegramError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // A failed call may still carry Telegram's own reason — prefer it when present.
            if let reason = Self.apiDescription(in: data) {
                throw TelegramError.api(description: reason)
            }
            throw TelegramError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Extracts `ok`/`description` from an error body without failing if the shape is unexpected.
    private static func apiDescription(in data: Data) -> String? {
        struct Envelope: Decodable { let ok: Bool; let description: String? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              !envelope.ok else { return nil }
        return envelope.description ?? "Telegram API error"
    }
}
