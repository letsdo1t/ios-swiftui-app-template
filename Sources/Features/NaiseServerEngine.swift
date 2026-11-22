import Foundation

// Naise+ FFmpeg server connector: upload -> poll -> download.
enum NaiseServerEngine {
    // Update this URL whenever Cloudflare Quick Tunnel restarts.
    static let baseURL = "https://gift-mpeg-peoples-grace.trycloudflare.com"
    static let apiKey = ""

    private struct CreatedJob: Decodable {
        let job_id: String
    }

    private struct JobStatus: Decodable {
        let state: String
        let progress: Int
        let error: String?
    }

    static func process(videoURL: URL, resolution: String, fps: Int) async throws -> URL {
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
        try handle.close()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var upload = try request(path: "/process")
        upload.httpMethod = "POST"
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (createdData, createdResponse) = try await session.upload(for: upload, fromFile: bodyURL)
        try validate(createdResponse, data: createdData, expected: 202)
        let jobID = try JSONDecoder().decode(CreatedJob.self, from: createdData).job_id

        // A job can take several minutes; each poll is a short HTTP request.
        for _ in 0..<360 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let (data, response) = try await session.data(for: request(path: "/jobs/\(jobID)"))
            try validate(response, data: data, expected: 200)
            let status = try JSONDecoder().decode(JobStatus.self, from: data)
            switch status.state {
            case "ready":
                let (tempURL, downloadResponse) = try await session.download(
                    for: request(path: "/jobs/\(jobID)/download")
                )
                guard let http = downloadResponse as? HTTPURLResponse, http.statusCode == 200 else {
                    throw EngineError.message("Download failed")
                }
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NaisePlus_\(UUID().uuidString)")
                    .appendingPathExtension("mp4")
                try FileManager.default.moveItem(at: tempURL, to: output)
                return output
            case "failed":
                throw EngineError.message(status.error ?? "Video processing failed")
            case "queued", "processing":
                continue
            default:
                throw EngineError.message("Unknown job state: \(status.state)")
            }
        }
        throw EngineError.message("Job status polling timed out")
    }

    private static func request(path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw EngineError.message("Invalid server URL")
        }
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    private static func validate(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.message("No HTTP response from server")
        }
        guard http.statusCode == expected else {
            let detail = String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
            throw EngineError.message("Server HTTP \(http.statusCode): \(detail)")
        }
    }

    enum EngineError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(text) = self { return text }
            return "Server error"
        }
    }
}
