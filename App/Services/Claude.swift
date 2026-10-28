import Foundation

enum ClaudeError: LocalizedError {
    case noKey
    case badKey
    case noCredit
    case busy
    case offline
    case unreadable
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your Claude key in Settings first."
        case .badKey: "Your Claude key isn't working. Check it in Settings."
        case .noCredit: "Your Claude account is out of credit. Top it up at platform.claude.com."
        case .busy: "Claude is busy right now. Try again in a moment."
        case .offline: "No internet connection."
        case .unreadable: "Couldn't make sense of the answer. Try again."
        case .api(let message): message
        }
    }
}

/// Talks to Claude directly from the phone with Ian's own key.
enum Claude {
    static let sonnet = "claude-sonnet-5-5"
    static let haiku = "claude-haiku-5-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Calls

    /// Asks for an answer in a fixed JSON shape and decodes it.
    static func structured<T: Decodable>(_ type: T.Type, model: String, system: String, content: [[String: Any]],
                                         schema: [String: Any], effort: String = "medium",
                                         maxTokens: Int = 8000) async throws -> T {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema]
            ]
        ]
        let response = try await send(body)
        guard let data = text(of: response).data(using: .utf8) else { throw ClaudeError.unreadable }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ClaudeError.unreadable }
    }

    /// Opens the connection to Claude ahead of time (while Ian is still talking), so the real
    /// request skips the handshake. Costs nothing: no key is sent and no model runs.
    static func warmUp() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        Task.detached(priority: .utility) { _ = try? await session.data(for: request) }
    }

    /// A tiny call to check a key works.
    static func checkKey() async throws {
        let body: [String: Any] = [
            "model": haiku,
            "max_tokens": 64,
            "messages": [["role": "user", "content": "Reply with the word ok."]],
            "output_config": ["effort": "low"]
        ]
        _ = try await send(body)
    }

    // MARK: - Plumbing

    /// Sends a request, carrying on if Claude pauses mid-search, and retrying once if it's busy.
    static func send(_ initialBody: [String: Any]) async throws -> [String: Any] {
        guard let key = KeyStore.claudeKey else { throw ClaudeError.noKey }
        var body = initialBody
        let model = body["model"] as? String ?? sonnet

        for _ in 0..<5 {
            let response = try await post(body, key: key)
            Spend.record(usage: response["usage"] as? [String: Any], model: model)
            guard (response["stop_reason"] as? String) == "pause_turn" else { return response }
            // Hand the unfinished turn straight back so the server picks up where it left off.
            var messages = body["messages"] as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": response["content"] ?? []])
            body["messages"] = messages
        }
        throw ClaudeError.busy
    }

    private static func post(_ body: [String: Any], key: String, attempt: Int = 0) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where offlineCodes.contains(error.code) {
            throw ClaudeError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.offline }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""

        switch http.statusCode {
        case 200:
            return json
        case 401, 403:
            throw ClaudeError.badKey
        case 400 where message.localizedCaseInsensitiveContains("credit"):
            throw ClaudeError.noCredit
        case 429, 500...599:
            guard attempt < 2 else { throw ClaudeError.busy }
            try await Task.sleep(for: .seconds(Double(attempt + 1) * 3))
            return try await post(body, key: key, attempt: attempt + 1)
        default:
            throw ClaudeError.api(message.isEmpty ? "Claude returned an error (\(http.statusCode))." : message)
        }
    }

    static func text(of response: [String: Any]) -> String {
        let blocks = response["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
}

/// A running total of what Agenda has spent on Claude this month, shown in Settings.
enum Spend {
    private static let defaults = UserDefaults.standard

    private static var monthKey: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "spend-%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static var thisMonth: Double { defaults.double(forKey: monthKey) }

    static func record(usage: [String: Any]?, model: String) {
        guard let usage else { return }
        let (inPrice, outPrice) = model == Claude.haiku ? (0.10, 0.50) : (2.0, 10.0)
        func n(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
        let input = n("input_tokens") + n("cache_creation_input_tokens") * 1.25 + n("cache_read_input_tokens") * 0.1
        let searches = ((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? NSNumber)?.doubleValue ?? 0
        let dollars = input / 1_000_000 * inPrice + n("output_tokens") / 1_000_000 * outPrice + searches * 0.01
        defaults.set(thisMonth + dollars, forKey: monthKey)
    }
}
