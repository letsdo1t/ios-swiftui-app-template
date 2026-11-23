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

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 740
            VStack(spacing: 0) {
                // ScrollView = fallback supaya tiada yang terpotong pada skrin kecil (SE, mini).
                // Pada skrin besar kandungan penuhkan ruang, tiada scroll.
                ScrollView(showsIndicators: false) {
                    Group {
                        switch page {
                        case 1: enhance(compact: compact)
                        case 2: result(compact: compact)
                        default: home(compact: compact)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 64), alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                bottomBar()
            }
            .padding(.horizontal, compact ? 14 : 15)
            .padding(.top, compact ? 2 : 4)
            .padding(.bottom, 3)
            .background {
                bg.ignoresSafeArea()
                if dark {
                    RadialGradient(colors: [purple.opacity(0.115), .clear], center: .topTrailing, startRadius: 0, endRadius: 310).ignoresSafeArea()
                    // Glow ungu-biru macam dalam gambar dark mode
                    Circle().fill(purple.opacity(0.30)).frame(width: 300, height: 300).blur(radius: 90)
                        .offset(x: 170, y: -300).allowsHitTesting(false)
                    Circle().fill(blue.opacity(0.30)).frame(width: 320, height: 320).blur(radius: 90)
                        .offset(x: -170, y: 340).allowsHitTesting(false)
                } else {
                    Circle().fill(blue.opacity(0.10)).frame(width: 320, height: 320).blur(radius: 80)
                        .offset(x: -170, y: 340).allowsHitTesting(false)
                    LinearGradient(colors: [Color.white.opacity(0.92), Color(red: 0.91, green: 0.94, blue: 0.99), Color.white.opacity(0.40)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                }
            }
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
            Button("OK", role: .cancel) {}
        } message: { Text(clip.label) }
        .task { await resumeJobIfNeeded() }
    }

    private func glass<Content: View>(radius: CGFloat = 16, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(
                                colors: dark
                                    ? [Color.white.opacity(0.075), glassFill.opacity(0.84), Color.black.opacity(0.13)]
                                    : [Color.white.opacity(0.90), glassFill.opacity(0.74), Color(red: 0.89, green: 0.92, blue: 0.98).opacity(0.64)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: dark
                            ? [Color.white.opacity(0.25), Color.white.opacity(0.09), Color.white.opacity(0.15)]
                            : [.white, .white.opacity(0.55), Color(red: 0.75, green: 0.81, blue: 0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 0.85)
            }
            .shadow(color: dark ? .black.opacity(0.35) : Color(red: 0.27, green: 0.39, blue: 0.59).opacity(0.14), radius: 11, y: 5)
    }

    private func circularButton(_ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(borderColor, lineWidth: 0.8))
        }.buttonStyle(.plain)
    }

    private func pageHeader(_ title: String) -> some View {
        HStack {
            circularButton("chevron.left") { page = page == 2 ? 1 : 0 }
            Spacer()
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
            circularButton("ellipsis") { settings = true }
        }
        .frame(height: 37)
    }

    private var compactButtonHeight: CGFloat { 43 }

    private func button(_ title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: compactButtonHeight)
                .foregroundStyle(prominent ? Color.white : ink)
                .background {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(actionGradient) : AnyShapeStyle(.thinMaterial))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 15).strokeBorder(borderColor.opacity(0.8), lineWidth: 0.9)
                }
                .shadow(color: prominent ? accent.opacity(0.20) : .clear, radius: 7, y: 3)
        }.buttonStyle(.plain)
    }

    private func bottomBar() -> some View {
        HStack(spacing: 0) {
            tab("house.fill", "Home", 0)
            tab("sparkles", "Enhance", 1)
            tab("play.rectangle", "Result", 2)
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(borderColor, lineWidth: 0.9) }
        .padding(.top, 4)
    }

    private func tab(_ symbol: String, _ name: String, _ index: Int) -> some View {
        Button { page = index } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: page == index ? .semibold : .regular))
                Text(name).font(.system(size: 10, weight: page == index ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(page == index ? accent : secondary)
        }.buttonStyle(.plain)
    }

    // The illustrated empty state resembles the chosen concept without pretending a video is processed.
    private func videoPanel(height: CGFloat, resultVideo: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(dark ? Color(red: 0.045, green: 0.060, blue: 0.110) : Color(red: 0.87, green: 0.92, blue: 0.98))
            if let url = resultVideo ? outputURL : inputURL {
                VideoPlayer(player: playerFor(url))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                GeometryReader { sampleSize in
                    Image("NaiseSample")
                        .resizable()
                        .scaledToFill()
                        .frame(width: sampleSize.size.width, height: sampleSize.size.height)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            Text(resultVideo ? "Sample only · No result yet" : "Sample only · Import a video")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.black.opacity(0.58), in: Capsule())
                                .padding(9)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // Slider Original ↔ Enhanced. Seret untuk bandingkan. Hanya untuk SAMPLE bila belum ada video.
    private func compareSample(height: CGFloat) -> some View {
        GeometryReader { g in
            let x = g.size.width * split
            ZStack(alignment: .leading) {
                Image("NaiseSample").resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
                    .saturation(1.08).contrast(1.06)
                Image("NaiseSample").resizable().scaledToFill()
                    .saturation(0.76)
                    .frame(width: g.size.width, height: g.size.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Rectangle().fill(.white).frame(width: 2, height: g.size.height)
                    .offset(x: x - 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: x - 15)
                VStack {
                    Spacer()
                    HStack {
                        Text("Original")
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                        Text("Enhanced")
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(max(value.location.x / max(g.size.width, 1), 0.06), 0.94)
            })
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func sectionHeading(_ title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").foregroundStyle(accent)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private func smallTool(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 47)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(borderColor) }
        }.buttonStyle(.plain)
    }

    private func toolContent(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 17))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity).frame(height: 47)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(borderColor) }
    }

    private func compactStat(_ icon: String, _ value: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 13))
            Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func filledLabel(_ title: String, icon: String, prominent: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 40)
            .foregroundStyle(prominent ? .white : ink)
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .fill(prominent ? AnyShapeStyle(actionGradient) : AnyShapeStyle(.thinMaterial))
            }
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(borderColor.opacity(0.8)) }
    }

    private func home(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 11) {
            HStack {
                (Text("Naise").foregroundColor(ink) + Text("+").foregroundColor(accent))
                    .font(.system(size: compact ? 20 : 22, weight: .bold))
                Spacer()
                circularButton("gearshape") { settings = true }
            }
            .frame(height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Enhance Your\nVideos with AI")
                    .font(.system(size: compact ? 22 : 25, weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.87)
                Text("Smooth motion, natural color, original audio.")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)

            glass(radius: 18) {
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        videoPanel(height: compact ? 170 : 218)
                        if let url = inputURL {
                            HStack(spacing: 4) {
                                Image(systemName: "film")
                                Text(url.lastPathComponent).lineLimit(1)
                            }
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(8)
                        }
                    }
                    HStack {
                        Text(inputURL == nil ? "Choose a video to begin" : "Original video")
                        Spacer(minLength: 2)
                        if inputURL != nil { Text("\(Int(clip.duration.rounded()))s") }
                    }
                    .font(.system(size: 10)).foregroundStyle(secondary)
                }
                .padding(8)
            }

            HStack(spacing: 6) {
                PhotosPicker(selection: $selected, matching: .videos) {
                    toolContent("arrow.triangle.2.circlepath", "Replace")
                }.buttonStyle(.plain).disabled(processing)
                smallTool("scissors", "Trim") { failure = "Trim belum tersedia dalam versi ini. Ciri ini masih dalam senarai pembangunan." }
                smallTool("info.circle", "Details") { showInfo = true }
            }.disabled(inputURL == nil)

            glass(radius: 13) {
                HStack(spacing: 0) {
                    compactStat("clock", inputURL == nil ? "—" : "\(Int(clip.duration.rounded()))s", "Duration")
                    Rectangle().fill(borderColor).frame(width: 1, height: 25)
                    compactStat("viewfinder", inputURL == nil ? "—" : "\(clip.width)×\(clip.height)", "Resolution")
                    Rectangle().fill(borderColor).frame(width: 1, height: 25)
                    compactStat("speedometer", inputURL == nil ? "—" : "\(Int(clip.fps.rounded())) FPS", "Frame Rate")
                }.padding(.vertical, 8)
            }

            PhotosPicker(selection: $selected, matching: .videos) {
                filledLabel(inputURL == nil ? "Import Video" : "Import Another Video", icon: "plus", prominent: true)
            }.buttonStyle(.plain).disabled(processing)

            if inputURL != nil {
                button("Open Enhance", symbol: "sparkles", prominent: false) { page = 1 }
            }
            Spacer(minLength: 0)
        }
    }

    private func platformRow() -> some View {
        Menu {
            ForEach(["WhatsApp", "Instagram", "TikTok", "YouTube"], id: \.self) { option in
                Button(option) { platform = option }
            }
        } label: {
            settingsRow("square.stack", title: "Platform", subtitle: "Selected target platform", trailing: platform + "  ›")
        }.buttonStyle(.plain)
    }

    private func settingsRow(_ symbol: String, title: String, subtitle: String, trailing: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 21)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(secondary)
            }
            Spacer(minLength: 2)
            Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
        }.padding(.horizontal, 10).frame(height: 43)
    }

    private func choice(_ label: String, active: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(label).font(.system(size: 11, weight: .semibold))
                .frame(minWidth: 42)
                .padding(.horizontal, 8)
                .frame(height: 27)
                .foregroundStyle(active ? Color.white : ink)
                .background {
                    Capsule().fill(active ? AnyShapeStyle(actionGradient) : AnyShapeStyle(inactiveFill))
                }
        }.buttonStyle(.plain)
    }

    private func enhance(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 11) {
            pageHeader("Enhance")
            glass {
                VStack(spacing: 6) {
                    if inputURL == nil {
                        // Tiada video: tunjuk slider Original/Enhanced (contoh sahaja, bukan hasil sebenar)
                        compareSample(height: compact ? 145 : 180)
                    } else {
                        ZStack(alignment: .top) {
                            videoPanel(height: compact ? 145 : 180)
                            HStack(spacing: 8) {
                                Text("Original")
                                Spacer()
                                Text(outputURL == nil ? "Preview" : "Enhanced")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(6)
                        }
                    }
                    HStack {
                        Text(inputURL?.lastPathComponent ?? "No video selected · sample preview")
                        Spacer(minLength: 4)
                        if inputURL != nil { Text(clip.label) }
                    }
                    .font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
                }.padding(8)
            }
            sectionHeading("Enhancement Settings")
            glass(radius: 13) { platformRow() }
            glass(radius: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder").font(.system(size: 15)).frame(width: 21)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resolution").font(.system(size: 12, weight: .semibold))
                        Text("Output video quality").font(.system(size: 9)).foregroundStyle(secondary)
                    }
                    Spacer(minLength: 2)
                    choice("1080p", active: resolution == "1080p") { resolution = "1080p" }
                    choice("4K", active: resolution == "4K") { resolution = "4K" }
                }.padding(.horizontal, 10).frame(height: 43)
            }
            glass(radius: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "video").font(.system(size: 15)).frame(width: 21)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frame Rate").font(.system(size: 12, weight: .semibold))
                        Text("Smooth motion output").font(.system(size: 9)).foregroundStyle(secondary)
                    }
                    Spacer(minLength: 2)
                    Text("60 FPS").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 13).frame(height: 27)
                        .background(actionGradient, in: Capsule())
                }.padding(.horizontal, 10).frame(height: 43)
            }
            glass(radius: 14) {
                VStack(alignment: .leading, spacing: compact ? 4 : 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").foregroundStyle(accent)
                        Text("Adaptive Enhance").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(processing ? "\(progress)%" : "Auto")
                            .font(.system(size: 10)).foregroundStyle(secondary)
                    }
                    Label(clip.fps >= 59.5 ? "Source already 60 FPS — skip interpolation" : "Lower FPS → target smooth 60 FPS", systemImage: "checkmark")
                    Label("Natural color and original audio", systemImage: "checkmark")
                    Label("Preserve source HDR when supported", systemImage: "checkmark")
                    if processing {
                        ProgressView(value: Double(progress), total: 100).tint(accent)
                        Text(stage).font(.system(size: 10)).foregroundStyle(secondary)
                    }
                }
                .font(.system(size: 10))
                .padding(10)
            }
            if processing {
                button("Stop checking status", symbol: "pause.circle", prominent: false) {
                    activeTask?.cancel(); activeTask = nil
                    processing = false
                    stage = "Job continues on PC; reopen to reconnect"
                }
            } else {
                button("Enhance & Export", symbol: "sparkles", prominent: true) { beginProcessing() }
                    .disabled(inputURL == nil || serverURL.isEmpty)
            }
            if serverURL.isEmpty {
                Text("Add your HTTPS tunnel URL in Settings to export.")
                    .font(.system(size: 9)).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func result(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 11) {
            pageHeader("Result")
            glass(radius: 17) {
                VStack(spacing: 5) {
                    ZStack {
                        Circle().strokeBorder(actionGradient, lineWidth: 2.5)
                            .frame(width: 50, height: 50)
                        Image(systemName: outputURL == nil ? "clock" : "checkmark")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .padding(.bottom, 2)
                    Text(outputURL == nil ? (processing ? "Enhancing Your Video" : "No completed video yet") : (savedPath == outputURL?.path ? "Video Saved Successfully" : "Video Ready"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(outputURL == nil ? (processing ? "Processing \(progress)% — \(stage)" : "Your enhanced video will appear here after processing.") : "Preview your video, share it, or save to Photos.")
                        .font(.system(size: 10)).foregroundStyle(secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 10 : 12)
            }

            glass(radius: 17) {
                videoPanel(height: compact ? 154 : 185, resultVideo: true)
                    .padding(8)
            }
            sectionHeading("Video Details")
            glass(radius: 14) {
                HStack(spacing: 4) {
                    compactStat("viewfinder", outputURL == nil ? "—" : resolution, "Resolution")
                    Rectangle().fill(borderColor).frame(width: 1, height: 28)
                    compactStat("speedometer", outputURL == nil ? "—" : "60 FPS", "Output target")
                    Rectangle().fill(borderColor).frame(width: 1, height: 28)
                    compactStat("checkmark.seal", outputURL == nil ? "Pending" : "Ready", "Status")
                }.padding(.vertical, 9)
            }
            glass(radius: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .foregroundStyle(accent).font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outputURL?.lastPathComponent ?? "No enhanced file available")
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(outputURL == nil ? "Process a video to unlock sharing" : "Enhanced MP4 · ready")
                            .font(.system(size: 10)).foregroundStyle(secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(12)
            }
            if let outputURL {
                button("Share", symbol: "square.and.arrow.up", prominent: true) {
                    shareItem = NaiseShareItem(url: outputURL)
                }
                button(savedPath == outputURL.path ? "Saved to Photos ✓" : "Save to Photos", symbol: "square.and.arrow.down", prominent: false) {
                    Task { await saveToPhotos(outputURL) }
                }.disabled(savedPath == outputURL.path)
            } else {
                button("Go to Enhance", symbol: "sparkles", prominent: true) { page = 1 }
                button("Save to Photos", symbol: "square.and.arrow.down", prominent: false) {}.disabled(true)
            }
            Spacer(minLength: 0)
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
