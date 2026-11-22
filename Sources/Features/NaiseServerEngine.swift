import Foundation

// Naise+ private FFmpeg server connector.
// Put this file in Sources/Features/NaiseServerEngine.swift.
enum NaiseServerEngine {
    // Cloudflare Quick Tunnel addresses change when the tunnel restarts.
    static let baseURL = "https://enjoy-damages-farm-colours.trycloudflare.com"
    static let apiKey = "" // Set only if NAISE_API_TOKEN is enabled on the PC.

    static func process(videoURL: URL, resolution: String, fps: Int) async throws -> URL {
        guard let endpoint = URL(string: baseURL + "/process") else {
            throw EngineError.message("Invalid server URL")
        }
        let boundary = "NaiseBoundary-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("upload")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw EngineError.message("Cannot create upload file")
        }
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        func write(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }
        func field(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write("\(value)\r\n")
        }
        try field("resolution", resolution)
        try field("fps", String(fps))
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"video\"; filename=\"clip.mov\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")

        let input = try FileHandle(forReadingFrom: videoURL)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        try handle.synchronize()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.timeoutInterval = 660

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 660
        config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.message("No HTTP response from server")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data.prefix(700), encoding: .utf8) ?? "Unknown error"
            throw EngineError.message("Server HTTP \(http.statusCode): \(detail)")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaisePlus_\(UUID().uuidString)").appendingPathExtension("mp4")
        try data.write(to: output, options: .atomic)
        return output
    }

    enum EngineError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(text) = self { return text }
            return "Server error"
        }
    }
}
