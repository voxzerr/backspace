import BackspaceCore
import Foundation

/// A minimal Claude client, shaped for this app's three jobs: rewriting a
/// selection, completing a sentence, and answering a question.
///
/// Deliberately hand-rolled over `URLSession` rather than pulling in the SDK:
/// the app ships to end users, every dependency is something to notarise and
/// keep current, and we use a small enough slice of the API that the SDK's
/// surface would be mostly dead weight.
public actor ClaudeClient {

    /// The default model.
    ///
    /// Claude Opus 5 thinks by default, which is right for rewriting and for
    /// the ask panel. The latency-sensitive paths pass `effort: .low` rather
    /// than dropping to a smaller model — quality is the product here, and
    /// fast mode exists if raw speed becomes the constraint.
    public static let defaultModel = "claude-opus-5"

    public enum Effort: String, Sendable {
        case low, medium, high, xhigh, max
    }

    public struct Configuration: Sendable {
        public var apiKey: String
        public var model: String
        public var timeout: TimeInterval

        public init(
            apiKey: String,
            model: String = ClaudeClient.defaultModel,
            timeout: TimeInterval = 30
        ) {
            self.apiKey = apiKey
            self.model = model
            self.timeout = timeout
        }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case notConfigured
        case http(status: Int, message: String)
        case refused(category: String?)
        case malformedResponse

        public var description: String {
            switch self {
            case .notConfigured:
                return "Add your Anthropic API key in Settings to use the AI features."
            case .http(let status, let message):
                return "Claude returned \(status): \(message)"
            case .refused(let category):
                return "Claude declined that request\(category.map { " (\($0))" } ?? "")."
            case .malformedResponse:
                return "Couldn't read Claude's response."
            }
        }
    }

    private var configuration: Configuration?
    private let session: URLSession

    public init(configuration: Configuration? = nil) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Backspace/1.0 (macOS)"]
        self.session = URLSession(configuration: config)
    }

    public func configure(_ configuration: Configuration?) {
        self.configuration = configuration
    }

    public var isConfigured: Bool { configuration != nil }

    // MARK: - Requests

    /// One non-streaming turn. Used for rewrites and corrections, where the
    /// output is short and the caller wants it whole.
    public func complete(
        system: String,
        user: String,
        effort: Effort = .low,
        maxTokens: Int = 2048,
        cacheSystemPrompt: Bool = true
    ) async throws -> String {
        guard let configuration else { throw ClientError.notConfigured }

        // The system prompt is stable across every call of a given kind, so it
        // is the natural cache prefix. Opus 5's minimum cacheable prefix is 512
        // tokens — low enough that even these short instruction blocks qualify
        // once a voice profile is appended.
        var systemBlock: [String: Any] = ["type": "text", "text": system]
        if cacheSystemPrompt {
            systemBlock["cache_control"] = ["type": "ephemeral"]
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": maxTokens,
            "system": [systemBlock],
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort.rawValue],
            "messages": [["role": "user", "content": user]],
        ]

        let response = try await send(body, configuration: configuration)
        return try text(from: response)
    }

    /// A streaming turn, for the ask panel where the person is watching the
    /// answer arrive and a thirty-second blank pause is unacceptable.
    public func stream(
        system: String,
        user: String,
        effort: Effort = .high,
        maxTokens: Int = 8192
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let configuration = await self.configuration else {
                    continuation.finish(throwing: ClientError.notConfigured)
                    return
                }
                do {
                    let body: [String: Any] = [
                        "model": configuration.model,
                        "max_tokens": maxTokens,
                        "system": [[
                            "type": "text", "text": system,
                            "cache_control": ["type": "ephemeral"],
                        ]],
                        "thinking": ["type": "adaptive"],
                        "output_config": ["effort": effort.rawValue],
                        "stream": true,
                        "messages": [["role": "user", "content": user]],
                    ]
                    let request = try await self.request(body, configuration: configuration)
                    let (bytes, response) = try await self.session.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.finish(
                            throwing: ClientError.http(status: http.statusCode, message: "")
                        )
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any] else { continue }

                        if event["type"] as? String == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let chunk = delta["text"] as? String {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Plumbing

    private func request(
        _ body: [String: Any],
        configuration: Configuration
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(
        _ body: [String: Any],
        configuration: Configuration
    ) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: try request(body, configuration: configuration))

        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw ClientError.http(status: http.statusCode, message: message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse
        }
        return json
    }

    /// Pull the text out of a response.
    ///
    /// Checks `stop_reason` first. A refusal comes back as a perfectly normal
    /// HTTP 200 with an empty or partial `content`, so code that indexes
    /// `content[0]` without looking breaks on exactly the requests a person
    /// most wants an explanation for.
    private func text(from response: [String: Any]) throws -> String {
        if response["stop_reason"] as? String == "refusal" {
            let details = response["stop_details"] as? [String: Any]
            throw ClientError.refused(category: details?["category"] as? String)
        }
        guard let content = response["content"] as? [[String: Any]] else {
            throw ClientError.malformedResponse
        }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClientError.malformedResponse }
        return text
    }
}
