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

// MARK: - Naise+ matched visual design (iOS 17+)
// Visual reference: compact 3-screen mockup. No fabricated quality metrics.
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
    @State private var split: CGFloat = 0.5

    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? .white : Color(red: 0.09, green: 0.12, blue: 0.20) }
    private var secondary: Color { dark ? Color(red: 0.69, green: 0.72, blue: 0.79) : Color(red: 0.42, green: 0.46, blue: 0.57) }
    private var bg: Color { dark ? Color(red: 0.012, green: 0.014, blue: 0.027) : Color(red: 0.965, green: 0.970, blue: 0.986) }
    private var borderColor: Color { dark ? .white.opacity(0.16) : .white.opacity(0.99) }
    private var purple: Color { Color(red: 0.67, green: 0.23, blue: 0.96) }
    private var blue: Color { Color(red: 0.11, green: 0.36, blue: 0.98) }
    private var accent: Color { dark ? Color(red: 0.63, green: 0.50, blue: 1.0) : blue }
    private var actionGradient: LinearGradient {
        LinearGradient(colors: dark ? [purple, blue] : [Color(red: 0.17, green: 0.69, blue: 1), blue], startPoint: .leading, endPoint: .trailing)
    }
    private var glassFill: Color { dark ? Color(red: 0.066, green: 0.073, blue: 0.119) : Color.white.opacity(0.82) }
    private var inactiveFill: Color { dark ? Color(red: 0.17, green: 0.19, blue: 0.27) : Color(red: 0.91, green: 0.93, blue: 0.97) }

    // One visual canvas; sizes are calculated from the iPhone's actual safe area.
    // No scrolling on iPhone 15 Pro for the three primary screens.
    var body: some View {
        GeometryReader { geometry in
            let safeHeight = geometry.size.height
            let safeWidth = geometry.size.width
            let scale = min(1.0, safeWidth / 365.0, safeHeight / 695.0)
            VStack(spacing: 0) {
                Group {
                    switch page {
                    case 1: enhanceScreen
                    case 2: resultScreen
                    default: homeScreen
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                navigationBar
            }
            .frame(width: safeWidth / scale, height: safeHeight / scale)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: safeWidth, height: safeHeight, alignment: .topLeading)
            .background { appBackground.ignoresSafeArea() }
        }
        .foregroundStyle(ink)
        .tint(accent)
        .onChange(of: selected) { _, next in Task { await importVideo(next) } }
        .sheet(isPresented: $settings) { serverSettings }
        .sheet(item: $shareItem) { NaiseShareSheet(url: $0.url) }
        .alert("Naise+", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .alert("Video Details", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: { Text(clip.label) }
        .task { await resumeJobIfNeeded() }
    }

    private var appBackground: some View {
        ZStack {
            bg
            if dark {
                RadialGradient(colors: [purple.opacity(0.23), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 370)
                RadialGradient(colors: [blue.opacity(0.18), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: 320)
            } else {
                LinearGradient(colors: [.white, Color(red: 0.93, green: 0.95, blue: 0.99)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private func surface<Content: View>(radius: CGFloat = 15, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(dark
                                ? Color(red: 0.08, green: 0.09, blue: 0.14).opacity(0.82)
                                : Color.white.opacity(0.70))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(dark ? .white.opacity(0.15) : .white.opacity(0.94), lineWidth: 0.8)
            }
            .shadow(color: dark ? .black.opacity(0.18) : .gray.opacity(0.10), radius: 9, y: 3)
    }

    private var primaryGradient: LinearGradient {
        LinearGradient(colors: dark ? [purple, blue] : [Color(red: 0.13, green: 0.70, blue: 0.98), blue],
                       startPoint: .leading, endPoint: .trailing)
    }

    private func pillButton(_ title: String, symbol: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 42)
                .foregroundStyle(prominent ? Color.white : ink)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(
                        prominent ? AnyShapeStyle(primaryGradient) : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(dark ? 0.11 : 0.80)) }
        }.buttonStyle(.plain)
    }

    private func navCircle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.7))
        }.buttonStyle(.plain)
    }

    private func header(_ title: String) -> some View {
        HStack {
            navCircle("chevron.left") { page = page == 2 ? 1 : 0 }
            Spacer()
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            navCircle("ellipsis") { settings = true }
        }
        .frame(height: 38)
    }

    private var navigationBar: some View {
        HStack(spacing: 0) {
            navItem("house.fill", "Home", 0)
            navItem("sparkles", "Enhance", 1)
            navItem("play.rectangle", "Result", 2)
        }
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(dark ? 0.12 : 0.85)) }
        .padding(.horizontal, 13).padding(.bottom, 3)
    }

    private func navItem(_ icon: String, _ label: String, _ destination: Int) -> some View {
        Button { page = destination } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                Text(label).font(.system(size: 10, weight: page == destination ? .semibold : .regular))
            }
            .foregroundStyle(page == destination ? accent : secondary)
            .frame(maxWidth: .infinity).frame(height: 38)
        }.buttonStyle(.plain)
    }

    private func placeholderPhoto(height: CGFloat, result: Bool = false) -> some View {
        GeometryReader { g in
            ZStack {
                Image("NaiseSample")
                    .resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                if !result {
                    Image(systemName: "play.fill").font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 43, height: 43)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.35)))
                }
                VStack {
                    Spacer()
                    HStack {
                        Text(result ? "Sample only · No result yet" : "Sample preview · Import a video")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.black.opacity(0.60), in: Capsule())
                        Spacer()
                    }
                    .foregroundStyle(.white).padding(8)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func videoPreview(height: CGFloat, result: Bool = false) -> some View {
        Group {
            if let url = result ? outputURL : inputURL {
                VideoPlayer(player: playerFor(url))
                    .frame(height: height)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                placeholderPhoto(height: height, result: result)
            }
        }
    }

    private func detailTriple(_ values: [(String, String, String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 3) {
                    Image(systemName: values[i].0).font(.system(size: 13))
                    Text(values[i].1).font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Text(values[i].2).font(.system(size: 9)).foregroundStyle(secondary)
                }
                .frame(maxWidth: .infinity)
                if i < 2 { Rectangle().fill(.gray.opacity(0.20)).frame(width: 1, height: 32) }
            }
        }.padding(.vertical, 10)
    }

    private func tool(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 48)
        }
        .buttonStyle(.plain)
        .background { RoundedRectangle(cornerRadius: 12).fill(.thinMaterial) }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(dark ? 0.12 : 0.85)) }
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                (Text("Naise").foregroundColor(ink) + Text("+").foregroundColor(accent))
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                // Settings remains available, without adding logo or notification icon.
                navCircle("gearshape") { settings = true }
            }.frame(height: 38)

            Text("Enhance Your\nVideos with AI")
                .font(.system(size: 22, weight: .bold))
                .lineSpacing(-2).fixedSize(horizontal: false, vertical: true)
            Text("Smooth motion, natural color, original audio.")
                .font(.system(size: 10)).foregroundStyle(secondary)

            surface(radius: 17) {
                VStack(spacing: 5) {
                    ZStack(alignment: .topLeading) {
                        videoPreview(height: 206)
                        if let inputURL {
                            Text(inputURL.lastPathComponent)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(.white)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(7)
                        }
                    }
                    HStack {
                        Text(inputURL == nil ? "Choose a video to begin" : "Original video")
                        Spacer()
                        if inputURL != nil { Text("\(Int(clip.duration.rounded()))s") }
                    }.font(.system(size: 9)).foregroundStyle(secondary)
                }.padding(8)
            }
            HStack(spacing: 6) {
                PhotosPicker(selection: $selected, matching: .videos) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17))
                        Text("Replace").font(.system(size: 10))
                    }.frame(maxWidth: .infinity).frame(height: 48)
                }.buttonStyle(.plain).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(inputURL == nil || processing)
                tool("scissors", "Trim") { failure = "Trim belum tersedia dalam versi ini." }
                    .disabled(inputURL == nil)
                tool("info.circle", "Details") { showInfo = true }
                    .disabled(inputURL == nil)
            }
            surface(radius: 13) {
                detailTriple([
                    ("clock", inputURL == nil ? "—" : "\(Int(clip.duration.rounded()))s", "Duration"),
                    ("viewfinder", inputURL == nil ? "—" : "\(clip.width)×\(clip.height)", "Resolution"),
                    ("speedometer", inputURL == nil ? "—" : "\(Int(clip.fps.rounded())) FPS", "Frame Rate")
                ])
            }
            PhotosPicker(selection: $selected, matching: .videos) {
                Label(inputURL == nil ? "Import Video" : "Import Another Video", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 43)
                    .background(primaryGradient, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).disabled(processing)
            if inputURL != nil {
                pillButton("Open Enhance", symbol: "sparkles") { page = 1 }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private func settingsLine(_ symbol: String, title: String, subtitle: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 21)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(secondary)
            }
            Spacer(minLength: 3)
            trailing()
        }
        .padding(.horizontal, 10).frame(height: 46)
    }

    private func resolutionChip(_ title: String) -> some View {
        Button { resolution = title } label: {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(resolution == title ? Color.white : ink)
                .padding(.horizontal, 12).frame(height: 27)
                .background(resolution == title ? AnyShapeStyle(primaryGradient) : AnyShapeStyle(.thinMaterial), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var previewComparison: some View {
        ZStack(alignment: .bottom) {
            if inputURL == nil {
                GeometryReader { g in
                    let pos = g.size.width * split
                    ZStack(alignment: .leading) {
                        Image("NaiseSample").resizable().scaledToFill()
                            .frame(width: g.size.width, height: g.size.height).clipped()
                        Image("NaiseSample").resizable().scaledToFill()
                            .saturation(0.78)
                            .frame(width: g.size.width, height: g.size.height)
                            .mask(alignment: .leading) { Rectangle().frame(width: pos) }
                        Rectangle().fill(.white).frame(width: 2).offset(x: pos - 1)
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                            .background(.black.opacity(0.55), in: Circle())
                            .overlay(Circle().stroke(.white))
                            .offset(x: pos - 13.5)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        split = min(max(gesture.location.x / max(1, g.size.width), 0.05), 0.95)
                    })
                }
                .frame(height: 188)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                videoPreview(height: 188)
            }
            HStack {
                Text("Original")
                Spacer()
                Text(inputURL == nil ? "Sample" : (outputURL == nil ? "Preview" : "Enhanced"))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.black.opacity(0.30))
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var enhanceScreen: some View {
        VStack(spacing: 8) {
            header("Enhance")
            surface(radius: 16) {
                VStack(spacing: 5) {
                    previewComparison
                    HStack {
                        Text(inputURL?.lastPathComponent ?? "Sample preview · Import a video")
                        Spacer()
                        if inputURL != nil { Text(clip.label) }
                    }.lineLimit(1).font(.system(size: 9)).foregroundStyle(secondary)
                }.padding(7)
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(accent)
                Text("Enhancement Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }.padding(.top, 1)
            surface(radius: 13) {
                Menu {
                    ForEach(["WhatsApp", "Instagram", "TikTok", "YouTube"], id: \.self) { name in
                        Button(name) { platform = name }
                    }
                } label: {
                    settingsLine("square.stack", title: "Platform", subtitle: "Optimize for your target platform") {
                        Text(platform + " ›").font(.system(size: 10)).foregroundStyle(secondary)
                    }
                }.buttonStyle(.plain)
            }
            surface(radius: 13) {
                settingsLine("viewfinder", title: "Resolution", subtitle: "Output video quality") {
                    resolutionChip("1080p")
                    resolutionChip("4K")
                }
            }
            surface(radius: 13) {
                settingsLine("video", title: "Frame Rate", subtitle: "Smooth motion output") {
                    Text("60 FPS").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 27)
                        .background(primaryGradient, in: Capsule())
                }
            }
            surface(radius: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(accent)
                        Text("Adaptive Enhance").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(processing ? "\(progress)%" : "Auto")
                            .font(.system(size: 9)).foregroundStyle(secondary)
                    }
                    Label(clip.fps >= 59.5 ? "Source already 60 FPS — skip interpolation" : "Lower FPS → target smooth 60 FPS", systemImage: "checkmark")
                    Label("Natural color and original audio", systemImage: "checkmark")
                    Label("Preserve source HDR when supported", systemImage: "checkmark")
                    if processing {
                        ProgressView(value: Double(progress), total: 100)
                        Text(stage).font(.system(size: 9)).foregroundStyle(secondary)
                    }
                }.font(.system(size: 10)).padding(10)
            }
            if processing {
                pillButton("Stop checking status", symbol: "pause.circle") {
                    activeTask?.cancel(); activeTask = nil
                    processing = false
                    stage = "Job continues on PC; reopen to reconnect"
                }
            } else {
                pillButton("Enhance & Export", symbol: "sparkles", prominent: true) { beginProcessing() }
                    .disabled(inputURL == nil || serverURL.isEmpty)
            }
            if serverURL.isEmpty {
                Text("Add your HTTPS tunnel URL in Settings to export.")
                    .font(.system(size: 9)).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14)
    }

    private var resultScreen: some View {
        VStack(spacing: 8) {
            header("Result")
            surface(radius: 16) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().strokeBorder(primaryGradient, lineWidth: 2.5)
                            .frame(width: 52, height: 52)
                        Image(systemName: outputURL == nil ? "clock" : "checkmark")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(accent)
                    }
                    Text(outputURL == nil ? (processing ? "Enhancing Your Video" : "No completed video yet") : "Video Ready")
                        .font(.system(size: 14, weight: .semibold))
                    Text(outputURL == nil ? (processing ? "Processing \(progress)% — \(stage)" : "Your enhanced video will appear here after processing.") : "Your video has finished processing.")
                        .font(.system(size: 9)).foregroundStyle(secondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            // Mockup's fake 2.8× chart is replaced with real output information.
            surface(radius: 15) {
                VStack(spacing: 7) {
                    HStack {
                        Image(systemName: "chart.bar").foregroundStyle(accent)
                        Text("Video Details").font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    detailTriple([
                        ("viewfinder", outputURL == nil ? "—" : resolution, "Resolution"),
                        ("speedometer", outputURL == nil ? "—" : "60 FPS", "Output target"),
                        ("checkmark.seal", outputURL == nil ? "Pending" : "Ready", "Status")
                    ])
                }.padding(10)
            }
            surface(radius: 15) {
                VStack(spacing: 6) {
                    videoPreview(height: 170, result: true)
                    HStack {
                        Image(systemName: "film.stack").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outputURL?.lastPathComponent ?? "No enhanced video yet")
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(outputURL == nil ? "Process a clip to unlock Share and Save" : "Enhanced MP4 · Ready")
                                .font(.system(size: 9)).foregroundStyle(secondary)
                        }
                        Spacer()
                    }
                }.padding(8)
            }
            if let outputURL {
                pillButton("Share", symbol: "square.and.arrow.up", prominent: true) {
                    shareItem = NaiseShareItem(url: outputURL)
                }
                pillButton(savedPath == outputURL.path ? "Saved to Photos ✓" : "Save to Photos", symbol: "square.and.arrow.down") {
                    Task { await saveToPhotos(outputURL) }
                }.disabled(savedPath == outputURL.path)
            } else {
                pillButton("Go to Enhance", symbol: "sparkles", prominent: true) { page = 1 }
                pillButton("Save to Photos", symbol: "square.and.arrow.down") {}.disabled(true)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14)
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


// Decorative SAMPLE only, never misrepresented as footage or as a processed result.
private struct NaiseLandscapeSample: View {
    var showsPlay = true
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.28, green: 0.29, blue: 0.61), Color(red: 0.83, green: 0.49, blue: 0.68), Color(red: 0.24, green: 0.40, blue: 0.67)],
                    startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Color(red: 1, green: 0.77, blue: 0.67).opacity(0.7))
                    .frame(width: h * 0.56, height: h * 0.56)
                    .blur(radius: h * 0.16)
                    .offset(x: w * 0.24, y: -h * 0.20)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.76))
                    p.addLines([
                        CGPoint(x: w * 0.12, y: h * 0.58),
                        CGPoint(x: w * 0.24, y: h * 0.68),
                        CGPoint(x: w * 0.42, y: h * 0.27),
                        CGPoint(x: w * 0.59, y: h * 0.67),
                        CGPoint(x: w * 0.74, y: h * 0.42),
                        CGPoint(x: w, y: h * 0.76),
                        CGPoint(x: w, y: h), CGPoint(x: 0, y: h)
                    ])
                    p.closeSubpath()
                }.fill(Color(red: 0.14, green: 0.23, blue: 0.41))
                Path { p in
                    p.move(to: CGPoint(x: w * 0.32, y: h * 0.49))
                    p.addLines([CGPoint(x: w * 0.42, y: h * 0.27), CGPoint(x: w * 0.51, y: h * 0.49), CGPoint(x: w * 0.43, y: h * 0.41), CGPoint(x: w * 0.39, y: h * 0.44)])
                    p.closeSubpath()
                }.fill(.white.opacity(0.86))
                Rectangle().fill(Color(red: 0.17, green: 0.37, blue: 0.60).opacity(0.84))
                    .frame(height: h * 0.22).frame(maxHeight: .infinity, alignment: .bottom)
                LinearGradient(colors: [.clear, .black.opacity(0.34)], startPoint: .center, endPoint: .bottom)
                if showsPlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 43, height: 43)
                        .background(.black.opacity(0.46), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.46), lineWidth: 1) }
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }
}

#Preview { ContentView() }
