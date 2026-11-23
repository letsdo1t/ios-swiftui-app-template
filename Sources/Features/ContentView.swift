import SwiftUI
import PhotosUI
import Photos
import AVKit
import UniformTypeIdentifiers

// Naise+ UI refresh (iOS 17+). Uses the existing FastAPI job API:
// POST /process -> 202 {job_id}; GET /jobs/{id}; GET /jobs/{id}/download.
// This is an app UI + client integration, not an implementation of RIFE/NVENC.

private struct NaisePickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return NaisePickedVideo(url: dest)
        }
    }
}

private struct NaiseJobCreated: Decodable { let job_id: String }
private struct NaiseJobStatus: Decodable {
    let state: String
    let progress: Int
    let stage: String?
    let error: String?
    let engine: String?
}
private struct NaiseClipInfo {
    var width = 0
    var height = 0
    var fps: Double = 0
    var duration: Double = 0
    var label: String { "\(width)×\(height) · \(Int(fps.rounded())) FPS · \(Int(duration.rounded()))s" }
}
private struct NaiseShareItem: Identifiable { let id = UUID(); let url: URL }
private struct NaiseShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum NaiseAPI {
    static func request(_ path: String, base: String, token: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else {
            throw NSError(domain: "Naise+", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set your current HTTPS tunnel URL in Settings."])
        }
        var req = URLRequest(url: url.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 120
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-API-Key") }
        return req
    }
    static func validated(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Naise+", code: 2, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard http.statusCode == expected else {
            let detail = String(data: data.prefix(260), encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "Naise+", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server \(http.statusCode): \(detail)"])
        }
    }
    static func upload(video: URL, resolution: String, base: String, token: String) async throws -> String {
        let boundary = "Naise-\(UUID().uuidString)"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let output = try FileHandle(forWritingTo: path)
        defer { try? output.close() }
        func write(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
        func field(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        try field("resolution", resolution)
        try field("fps", "60")  // Locked to 60 FPS.
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"input.mov\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: video)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        try output.synchronize()
        var req = try request("process", base: base, token: token, method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: path)
        try validated(response, data: data, expected: 202)
        return try JSONDecoder().decode(NaiseJobCreated.self, from: data).job_id
    }
    static func status(job: String, base: String, token: String) async throws -> NaiseJobStatus {
        let (data, response) = try await URLSession.shared.data(for: request("jobs/\(job)", base: base, token: token))
        try validated(response, data: data, expected: 200)
        return try JSONDecoder().decode(NaiseJobStatus.self, from: data)
    }
    static func download(job: String, base: String, token: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(for: request("jobs/\(job)/download", base: base, token: token))
        try validated(response, data: data, expected: 200)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("NaisePlus_\(UUID().uuidString).mp4")
        try data.write(to: dest, options: .atomic)
        return dest
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("naiseServerURL") private var serverURL = ""
    @AppStorage("naiseServerToken") private var serverToken = ""
    @AppStorage("naiseLastJobID") private var lastJobID = ""
    @AppStorage("naiseLastJobBase") private var lastJobBase = ""
    @State private var selected: PhotosPickerItem?
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var clip = NaiseClipInfo()
    @State private var platform = "WhatsApp"
    @State private var resolution = "1080p"
    @State private var page = 0
    @State private var processing = false
    @State private var progress = 0
    @State private var stage = "Ready"
    @State private var failure: String?
    @State private var settings = false
    @State private var shareItem: NaiseShareItem?
    @State private var savedPath: String?
    @State private var player: AVPlayer?
    @State private var activeTask: Task<Void, Never>?
    @State private var noiseReduction = false
    @State private var showInfo = false

    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? .white : Color(red: 0.09, green: 0.10, blue: 0.13) }
    private var secondary: Color { ink.opacity(0.62) }
    private var bg: Color { dark ? Color(red: 0.015, green: 0.015, blue: 0.02) : Color(red: 0.95, green: 0.96, blue: 0.98) }
    private var card: Color { dark ? Color(white: 0.12) : .white }
    private var line: Color { ink.opacity(dark ? 0.16 : 0.08) }
    private let purple = Color(red: 0.57, green: 0.30, blue: 0.95)
    private let blue = Color(red: 0.23, green: 0.36, blue: 0.98)

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 690
            VStack(spacing: 0) {
                Group {
                    switch page {
                    case 1: enhance(compact: compact)
                    case 2: result(compact: compact)
                    default: home(compact: compact)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 14)
            .padding(.top, compact ? 4 : 8)
            .padding(.bottom, 6)
            .background(bg.ignoresSafeArea())
        }
        .foregroundStyle(ink)
        .onChange(of: selected) { _, next in Task { await importVideo(next) } }
        .sheet(isPresented: $settings) { serverSettings }
        .sheet(item: $shareItem) { NaiseShareSheet(url: $0.url) }
        .alert("Naise+", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .alert("Video Details", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: { Text(clip.label) }
        .task { await resumeJobIfNeeded() }
    }

    private func glass<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(line, lineWidth: 1))
    }
    private func title(_ name: String) -> some View {
        HStack {
            if page > 0 {
                Button { page = page == 2 ? 1 : 0 } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 38, height: 38).background(card, in: Circle()) }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(name).font(.system(size: 18, weight: .bold))
            Spacer()
            Button { settings = true } label: { Image(systemName: "ellipsis").font(.headline).frame(width: 38, height: 38).background(card, in: Circle()) }
                .buttonStyle(.plain)
        }
        .frame(height: 44)
    }
    private func buttonStyle(_ caption: String, icon: String, action: @escaping () -> Void, highlighted: Bool = false) -> some View {
        Button(action: action) {
            Label(caption, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 45)
                .foregroundStyle(highlighted ? .white : ink)
                .background {
                    RoundedRectangle(cornerRadius: 15).fill(highlighted ? AnyShapeStyle(LinearGradient(colors: [purple, blue], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func tabs() -> some View {
        HStack {
            tab("house.fill", "Home", page: 0)
            tab("sparkles", "Enhance", page: 1)
            tab("play.rectangle", "Result", page: 2)
            Button { settings = true } label: { VStack(spacing: 3) { Image(systemName: "gearshape"); Text("Settings") }.font(.system(size: 10)).frame(maxWidth: .infinity) }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(line, lineWidth: 1))
    }
    private func tab(_ icon: String, _ name: String, page target: Int) -> some View {
        Button { page = target } label: {
            VStack(spacing: 3) { Image(systemName: icon).font(.system(size: 17)); Text(name).font(.system(size: 10)) }
                .foregroundStyle(page == target ? (dark ? Color.white : Color.black) : secondary)
                .frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }
    private func clipRow() -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film.stack.fill").font(.title3).frame(width: 35, height: 35).background(ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(inputURL?.lastPathComponent ?? "No video selected").lineLimit(1).font(.system(size: 13, weight: .semibold))
                Text(inputURL == nil ? "Import to begin" : clip.label).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { showInfo = true } label: { Image(systemName: "info.circle").frame(width: 30, height: 30) }
                .disabled(inputURL == nil).buttonStyle(.plain)
        }.padding(11)
    }
    private func gauge(_ value: Int, size: CGFloat) -> some View {
        ZStack {
            Circle().trim(from: 0.05, to: 0.45).rotationEffect(.degrees(90))
                .stroke(ink.opacity(0.14), style: StrokeStyle(lineWidth: 9, lineCap: .round)).frame(width: size, height: size)
            Circle().trim(from: 0.05, to: 0.05 + 0.4 * CGFloat(max(0, min(100, value))) / 100)
                .rotationEffect(.degrees(90))
                .stroke(dark ? Color.white : Color.gray, style: StrokeStyle(lineWidth: 9, lineCap: .round)).frame(width: size, height: size)
            VStack(spacing: 2) {
                Text(processing ? "Enhancing" : "Processing").font(.caption2).foregroundStyle(secondary)
                Text("\(value)%").font(.system(size: 32, weight: .semibold, design: .rounded))
                Text(stage).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }.offset(y: 21)
        }.frame(height: size * 0.62).frame(maxWidth: .infinity).clipped()
    }
    private func infoCell(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14))
            Text(value).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.system(size: 9)).foregroundStyle(secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    private func home(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Naise+").font(.system(size: 23, weight: .bold))
                    Text("AI Video Enhancer").font(.caption).foregroundStyle(secondary)
                }
                Spacer()
                Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle()) }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                ForEach(["WhatsApp", "Instagram", "TikTok", "YouTube"], id: \.self) { p in
                    Button { platform = p } label: {
                        Text(p).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(platform == p ? (dark ? Color.black : Color.white) : ink)
                            .background(platform == p ? (dark ? Color.white : Color.gray) : card, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            glass {
                VStack(spacing: 6) {
                    HStack { Image(systemName: "sparkles"); Text("AI Enhancer").font(.headline); Spacer(); Text("60 FPS").font(.caption).foregroundStyle(secondary) }
                    clipRow()
                    gauge(progress, size: compact ? 158 : 190)
                    ProgressView(value: Double(progress), total: 100).tint(dark ? .white : .gray)
                    HStack(spacing: 6) {
                        infoCell("rectangle.expand.vertical", inputURL == nil ? "—" : resolution, "Output")
                        infoCell("speedometer", "60 FPS", "Locked")
                        infoCell("clock", inputURL == nil ? "—" : "\(Int(clip.duration))s", "Duration")
                        Button { showInfo = true } label: { infoCell("scissors", "Details", "Video") }.buttonStyle(.plain)
                    }
                }.padding(compact ? 10 : 14)
            }
            HStack(spacing: 9) {
                glass {
                    HStack { Image(systemName: "sun.max"); Text("Preserve HDR").font(.caption2); Spacer() }.padding(13)
                }
                glass {
                    Toggle("Noise Reduce", isOn: $noiseReduction).font(.caption2).padding(10)
                        .disabled(true) // Pending backend support; never claim this works yet.
                }
            }
            PhotosPicker(selection: $selected, matching: .videos) {
                Label(inputURL == nil ? "Import Video" : "Replace Video", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 46)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(line))
            }.buttonStyle(.plain).disabled(processing)
            buttonStyle("Open Enhance", icon: "sparkles", action: { page = 1 }, highlighted: true)
                .disabled(inputURL == nil)
            Spacer(minLength: 1)
            tabs()
        }
    }
    private func enhance(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 10) {
            title("Enhance Video")
            glass {
                VStack(spacing: 9) {
                    HStack { Text("Original"); Spacer(); Text(outputURL == nil ? "Preview" : "Enhanced") }.font(.caption).foregroundStyle(secondary)
                    if let url = outputURL ?? inputURL {
                        VideoPlayer(player: playerFor(url))
                            .frame(height: compact ? 152 : 190)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                    } else {
                        ZStack { Rectangle().fill(ink.opacity(0.05)); Label("Import a video first", systemImage: "play.rectangle").foregroundStyle(secondary) }
                            .frame(height: compact ? 152 : 190).clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    HStack { Text(inputURL?.lastPathComponent ?? "No clip").lineLimit(1); Spacer(); Text(clip.label).lineLimit(1) }
                        .font(.system(size: 10)).foregroundStyle(secondary)
                }.padding(10)
            }
            glass {
                VStack(spacing: compact ? 9 : 13) {
                    HStack { Label("Adaptive Enhance", systemImage: "sparkles").font(.headline); Spacer(); Text("Auto").foregroundStyle(secondary) }
                    gauge(progress, size: compact ? 128 : 155)
                    HStack(spacing: 8) {
                        ForEach(["1080p", "4K"], id: \.self) { option in
                            Button { resolution = option } label: {
                                Text(option).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .foregroundStyle(resolution == option ? (dark ? Color.black : Color.white) : ink)
                                    .background(resolution == option ? (dark ? Color.white : Color.gray) : card, in: Capsule())
                            }.buttonStyle(.plain).disabled(processing)
                        }
                        Text("60 FPS").font(.system(size: 13, weight: .bold)).padding(.horizontal, 13).padding(.vertical, 11)
                            .background(card, in: Capsule())
                    }
                    HStack(spacing: 10) {
                        Label("Natural color", systemImage: "camera.filters").font(.caption2)
                        Spacer()
                        Label("HDR if supported", systemImage: "sun.max").font(.caption2)
                    }.foregroundStyle(secondary)
                    if processing { ProgressView(value: Double(progress), total: 100); Text(stage).font(.caption2).foregroundStyle(secondary) }
                }.padding(compact ? 10 : 13)
            }
            if processing {
                buttonStyle("Stop checking on this device", icon: "pause.circle") {
                    activeTask?.cancel(); activeTask = nil
                    processing = false
                    stage = "Job continues on PC; reopen to reconnect"
                    // This stops polling only; backend has no cancel endpoint.
                }
            } else {
                buttonStyle("Enhance & Export", icon: "sparkles", action: { beginProcessing() }, highlighted: true)
                    .disabled(inputURL == nil || serverURL.isEmpty)
            }
            if serverURL.isEmpty { Text("Add your HTTPS tunnel URL in Settings first.").font(.caption2).foregroundStyle(secondary) }
            Spacer(minLength: 1)
            tabs()
        }
    }
    private func result(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 11) {
            title("Result")
            glass {
                VStack(spacing: 6) {
                    Image(systemName: outputURL == nil ? "clock" : "checkmark.circle").font(.system(size: 42)).padding(.top, 8)
                    Text(outputURL == nil ? "No completed video yet" : "Video Ready").font(.system(size: 18, weight: .bold))
                    Text(outputURL == nil ? "Enhance a video first." : "Preview, share or save the exported clip.")
                        .font(.caption2).foregroundStyle(secondary).padding(.bottom, 8)
                }.frame(maxWidth: .infinity).padding(12)
            }
            if let outputURL {
                VideoPlayer(player: playerFor(outputURL))
                    .frame(height: compact ? 165 : 210)
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                HStack(spacing: 8) {
                    infoCell("rectangle.expand.vertical", resolution, "Output")
                    infoCell("gauge", "60 FPS", "Target")
                    infoCell("checkmark.seal", "Ready", "Job")
                }
                glass { HStack { Image(systemName: "doc.fill"); Text(outputURL.lastPathComponent).lineLimit(1); Spacer() }.font(.caption).padding(12) }
                buttonStyle("Share", icon: "square.and.arrow.up", action: { shareItem = NaiseShareItem(url: outputURL) }, highlighted: true)
                buttonStyle(savedPath == outputURL.path ? "Saved to Photos ✓" : "Save to Photos", icon: "square.and.arrow.down") {
                    Task { await saveToPhotos(outputURL) }
                }.disabled(savedPath == outputURL.path)
            } else {
                buttonStyle("Go to Enhance", icon: "sparkles", action: { page = 1 }, highlighted: true)
            }
            Spacer(minLength: 1)
            tabs()
        }
    }
    // Player intentionally stays within app; recreate only when URL changes.
    private func playerFor(_ url: URL) -> AVPlayer {
        if let player, let current = (player.currentItem?.asset as? AVURLAsset)?.url, current == url { return player }
        let created = AVPlayer(url: url)
        DispatchQueue.main.async { self.player = created }
        return created
    }
    private var serverSettings: some View {
        NavigationStack {
            Form {
                Section("Private backend") {
                    TextField("https://your-tunnel.trycloudflare.com", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("X-API-Key (optional)", text: $serverToken)
                    Text("Quick Tunnel addresses can change when restarted. Only use a server you control.").font(.caption)
                }
                Section("Processing") {
                    Text("Output 60 FPS. RIFE/NVENC and HDR behavior depend on the Windows backend, not the UI.")
                    if !lastJobID.isEmpty { Text("Last job: \(lastJobID)").font(.caption2).textSelection(.enabled) }
                    Button("Reconnect to last job") { settings = false; Task { await resumeJobIfNeeded() } }
                }
            }.navigationTitle("Naise+ Settings").toolbar { Button("Done") { settings = false } }
        }
    }
    @MainActor private func importVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            let picked = try await item.loadTransferable(type: NaisePickedVideo.self)
            guard let url = picked?.url else { throw NSError(domain: "Naise+", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not import clip"] ) }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "Naise+", code: 4, userInfo: [NSLocalizedDescriptionKey: "Video track missing"] ) }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rotated = CGRect(origin: .zero, size: natural).applying(transform)
            let rate = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration)
            clip = NaiseClipInfo(width: Int(abs(rotated.width)), height: Int(abs(rotated.height)), fps: Double(rate), duration: max(0, CMTimeGetSeconds(duration)))
            inputURL = url; outputURL = nil; savedPath = nil; player = nil; progress = 0; stage = "Ready"
            page = 1
        } catch { failure = error.localizedDescription }
    }
    private func beginProcessing() {
        guard let inputURL, !processing else { return }
        activeTask?.cancel()
        processing = true; progress = 0; stage = "Uploading"; outputURL = nil; savedPath = nil
        let base = serverURL; let token = serverToken; let selectedResolution = resolution
        activeTask = Task {
            do {
                let job = try await NaiseAPI.upload(video: inputURL, resolution: selectedResolution, base: base, token: token)
                await MainActor.run { lastJobID = job; lastJobBase = base }
                try await poll(job: job, base: base, token: token)
            } catch is CancellationError {
                await MainActor.run { processing = false }
            } catch {
                await MainActor.run { failure = error.localizedDescription; processing = false; stage = "Failed" }
            }
        }
    }
    private func poll(job: String, base: String, token: String) async throws {
        while !Task.isCancelled {
            let status = try await NaiseAPI.status(job: job, base: base, token: token)
            await MainActor.run { progress = status.progress; stage = status.stage ?? status.state }
            if status.state == "ready" {
                let url = try await NaiseAPI.download(job: job, base: base, token: token)
                await MainActor.run { outputURL = url; player = nil; processing = false; progress = 100; stage = "Ready"; page = 2; lastJobID = ""; lastJobBase = "" }
                return
            }
            if status.state == "failed" {
                throw NSError(domain: "Naise+", code: 5, userInfo: [NSLocalizedDescriptionKey: status.error ?? "Server failed processing video"])
            }
            try await Task.sleep(for: .seconds(2))
        }
    }
    @MainActor private func resumeJobIfNeeded() async {
        guard !lastJobID.isEmpty, !lastJobBase.isEmpty, !processing else { return }
        let job = lastJobID
        let base = lastJobBase
        let token = serverToken
        processing = true; stage = "Reconnecting"; page = 1
        do { try await poll(job: job, base: base, token: token) }
        catch {
            processing = false
            failure = "Cannot reconnect: \(error.localizedDescription). Check that the same backend and tunnel are still running."
        }
    }
    @MainActor private func saveToPhotos(_ url: URL) async {
        guard savedPath != url.path else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            failure = "Add NSPhotoLibraryAddUsageDescription to Info.plist or use Share to save manually."
            return
        }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else { failure = "Allow Add Photos access or use Share."; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            savedPath = url.path
        } catch { failure = error.localizedDescription }
    }
}

#Preview { ContentView() }
