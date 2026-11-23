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

// MARK: - Naise+ 2026 visual design
// Light: silver / white frosted glass; Dark: black / white dark glass.
// Functional exports remain 1080p / 4K at locked 60 FPS.
private struct NaiseSemiArc: Shape {
    var fraction: CGFloat
    func path(in rect: CGRect) -> Path {
        var result = Path()
        let amount = max(0, min(1, fraction))
        let radius = min(rect.width / 2 - 6, rect.height - 7)
        let center = CGPoint(x: rect.midX, y: rect.maxY - 5)
        let steps = max(1, Int(100 * amount))
        for step in 0...steps {
            let angle = Double.pi * (1 + Double(step) / Double(steps) * Double(amount))
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            if step == 0 { result.move(to: point) } else { result.addLine(to: point) }
        }
        return result
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
    private var ink: Color { dark ? .white : Color(red: 0.10, green: 0.12, blue: 0.17) }
    private var secondary: Color { dark ? Color(white: 0.70) : Color(red: 0.38, green: 0.42, blue: 0.50) }
    private var bg: Color { dark ? Color(red: 0.012, green: 0.014, blue: 0.022) : Color(red: 0.945, green: 0.956, blue: 0.977) }
    private var edge: Color { dark ? Color.white.opacity(0.16) : Color.white.opacity(0.92) }
    private var purple: Color { Color(red: 0.53, green: 0.28, blue: 0.98) }
    private var blue: Color { Color(red: 0.18, green: 0.37, blue: 0.97) }
    private var actionGradient: LinearGradient {
        LinearGradient(colors: dark ? [purple, blue] : [Color(red: 0.55, green: 0.59, blue: 0.68), Color(red: 0.34, green: 0.38, blue: 0.47)], startPoint: .leading, endPoint: .trailing)
    }
    private var highlight: Color { dark ? Color(red: 0.68, green: 0.52, blue: 1) : Color(red: 0.39, green: 0.44, blue: 0.57) }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 770
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
            .padding(.horizontal, 15)
            .padding(.top, compact ? 3 : 8)
            .padding(.bottom, 5)
            .background {
                bg.ignoresSafeArea()
                if !dark {
                    LinearGradient(colors: [.white.opacity(0.45), .clear, Color(red: 0.85, green: 0.88, blue: 0.94).opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                }
            }
        }
        .foregroundStyle(ink)
        .tint(highlight)
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

    private func glass<Content: View>(radius: CGFloat = 19, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(dark ? Color.white.opacity(0.035) : Color.white.opacity(0.37))
                    }
            }
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(edge, lineWidth: 1) }
            .shadow(color: dark ? .black.opacity(0.25) : Color(red: 0.35, green: 0.39, blue: 0.50).opacity(0.10), radius: 11, y: 4)
    }

    private func pageHeader(_ title: String) -> some View {
        HStack {
            Button { page = page == 2 ? 1 : 0 } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40).background(.thinMaterial, in: Circle())
            }.buttonStyle(.plain)
            Spacer()
            Text(title).font(.system(size: 18, weight: .bold))
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40).background(.thinMaterial, in: Circle())
            }.buttonStyle(.plain)
        }.frame(height: 44)
    }

    private func action(_ label: String, symbol: String, emphasized: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(label, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 45)
                .foregroundStyle(emphasized ? Color.white : ink)
                .background {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(emphasized ? AnyShapeStyle(actionGradient) : AnyShapeStyle(.thinMaterial))
                }
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(edge.opacity(emphasized ? 0.48 : 0.85)) }
        }.buttonStyle(.plain)
    }

    private func bottomBar() -> some View {
        HStack(spacing: 0) {
            tab("house.fill", "Home", 0)
            tab("sparkles", "Enhance", 1)
            tab("play.rectangle", "Result", 2)
            Button { settings = true } label: {
                VStack(spacing: 3) {
                    Image(systemName: "gearshape").font(.system(size: 17))
                    Text("Settings").font(.system(size: 10))
                }.frame(maxWidth: .infinity).foregroundStyle(secondary)
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay { Capsule().stroke(edge, lineWidth: 1) }
    }

    private func tab(_ symbol: String, _ title: String, _ index: Int) -> some View {
        Button { page = index } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.system(size: 10))
            }.frame(maxWidth: .infinity).foregroundStyle(page == index ? ink : secondary)
        }.buttonStyle(.plain)
    }

    private func stat(_ symbol: String, value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 15))
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func meter(_ value: Int, size: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            NaiseSemiArc(fraction: 1)
                .stroke(ink.opacity(0.17), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            NaiseSemiArc(fraction: CGFloat(max(0, min(100, value))) / 100)
                .stroke(highlight, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            VStack(spacing: 2) {
                Text(processing ? "Processing" : "Ready").font(.system(size: 11)).foregroundStyle(secondary)
                Text(processing ? "\(value)%" : "60 FPS").font(.system(size: 27, weight: .bold, design: .rounded))
                Text(processing ? stage : "Output locked").font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }.padding(.bottom, 1)
        }
        .frame(width: size, height: size * 0.54)
        .frame(maxWidth: .infinity)
    }

    private func videoPanel(height: CGFloat, resultVideo: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(dark ? Color(white: 0.09) : Color(red: 0.83, green: 0.85, blue: 0.90))
            if let video = resultVideo ? outputURL : (outputURL ?? inputURL) {
                VideoPlayer(player: playerFor(video))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 29))
                    Text(resultVideo ? "No result available" : "Import a video to preview")
                        .font(.system(size: 12, weight: .medium))
                }.foregroundStyle(secondary)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private func platformSelector() -> some View {
        HStack(spacing: 6) {
            ForEach(["WhatsApp", "Instagram", "TikTok", "YouTube"], id: \.self) { option in
                Button { platform = option } label: {
                    Text(option).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(platform == option ? (dark ? Color.black : Color.white) : ink)
                        .background {
                            Capsule().fill(platform == option ? AnyShapeStyle(dark ? Color.white : Color.gray) : AnyShapeStyle(.thinMaterial))
                        }
                }.buttonStyle(.plain)
            }
        }
    }

    private func home(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Naise+").font(.system(size: 24, weight: .bold))
                    Text("AI Video Enhancer").font(.system(size: 12)).foregroundStyle(secondary)
                }
                Spacer()
                Button { settings = true } label: { Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 40, height: 40).background(.thinMaterial, in: Circle()) }
                    .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Enhance Your Videos").font(.system(size: compact ? 19 : 21, weight: .bold))
                Text("Smooth motion. Preserve natural color.").font(.system(size: 11)).foregroundStyle(secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            platformSelector()
            glass {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("AI Enhancer", systemImage: "sparkles").font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text(processing ? "\(progress)%" : "60 FPS").font(.caption).foregroundStyle(secondary)
                    }
                    videoPanel(height: compact ? 160 : 190)
                    HStack {
                        Text(inputURL?.lastPathComponent ?? "No video selected").lineLimit(1)
                        Spacer(minLength: 3)
                        if inputURL != nil { Text(clip.label).lineLimit(1) }
                    }.font(.system(size: 10)).foregroundStyle(secondary)
                    if processing {
                        ProgressView(value: Double(progress), total: 100).tint(highlight)
                        Text(stage).font(.caption2).foregroundStyle(secondary).lineLimit(1)
                    }
                }.padding(11)
            }
            HStack(spacing: 7) {
                PhotosPicker(selection: $selected, matching: .videos) {
                    stat("arrow.triangle.2.circlepath", value: "Replace", label: "Video")
                }.buttonStyle(.plain).disabled(processing)
                Button { showInfo = true } label: { stat("info.circle", value: "Details", label: "Clip") }
                    .buttonStyle(.plain).disabled(inputURL == nil)
                stat("clock", value: inputURL == nil ? "—" : "\(Int(clip.duration))s", label: "Duration")
                stat("speedometer", value: "60 FPS", label: "Output")
            }
            PhotosPicker(selection: $selected, matching: .videos) {
                Label(inputURL == nil ? "Import Video" : "Import Another Video", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 45)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15))
                    .overlay { RoundedRectangle(cornerRadius: 15).stroke(edge) }
            }.buttonStyle(.plain).disabled(processing)
            action("Open Enhance", symbol: "sparkles", emphasized: true) { page = 1 }.disabled(inputURL == nil)
            Spacer(minLength: 0)
            bottomBar()
        }
    }

    private func enhance(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            pageHeader("Enhance Video")
            glass {
                VStack(spacing: 6) {
                    HStack {
                        Text("Original")
                        Spacer()
                        Text(outputURL == nil ? "Preview" : "Enhanced")
                    }.font(.system(size: 11)).foregroundStyle(secondary)
                    videoPanel(height: compact ? 167 : 195)
                    HStack {
                        Text(inputURL?.lastPathComponent ?? "No clip selected").lineLimit(1)
                        Spacer()
                        Text(clip.label).lineLimit(1)
                    }.font(.system(size: 10)).foregroundStyle(secondary)
                }.padding(10)
            }
            HStack {
                Image(systemName: "sparkles").foregroundStyle(highlight)
                Text("Enhancement Settings").font(.system(size: 14, weight: .bold))
                Spacer()
            }.padding(.horizontal, 4)
            glass(radius: 15) {
                HStack {
                    Label("Platform", systemImage: "square.stack")
                    Spacer()
                    Text(platform).foregroundStyle(secondary)
                }.font(.system(size: 12, weight: .medium)).padding(13)
            }
            glass(radius: 15) {
                HStack(spacing: 10) {
                    Label("Resolution", systemImage: "4k.tv").font(.system(size: 12, weight: .medium))
                    Spacer()
                    ForEach(["1080p", "4K"], id: \.self) { option in
                        Button { resolution = option } label: {
                            Text(option).font(.system(size: 12, weight: .bold))
                                .foregroundStyle(resolution == option ? (dark ? Color.white : Color.white) : ink)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background {
                                    Capsule().fill(resolution == option ? AnyShapeStyle(actionGradient) : AnyShapeStyle(.thinMaterial))
                                }
                        }.buttonStyle(.plain).disabled(processing)
                    }
                }.padding(9)
            }
            glass(radius: 15) {
                HStack {
                    Label("Frame Rate", systemImage: "film.stack").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("60 FPS · Locked").font(.system(size: 12, weight: .semibold)).foregroundStyle(highlight)
                }.padding(13)
            }
            glass {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(highlight)
                        Text("Adaptive Enhance").font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text("Auto").font(.caption).foregroundStyle(secondary)
                    }
                    if processing {
                        meter(progress, size: compact ? 125 : 142)
                        ProgressView(value: Double(progress), total: 100).tint(highlight)
                    } else {
                        Label("Natural color & original audio", systemImage: "checkmark.circle")
                            .font(.system(size: 11)).foregroundStyle(secondary)
                        Label("HDR preserved when supported by backend", systemImage: "sun.max")
                            .font(.system(size: 11)).foregroundStyle(secondary)
                    }
                }.padding(12)
            }
            if processing {
                action("Stop checking on this device", symbol: "pause.circle") {
                    activeTask?.cancel(); activeTask = nil
                    processing = false
                    stage = "Job continues on PC; reopen to reconnect"
                    // Backend has no cancel endpoint; this stops polling only.
                }
            } else {
                action("Enhance & Export", symbol: "sparkles", emphasized: true) { beginProcessing() }
                    .disabled(inputURL == nil || serverURL.isEmpty)
            }
            if serverURL.isEmpty {
                Text("Add your HTTPS tunnel URL in Settings first.")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            bottomBar()
        }
    }

    private func result(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            pageHeader("Result")
            glass {
                VStack(spacing: 8) {
                    if outputURL == nil {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 38)).foregroundStyle(secondary)
                        Text("No completed video yet").font(.system(size: 17, weight: .bold))
                        Text("Enhance a video first.").font(.caption2).foregroundStyle(secondary)
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: 31)).foregroundStyle(highlight)
                        Text("Video Ready").font(.system(size: 17, weight: .bold))
                        Text("Preview your export before saving.").font(.caption2).foregroundStyle(secondary)
                    }
                }.frame(maxWidth: .infinity).padding(14)
            }
            if let outputURL {
                glass { videoPanel(height: compact ? 190 : 225, resultVideo: true).padding(9) }
                HStack(spacing: 8) {
                    stat("4k.tv", value: resolution, label: "Resolution")
                    stat("speedometer", value: "60 FPS", label: "Target")
                    stat("checkmark.seal", value: "Ready", label: "Status")
                }
                glass {
                    HStack(spacing: 9) {
                        Image(systemName: "film.stack.fill").foregroundStyle(highlight)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(outputURL.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("Exported video · MP4").font(.system(size: 10)).foregroundStyle(secondary)
                        }
                        Spacer()
                    }.padding(12)
                }
                action("Share", symbol: "square.and.arrow.up", emphasized: true) {
                    shareItem = NaiseShareItem(url: outputURL)
                }
                action(savedPath == outputURL.path ? "Saved to Photos ✓" : "Save to Photos", symbol: "square.and.arrow.down") {
                    Task { await saveToPhotos(outputURL) }
                }.disabled(savedPath == outputURL.path)
            } else {
                action("Go to Enhance", symbol: "sparkles", emphasized: true) { page = 1 }
            }
            Spacer(minLength: 0)
            bottomBar()
        }
    }

    // Reuse a single player when possible. Preview always uses the actual video.
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
