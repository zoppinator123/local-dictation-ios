import Foundation

enum DictationClient {
    struct Response: Decodable {
        var ok: Bool
        var text: String?
        var error: String?
        var listening: Bool?
        var armed: Bool?
    }

    static func start() async throws {
        let response = try await send(path: "/start", timeout: 8)
        guard response.ok else {
            throw SpeechCaptureError.engineStartFailed(response.error ?? "Session start failed")
        }
    }

    static func stop() async throws -> String {
        let response = try await send(path: "/stop", timeout: 12)
        guard response.ok else {
            throw SpeechCaptureError.engineStartFailed(response.error ?? "Session stop failed")
        }
        return response.text ?? ""
    }

    static func turnOff() async {
        _ = try? await send(path: "/off", timeout: 5)
    }

    private static func send(path: String, timeout: TimeInterval) async throws -> Response {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765\(path)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
