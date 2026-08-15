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
        do {
            let response = try await send(path: "/start", timeout: 8)
            guard response.ok else {
                throw SpeechCaptureError.engineStartFailed(response.error ?? "Session start failed")
            }
        } catch {
            // The host can open the clip but its HTTP response can be delayed while
            // iOS transitions the containing app to background. Verify before failing.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let health = try? await send(path: "/health", timeout: 3),
               health.ok, health.listening == true {
                return
            }
            let ns = error as NSError
            throw SpeechCaptureError.engineStartFailed("Session connection failed (\(ns.domain) \(ns.code)): \(error.localizedDescription)")
        }
    }

    static func stop() async throws -> String {
        let response = try await send(path: "/stop", timeout: 12)
        guard response.ok else {
            throw SpeechCaptureError.engineStartFailed(response.error ?? "Session stop failed")
        }
        return response.text ?? ""
    }

    static func turnOff() async -> Bool {
        guard let response = try? await send(path: "/off", timeout: 5) else { return false }
        return response.ok
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
