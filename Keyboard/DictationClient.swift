import Foundation

enum DictationClient {
    static let baseURL = URL(string: "http://127.0.0.1:18765")!

    struct Response: Decodable {
        var ok: Bool
        var text: String?
        var error: String?
        var listening: Bool?
    }

    static func health() async -> Bool {
        (try? await send(path: "/health", timeout: 0.6))?.ok == true
    }

    static func start() async throws {
        let response = try await send(path: "/start", timeout: 3)
        guard response.ok else {
            throw SpeechCaptureError.engineStartFailed(response.error ?? "Session start failed")
        }
    }

    static func stop() async throws -> String {
        let response = try await send(path: "/stop", timeout: 20)
        guard response.ok else {
            throw SpeechCaptureError.engineStartFailed(response.error ?? "Session stop failed")
        }
        return response.text ?? ""
    }

    private static func send(path: String, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765\(path)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
