import SwiftUI
import PhotosUI
import Photos
import AVKit
import UniformTypeIdentifiers

// Naise+ v10 UI (iOS 17+). Uses the existing FastAPI job API:
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
    var aspectRatio: CGFloat { width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 16.0 / 9.0 }
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
    static func upload(video: URL, resolution: String, fps: Int, base: String, token: String) async throws -> String {
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
        try field("fps", String(fps))
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

// MARK: - Naise+ v13 UI: matches the Light / Dark poster + web mockup polish (iOS 17+)
// v13: scales to fill every iPhone (no empty gap at the bottom), flexible video/preview height,
//      separate setting cards + separate result tiles like the mockup, Enhance & Export always full colour.
// v12: progress-fill export button, animated success badge, animated quality chart,
// dark-mode glow streak on Home, sharper before/after contrast. API logic unchanged.
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
    @State private var platform = "YouTube"
    @State private var resolution = "4K"
    @State private var fps = 60
    @State private var aiEnhance = true
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
    @State private var showInfo = false
    @State private var split: CGFloat = 0.5
    @State private var chartDrawn: CGFloat = 0
    @State private var badgePop = false
    @State private var sparklePulse = false

    // MARK: Tokens
    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? .white : Color(red: 0.07, green: 0.09, blue: 0.16) }
    private var secondary: Color { dark ? Color(red: 0.66, green: 0.69, blue: 0.78) : Color(red: 0.42, green: 0.46, blue: 0.57) }
    private var bg: Color { dark ? Color(red: 0.012, green: 0.014, blue: 0.035) : Color(red: 0.965, green: 0.972, blue: 0.99) }
    private var blue: Color { Color(red: 0.10, green: 0.38, blue: 1.0) }
    private var cyan: Color { Color(red: 0.17, green: 0.62, blue: 1.0) }
    private var violet: Color { Color(red: 0.62, green: 0.27, blue: 0.98) }
    private var accent: Color { dark ? Color(red: 0.70, green: 0.45, blue: 1.0) : blue }
    private var inactiveFill: Color { dark ? Color.white.opacity(0.09) : Color(red: 0.90, green: 0.92, blue: 0.97) }
    private var blueGradient: LinearGradient {
        LinearGradient(colors: [cyan, blue], startPoint: .leading, endPoint: .trailing)
    }
    private var purpleGradient: LinearGradient {
        LinearGradient(colors: [violet, Color(red: 0.36, green: 0.35, blue: 1.0)], startPoint: .leading, endPoint: .trailing)
    }
    private var shareGradient: LinearGradient { dark ? purpleGradient : blueGradient }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            let scale = min(w / 365.0, h / 690.0)
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
            .frame(width: w / scale, height: h / scale)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: w, height: h, alignment: .topLeading)
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

    // MARK: Background: silver glass (light) / purple-blue glow (dark)
    private var appBackground: some View {
        ZStack {
            bg
            if dark {
                RadialGradient(colors: [violet.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 330)
                RadialGradient(colors: [blue.opacity(0.28), .clear], center: .bottomLeading, startRadius: 0, endRadius: 380)
            } else {
                LinearGradient(colors: [.white, Color(red: 0.92, green: 0.94, blue: 0.985)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [cyan.opacity(0.10), .clear], center: .bottomLeading, startRadius: 0, endRadius: 320)
            }
        }
    }

    // MARK: Building blocks
    private func surface<Content: View>(radius: CGFloat = 16, @ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content()
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(dark ? Color(red: 0.09, green: 0.10, blue: 0.16).opacity(0.68) : Color.white.opacity(0.66)) }
                    .clipShape(shape)
            }
            .overlay { shape.strokeBorder(dark ? .white.opacity(0.14) : .white.opacity(0.95), lineWidth: 0.8) }
            .shadow(color: dark ? .black.opacity(0.30) : Color(red: 0.4, green: 0.45, blue: 0.6).opacity(0.14), radius: 12, y: 4)
    }

    private func gradientButton(_ title: String, symbol: String, gradient: LinearGradient, action: @escaping () -> Void) -> some View {
        Button(action: action) { gradientLabel(title, symbol: symbol, gradient: gradient) }.buttonStyle(.plain)
    }

    private func gradientLabel(_ title: String, symbol: String, gradient: LinearGradient) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(gradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
            .shadow(color: (dark ? violet : blue).opacity(0.30), radius: 9, y: 3)
    }

    private func glassButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(dark ? AnyShapeStyle(Color.white.opacity(0.07)) : AnyShapeStyle(.thinMaterial), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(dark ? 0.14 : 0.9), lineWidth: 0.8))
        }.buttonStyle(.plain)
    }

    private func navCircle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(dark ? 0.16 : 0.9), lineWidth: 0.7))
        }.buttonStyle(.plain)
    }

    private func header(_ title: String) -> some View {
        HStack {
            navCircle("chevron.left") { page = page == 2 ? 1 : 0 }
            Spacer()
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            navCircle("ellipsis") { settings = true }
        }.frame(height: 32)
    }

    private var navigationBar: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return HStack(spacing: 0) {
            navItem("house.fill", "Home", 0)
            navItem("sparkles", "Enhance", 1)
            navItem("square.stack.3d.up", "Library", 2)
        }
        .frame(height: 50)
        .background { shape.fill(.ultraThinMaterial).overlay { shape.fill(dark ? .black.opacity(0.35) : .white.opacity(0.45)) } }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(dark ? 0.20 : 0.95), lineWidth: 0.8) }
        .padding(.horizontal, 13).padding(.bottom, 3)
    }

    private func navItem(_ icon: String, _ label: String, _ destination: Int) -> some View {
        let on = page == destination
        return Button { page = destination } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                    .shadow(color: on ? accent.opacity(0.7) : .clear, radius: 6)
                Text(label).font(.system(size: 10, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? accent : secondary)
            .frame(maxWidth: .infinity).frame(height: 38)
        }.buttonStyle(.plain)
    }

    private func mmss(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func fileSizeText(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // Fit the imported video's display orientation inside the existing glass card.
    // A portrait clip is shown tall, landscape wide; neither is cropped or stretched.
    private func playerFrame(minHeight: CGFloat, maxHeight: CGFloat, result: Bool = false) -> some View {
        GeometryReader { geometry in
            let ratio = clip.aspectRatio
            let fittedWidth = min(geometry.size.width, geometry.size.height * ratio)
            let fittedHeight = min(geometry.size.height, geometry.size.width / ratio)
            ZStack {
                Color.black
                if let url = result ? outputURL : inputURL {
                    VideoPlayer(player: playerFor(url))
                        .frame(width: fittedWidth, height: fittedHeight)
                } else {
                    Image("NaiseSample").resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: inputURL == nil ? minHeight : (clip.aspectRatio < 1 ? maxHeight : minHeight))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // A gap that grows on tall phones (up to `max`) so the screen fills like the mockup.
    private func flexGap(_ max: CGFloat) -> some View {
        Spacer(minLength: 0).frame(maxHeight: max)
    }

    private func statTriple(_ values: [(String, String, String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 3) {
                    Image(systemName: values[i].0).font(.system(size: 13)).foregroundStyle(secondary)
                    Text(values[i].1).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                    Text(values[i].2).font(.system(size: 9)).foregroundStyle(secondary)
                }.frame(maxWidth: .infinity)
                if i < 2 { Rectangle().fill(secondary.opacity(0.22)).frame(width: 1, height: 34) }
            }
        }.padding(.vertical, 9)
    }

    // MARK: Home
    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                (Text("Naise").foregroundColor(ink) + Text("+").foregroundColor(accent))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Spacer()
                Button { settings = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "crown.fill").font(.system(size: 13)).foregroundStyle(dark ? .white : ink)
                        Text("Pro").font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 13).frame(height: 32)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(dark ? 0.16 : 0.9), lineWidth: 0.7))
                }.buttonStyle(.plain)
            }.frame(height: 38)

            VStack(alignment: .leading, spacing: 5) {
                Text("Enhance Your\nVideos with AI").font(.system(size: 21, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Restore clarity, boost quality, and\nmake every frame look its best.")
                    .font(.system(size: 10)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .trailing) {
                if dark {
                    Ellipse()
                        .fill(LinearGradient(colors: [violet.opacity(0.55), blue.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 260, height: 90)
                        .rotationEffect(.degrees(-25))
                        .blur(radius: 28)
                        .offset(x: 90, y: -10)
                        .allowsHitTesting(false)
                }
            }

            flexGap(8)
            surface(radius: 16) {
                ZStack(alignment: .topLeading) {
                    playerFrame(minHeight: 172, maxHeight: 250)
                    Label("My Video.mp4", systemImage: "film")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.45), in: Capsule()).padding(8)
                    if inputURL == nil {
                        Image(systemName: "play.fill").font(.system(size: 17)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.4)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: 5) {
                            Spacer()
                            HStack { Text("00:00 / \(mmss(inputURL == nil ? 84 : clip.duration))"); Spacer() }
                            HStack(spacing: 8) {
                                Capsule().fill(.white.opacity(0.35)).frame(height: 3)
                                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 30, height: 3) }
                                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9))
                            }
                        }
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white).padding(10)
                    }
                }.frame(height: inputURL == nil ? 172 : (clip.aspectRatio < 1 ? 250 : 172)).padding(6)
            }

            HStack(spacing: 6) {
                PhotosPicker(selection: $selected, matching: .videos) { toolLabel("arrow.triangle.2.circlepath", "Replace") }
                    .buttonStyle(.plain).disabled(processing)
                Button { failure = "Trim is not available yet; source video has not been changed." } label: { toolLabel("scissors", "Trim") }
                    .buttonStyle(.plain)
                Button { if inputURL == nil { failure = "Import a video first." } else { showInfo = true } } label: { toolLabel("info.circle", "Details") }
                    .buttonStyle(.plain)
            }

            surface(radius: 14) {
                statTriple([
                    ("timer", inputURL == nil ? "01:24" : mmss(clip.duration), "Duration"),
                    ("arrow.up.left.and.arrow.down.right", inputURL == nil ? "1920 × 1080" : "\(clip.width) × \(clip.height)", "Resolution"),
                    ("square.stack.3d.up", inputURL == nil ? "30 FPS" : "\(Int(clip.fps.rounded())) FPS", "Frame Rate")
                ])
            }

            flexGap(6)
            PhotosPicker(selection: $selected, matching: .videos) {
                gradientLabel("Import Video", symbol: "plus", gradient: blueGradient)
            }.buttonStyle(.plain).disabled(processing)
            flexGap(18)
        }.padding(.horizontal, 14).padding(.bottom, 6)
    }

    private func toolLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 16))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .frame(maxWidth: .infinity).frame(height: 46)
        .background(dark ? AnyShapeStyle(Color.white.opacity(0.07)) : AnyShapeStyle(.thinMaterial), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(dark ? 0.12 : 0.9), lineWidth: 0.8))
    }

    // MARK: Enhance
    private func settingsLine(_ symbol: String, title: String, subtitle: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 8.5)).foregroundStyle(secondary)
            }
            Spacer(minLength: 3)
            trailing()
        }.padding(.horizontal, 11).frame(height: 44)
    }

    private func segmented(_ options: [String], selection: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { onSelect(option) } label: {
                    Text(option).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selection == option ? Color.white : ink)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background { if selection == option { Capsule().fill(blueGradient) } }
                }.buttonStyle(.plain)
            }
        }.padding(2).background(inactiveFill, in: Capsule())
    }

    private var previewComparison: some View {
        ZStack(alignment: .bottom) {
            if inputURL == nil {
                GeometryReader { g in
                    let pos = g.size.width * split
                    ZStack(alignment: .leading) {
                        Image("NaiseSample").resizable().scaledToFill()
                            .frame(width: g.size.width, height: g.size.height).clipped()
                        Image("NaiseSample").resizable().scaledToFill().blur(radius: 1.6).saturation(0.55).contrast(0.82).brightness(-0.05)
                            .frame(width: g.size.width, height: g.size.height).clipped()
                            .mask(alignment: .leading) { Rectangle().frame(width: pos) }
                        Rectangle().fill(.white).frame(width: 2).offset(x: pos - 1)
                        HStack(spacing: 1) {
                            Image(systemName: "chevron.left"); Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.5), in: Circle()).overlay(Circle().stroke(.white, lineWidth: 1.2))
                        .offset(x: pos - 14)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        split = min(max(value.location.x / max(1, g.size.width), 0.05), 0.95)
                    })
                }
            } else {
                playerFrame(minHeight: 150, maxHeight: 230)
            }
            HStack {
                Text("Original").padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                Spacer()
                Text(outputURL == nil && inputURL != nil ? "Preview" : "Enhanced").padding(.horizontal, 8).padding(.vertical, 4)
                    .background(blueGradient, in: Capsule())
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).padding(7)
        }
        .frame(height: inputURL == nil ? 150 : (clip.aspectRatio < 1 ? 230 : 150))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var enhanceScreen: some View {
        VStack(spacing: 8) {
            header("Enhance")
            flexGap(6)
            surface(radius: 16) { previewComparison.padding(6) }
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(accent)
                Text("Enhancement Settings").font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            VStack(spacing: 6) {
                surface(radius: 14) {
                    Menu {
                        ForEach(["YouTube", "TikTok", "Instagram", "WhatsApp"], id: \.self) { name in
                            Button(name) { platform = name }
                        }
                    } label: {
                        settingsLine("square.stack.3d.up", title: "Platform", subtitle: "Optimize for your target platform") {
                            HStack(spacing: 3) { Text(platform); Image(systemName: "chevron.right").font(.system(size: 9)) }
                                .font(.system(size: 10.5)).foregroundStyle(ink)
                        }
                    }.buttonStyle(.plain)
                }
                surface(radius: 14) {
                    settingsLine("play.rectangle", title: "Resolution", subtitle: "Output video quality") {
                        segmented(["1080p", "4K"], selection: resolution) { resolution = $0 }
                    }
                }
                surface(radius: 14) {
                    settingsLine("film", title: "Frame Rate", subtitle: "Smoother, more natural motion") {
                        segmented(["30 FPS", "60 FPS"], selection: "\(fps) FPS") { fps = $0.hasPrefix("30") ? 30 : 60 }
                    }
                }
            }
            surface(radius: 15) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").foregroundStyle(accent)
                        Text("AI Enhancement").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Toggle("", isOn: $aiEnhance).labelsHidden().tint(blue).scaleEffect(0.82)
                    }
                    if !processing {
                        ForEach(["Upscale & add detail", "Reduce noise & clean artifacts", "Improve color & dynamic range"], id: \.self) { line in
                            Label(line, systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(ink.opacity(0.9))
                        }
                    }
                    if processing {
                        ProgressView(value: Double(progress), total: 100).tint(accent)
                        Text("\(stage) · \(progress)%").font(.system(size: 9)).foregroundStyle(secondary)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 9)
            }
            if processing {
                exportProgressButton
                glassButton("Stop checking status", symbol: "pause.circle") {
                    activeTask?.cancel(); activeTask = nil
                    processing = false
                    stage = "Job continues on PC; reopen to reconnect"
                }
            } else {
                gradientButton("Enhance & Export", symbol: "sparkles", gradient: purpleGradient) {
                    if inputURL == nil {
                        failure = "Import a video first (Home → Import Video)."
                    } else if serverURL.isEmpty {
                        failure = "Add your HTTPS tunnel URL in Settings (•••) to export."
                        settings = true
                    } else {
                        beginProcessing()
                    }
                }
            }
            flexGap(18)
        }.padding(.horizontal, 14).padding(.bottom, 6)
    }

    private var exportProgressButton: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(purpleGradient)
                Capsule().fill(.white.opacity(0.22))
                    .frame(width: g.size.width * CGFloat(min(max(progress, 0), 100)) / 100)
                    .animation(.easeOut(duration: 0.4), value: progress)
                HStack(spacing: 6) {
                    ProgressView().tint(.white).scaleEffect(0.7)
                    Text("Enhancing… \(progress)%").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 42)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
        .shadow(color: violet.opacity(0.35), radius: 9, y: 3)
    }

    // MARK: Result (only real values: resolution, FPS, file size)
    private var scaleGain: Double {
        let source = Double(min(clip.width, clip.height))
        return source > 0 ? (resolution == "4K" ? 2160 : 1080) / source : 0
    }

    private var resultScreen: some View {
        let done = outputURL != nil
        let saved = outputURL.map { savedPath == $0.path } ?? false
        let outLabel = resolution == "4K" ? "4K" : "1080p"
        let outDims = resolution == "4K" ? "(3840 × 2160)" : "(1920 × 1080)"
        return VStack(spacing: 8) {
            header("Result")
            flexGap(6)
            surface(radius: 16) {
                VStack(spacing: 5) {
                    ZStack {
                        Circle().strokeBorder(LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
                            .frame(width: 52, height: 52)
                            .shadow(color: accent.opacity(0.5), radius: 8)
                        Image(systemName: done ? "checkmark" : "clock").font(.system(size: 22, weight: .bold)).foregroundStyle(accent)
                        Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(blue)
                            .offset(x: -36, y: 8).opacity(sparklePulse ? 1 : 0.3).scaleEffect(sparklePulse ? 1.1 : 0.8)
                        Image(systemName: "sparkle").font(.system(size: 7, weight: .bold)).foregroundStyle(violet)
                            .offset(x: 34, y: -22).opacity(sparklePulse ? 0.3 : 1).scaleEffect(sparklePulse ? 0.8 : 1.1)
                    }
                    .scaleEffect(badgePop ? 1 : 0.6)
                    .opacity(badgePop ? 1 : 0)
                    .onAppear {
                        badgePop = false
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { badgePop = true }
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { sparklePulse = true }
                    }
                    Text(saved ? "Video Saved Successfully" : done ? "Video Enhanced Successfully" : processing ? "Enhancing Your Video" : "No enhanced video yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text(saved ? "Your video has been enhanced and\nsaved to your library." : done ? "Your video has been enhanced and\nis ready to save or share." : processing ? "Processing \(progress)% · \(stage)" : "Your result will appear here after export.")
                        .font(.system(size: 9.5)).foregroundStyle(secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            surface(radius: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.fill").foregroundStyle(accent)
                        Text("Quality Improvement").font(.system(size: 11.5, weight: .semibold))
                    }
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(done && scaleGain > 0 ? String(format: "%.1f×", scaleGain) : "—")
                                .font(.system(size: 26, weight: .bold))
                            Text("Resolution ↑").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(purpleGradient, in: Capsule())
                        }.frame(width: 104, alignment: .leading)
                        qualityChart(active: done && scaleGain > 0,
                                     badge: "+\(Int(max(0, (scaleGain - 1) * 100)))%")
                    }
                }.padding(11)
            }
            HStack(spacing: 6) {
                resultTile("sparkles.tv", done ? outLabel : "—", done ? outDims : "Resolution", highlight: done)
                resultTile("square.stack.3d.up", done ? "\(fps) FPS" : "—", "Frame Rate")
                resultTile("externaldrive", outputURL.map { fileSizeText($0) } ?? "—", "File Size")
            }
            surface(radius: 14) {
                HStack(spacing: 10) {
                    Image("NaiseSample").resizable().scaledToFill().frame(width: 52, height: 40).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("My Video (Enhanced).mp4").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(done ? "\(outLabel) · \(fps) FPS · \(outputURL.map { fileSizeText($0) } ?? "")" : "Process a clip to enable sharing")
                            .font(.system(size: 9)).foregroundStyle(secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(secondary)
                }.padding(9)
            }
            if let outputURL {
                gradientButton("Share", symbol: "square.and.arrow.up", gradient: shareGradient) {
                    shareItem = NaiseShareItem(url: outputURL)
                }
                glassButton(saved ? "Saved to Photos ✓" : "Save to Photos", symbol: "square.and.arrow.down") {
                    Task { await saveToPhotos(outputURL) }
                }.disabled(saved)
            } else {
                gradientButton("Go to Enhance", symbol: "sparkles", gradient: shareGradient) { page = 1 }
                glassButton("Save to Photos", symbol: "square.and.arrow.down") {}.disabled(true).opacity(0.55)
            }
            flexGap(18)
        }.padding(.horizontal, 14).padding(.bottom, 6)
    }

    private func resultTile(_ symbol: String, _ value: String, _ caption: String, highlight: Bool = false) -> some View {
        surface(radius: 14) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(highlight ? accent : secondary)
                Text(value).font(.system(size: 13, weight: .bold)).foregroundStyle(highlight ? accent : ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(caption).font(.system(size: 8.5)).foregroundStyle(secondary)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 62).padding(.horizontal, 4)
        }
    }

    private func qualityChart(active: Bool, badge: String) -> some View {
        let line = active ? AnyShapeStyle(blueGradient) : AnyShapeStyle(Color.gray.opacity(0.4))
        return ZStack(alignment: .topTrailing) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 50))
                p.addCurve(to: CGPoint(x: 150, y: 12), control1: CGPoint(x: 50, y: 48), control2: CGPoint(x: 95, y: 18))
            }
            .trim(from: 0, to: active ? chartDrawn : 1)
            .stroke(line, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 0, y: 50))
                p.addCurve(to: CGPoint(x: 150, y: 12), control1: CGPoint(x: 50, y: 48), control2: CGPoint(x: 95, y: 18))
                p.addLine(to: CGPoint(x: 150, y: 58)); p.addLine(to: CGPoint(x: 0, y: 58)); p.closeSubpath()
            }.fill(LinearGradient(colors: [(active ? blue : .gray).opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
            if active {
                Circle().fill(.white).overlay(Circle().stroke(blue, lineWidth: 2)).frame(width: 7, height: 7).offset(x: 3, y: 9)
                Text(badge).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(blueGradient, in: Capsule()).offset(y: -9)
            }
        }
        .frame(width: 150, height: 58)
        .onAppear {
            chartDrawn = 0
            withAnimation(.easeOut(duration: 1.4)) { chartDrawn = 1 }
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
                    Text("Resolution and FPS are sent to the backend. RIFE/NVENC and HDR behavior depend on the Windows backend, not the UI.")
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
        let base = serverURL; let token = serverToken; let selectedResolution = resolution; let selectedFPS = fps
        activeTask = Task {
            do {
                let job = try await NaiseAPI.upload(video: inputURL, resolution: selectedResolution, fps: selectedFPS, base: base, token: token)
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
