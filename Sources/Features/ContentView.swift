import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var exportedVideoURL: URL?
    @State private var videoName = "Ready to import"
    @State private var isProcessing = false
    @State private var exportError: String?
    @State private var platform = "Instagram"
    @State private var resolution = "1080p"
    @State private var fps = "60 FPS"

    // Palet Frosted Glass
    private let bgTop = Color(red: 0.08, green: 0.14, blue: 0.24)
    private let bgMid = Color(red: 0.05, green: 0.08, blue: 0.15)
    private let bgBottom = Color(red: 0.04, green: 0.05, blue: 0.09)
    private let glassBorder = Color.white.opacity(0.14)
    private let cyanAccent = Color(red: 0.22, green: 0.74, blue: 0.97)
    private let cyanBright = Color(red: 0.49, green: 0.83, blue: 0.99)
    private let indigoAccent = Color(red: 0.51, green: 0.55, blue: 0.97)
    private let mutedText = Color(red: 0.58, green: 0.65, blue: 0.74)

    private let platforms = ["Instagram", "TikTok", "WhatsApp", "Facebook"]
    private let resolutions = ["720p", "1080p", "4K"]
    private let rates = ["30 FPS", "60 FPS"]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                    .padding(.top, 12)

                importArea
                    .padding(.top, 18)

                status
                    .padding(.top, 10)

                settingsPanel
                    .padding(.top, 16)

                Spacer(minLength: 12)

                exportButton

                if let exportedVideoURL {
                    ShareLink(item: exportedVideoURL, preview: SharePreview("Naise+ Video")) {
                        Label("Share / Save Video", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(cyanBright)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(cyanAccent.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .padding(.top, 10)
                }

                if let exportError {
                    Text(exportError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: 500)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [bgTop, bgMid, bgBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(cyanAccent.opacity(0.16))
                        .frame(width: 280, height: 280)
                        .blur(radius: 70)
                        .offset(x: -110, y: -260)

                    Circle()
                        .fill(indigoAccent.opacity(0.14))
                        .frame(width: 260, height: 260)
                        .blur(radius: 75)
                        .offset(x: 130, y: 180)
                }
                .ignoresSafeArea()
            )
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Naise+")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("AI Video Enhancer")
                    .font(.system(size: 13))
                    .foregroundStyle(mutedText)
            }

            Spacer()

            Image(systemName: "video.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(cyanBright)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(glassBorder, lineWidth: 1)
                )
        }
    }

    // MARK: - Import Area
    private var importArea: some View {
        PhotosPicker(selection: $selectedVideo, matching: .videos) {
            VStack(spacing: 10) {
                Image(systemName: videoURL == nil ? "plus" : "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(cyanBright)
                    .frame(width: 46, height: 46)
                    .background(cyanAccent.opacity(0.18), in: Circle())

                Text(videoURL == nil ? "Import Video" : "Change Video")
                    .font(.system(size: 17, weight: .semibold))

                Text(videoURL == nil
                     ? "Select from Photos library"
                     : "Tap to replace current clip")
                    .font(.system(size: 12))
                    .foregroundStyle(mutedText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 152)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        videoURL == nil ? Color.white.opacity(0.24) : cyanAccent.opacity(0.75),
                        style: StrokeStyle(
                            lineWidth: 1.4,
                            dash: videoURL == nil ? [6, 5] : []
                        )
                    )
            )
        }
        .onChange(of: selectedVideo) { _, item in
            Task {
                await loadVideo(item)
            }
        }
    }

    // MARK: - Status
    private var status: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(videoURL == nil ? mutedText : cyanBright)
                .frame(width: 7, height: 7)

            Text(videoName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(videoURL == nil ? mutedText : cyanBright)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Settings Panel
    private var settingsPanel: some View {
        VStack(spacing: 13) {
            sectionHeading("PLATFORM", detail: platform, highlight: true)

            HStack(spacing: 6) {
                ForEach(platforms, id: \.self) { name in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            platform = name
                        }
                    } label: {
                        SocialPlatformLogo(platform: name)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .foregroundStyle(platform == name ? cyanBright : mutedText)
                            .background(
                                platform == name
                                    ? cyanAccent.opacity(0.2)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        platform == name
                                            ? cyanAccent.opacity(0.65)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(4)
            .background(
                Color.black.opacity(0.28),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            Divider().overlay(Color.white.opacity(0.1))

            sectionHeading("RESOLUTION", detail: resolutionDetail)
            choiceRow(resolutions, selection: $resolution)

            Divider().overlay(Color.white.opacity(0.1))

            sectionHeading(
                "FRAME RATE",
                detail: fps == "60 FPS" ? "Smooth" : "Standard"
            )
            choiceRow(rates, selection: $fps)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(glassBorder, lineWidth: 1)
        )
    }

    private var resolutionDetail: String {
        switch resolution {
        case "720p": return "HD"
        case "1080p": return "Full HD"
        default: return "Ultra HD"
        }
    }

    private func sectionHeading(
        _ title: String,
        detail: String,
        highlight: Bool = false
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(mutedText)

            Spacer()

            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlight ? cyanBright : mutedText)
        }
    }

    private func choiceRow(
        _ options: [String],
        selection: Binding<String>
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selection.wrappedValue = option
                    }
                } label: {
                    let isSelected = selection.wrappedValue == option
                    Text(option)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(isSelected ? cyanBright : mutedText)
                        .background(
                            isSelected
                                ? cyanAccent.opacity(0.2)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? cyanAccent.opacity(0.65)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Color.black.opacity(0.28),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    // MARK: - Export Button
    private var exportButton: some View {
        Button {
            Task {
                await exportVideo()
            }
        } label: {
            HStack(spacing: 10) {
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(isProcessing ? "Processing Video..." : "Enhance & Export")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                LinearGradient(
                    colors: [cyanAccent, indigoAccent],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
        }
        .disabled(videoURL == nil || isProcessing)
        .opacity(videoURL == nil || isProcessing ? 0.55 : 1)
    }

    // MARK: - Video Import & Export
    @MainActor
    private func loadVideo(_ item: PhotosPickerItem?) async {
        videoURL = nil
        exportedVideoURL = nil
        exportError = nil

        guard let item else {
            videoName = "Ready to import"
            return
        }

        videoName = "Loading video..."

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                videoName = "Unable to load video"
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")

            try data.write(to: url, options: .atomic)

            videoURL = url
            videoName = "Video imported · \(resolution) · \(fps)"
        } catch {
            exportError = error.localizedDescription
            videoName = "Import failed"
        }
    }

    private func resolvedPreset(for asset: AVAsset) -> String {
        let desired: String
        switch resolution {
        case "720p": desired = AVAssetExportPreset1280x720
        case "1080p": desired = AVAssetExportPreset1920x1080
        default: desired = AVAssetExportPreset3840x2160
        }

        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        if compatible.contains(desired) {
            return desired
        }
        return compatible.contains(AVAssetExportPresetHighestQuality)
            ? AVAssetExportPresetHighestQuality
            : (compatible.first ?? AVAssetExportPresetMediumQuality)
    }

    @MainActor
    private func exportVideo() async {
        guard let videoURL else {
            videoName = "Please import a video"
            return
        }

        isProcessing = true
        exportError = nil
        exportedVideoURL = nil
        videoName = "Processing \(resolution) (\(fps))..."

        defer {
            isProcessing = false
        }

        do {
            let asset = AVURLAsset(url: videoURL)
            let preset = resolvedPreset(for: asset)

            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: preset
            ) else {
                throw NSError(
                    domain: "NaisePlus",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unable to create export session"
                    ]
                )
            }

            let composition = AVMutableVideoComposition(
                asset: asset,
                applyingCIFiltersWithHandler: { request in
                    request.finish(with: request.sourceImage, context: nil)
                }
            )
            let targetFPS: Int32 = fps == "60 FPS" ? 60 : 30
            composition.frameDuration = CMTime(value: 1, timescale: targetFPS)
            session.videoComposition = composition

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("NaisePlus_\(UUID().uuidString)")
                .appendingPathExtension("mp4")

            try await session.export(to: outputURL, as: .mp4)

            exportedVideoURL = outputURL
            videoName = "Exported for \(platform) · \(resolution)"
        } catch {
            exportError = error.localizedDescription
            videoName = "Export failed"
        }
    }
}

// MARK: - Custom Vector Social Logos
private struct SocialPlatformLogo: View {
    let platform: String

    var body: some View {
        switch platform {
        case "Instagram":
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .stroke(lineWidth: 1.8)
                    .frame(width: 19, height: 19)
                Circle()
                    .stroke(lineWidth: 1.8)
                    .frame(width: 8.5, height: 8.5)
                Circle()
                    .fill()
                    .frame(width: 2.3, height: 2.3)
                    .offset(x: 5.2, y: -5.2)
            }

        case "TikTok":
            TikTokShape()
                .fill(style: FillStyle(eoFill: false))
                .frame(width: 17, height: 19)

        case "WhatsApp":
            ZStack {
                WhatsAppBubbleShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 19, height: 19)
                WhatsAppPhoneShape()
                    .fill()
                    .frame(width: 9.5, height: 9.5)
            }

        default: // Facebook
            FacebookFShape()
                .fill()
                .frame(width: 11, height: 19)
        }
    }
}

private struct TikTokShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.68, y: h * 0.05))
        p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.05))
        p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.67))
        p.addCurve(
            to: CGPoint(x: w * 0.34, y: h * 0.80),
            control1: CGPoint(x: w * 0.50, y: h * 0.75),
            control2: CGPoint(x: w * 0.43, y: h * 0.80)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.19, y: h * 0.66),
            control1: CGPoint(x: w * 0.25, y: h * 0.80),
            control2: CGPoint(x: w * 0.19, y: h * 0.74)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.38, y: h * 0.52),
            control1: CGPoint(x: w * 0.19, y: h * 0.57),
            control2: CGPoint(x: w * 0.28, y: h * 0.50)
        )
        p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.36))
        p.addCurve(
            to: CGPoint(x: w * 0.03, y: h * 0.66),
            control1: CGPoint(x: w * 0.18, y: h * 0.34),
            control2: CGPoint(x: w * 0.03, y: h * 0.48)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.35, y: h * 0.96),
            control1: CGPoint(x: w * 0.03, y: h * 0.83),
            control2: CGPoint(x: w * 0.18, y: h * 0.96)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.67, y: h * 0.66),
            control1: CGPoint(x: w * 0.53, y: h * 0.96),
            control2: CGPoint(x: w * 0.67, y: h * 0.83)
        )
        p.addLine(to: CGPoint(x: w * 0.67, y: h * 0.35))
        p.addCurve(
            to: CGPoint(x: w * 0.96, y: h * 0.43),
            control1: CGPoint(x: w * 0.76, y: h * 0.40),
            control2: CGPoint(x: w * 0.86, y: h * 0.43)
        )
        p.addLine(to: CGPoint(x: w * 0.96, y: h * 0.27))
        p.addCurve(
            to: CGPoint(x: w * 0.68, y: h * 0.05),
            control1: CGPoint(x: w * 0.80, y: h * 0.26),
            control2: CGPoint(x: w * 0.69, y: h * 0.17)
        )
        p.closeSubpath()
        return p
    }
}

private struct WhatsAppBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.12, y: h * 0.90))
        p.addLine(to: CGPoint(x: w * 0.21, y: h * 0.68))
        p.addArc(
            center: CGPoint(x: w * 0.52, y: h * 0.48),
            radius: w * 0.44,
            startAngle: .degrees(145),
            endAngle: .degrees(115),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

private struct WhatsAppPhoneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.22, y: h * 0.10))
        p.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.34), control: CGPoint(x: w * 0.42, y: h * 0.14))
        p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.44))
        p.addQuadCurve(to: CGPoint(x: w * 0.60, y: h * 0.68), control: CGPoint(x: w * 0.42, y: h * 0.60))
        p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.60))
        p.addQuadCurve(to: CGPoint(x: w * 0.92, y: h * 0.80), control: CGPoint(x: w * 0.88, y: h * 0.62))
        p.addQuadCurve(to: CGPoint(x: w * 0.66, y: h * 0.94), control: CGPoint(x: w * 0.86, y: h * 0.96))
        p.addQuadCurve(to: CGPoint(x: w * 0.08, y: h * 0.34), control: CGPoint(x: w * 0.26, y: h * 0.84))
        p.addQuadCurve(to: CGPoint(x: w * 0.22, y: h * 0.10), control: CGPoint(x: w * 0.08, y: h * 0.14))
        p.closeSubpath()
        return p
    }
}

private struct FacebookFShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.64, y: h * 0.98))
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.54))
        p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.54))
        p.addLine(to: CGPoint(x: w * 0.97, y: h * 0.36))
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.36))
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.24))
        p.addCurve(
            to: CGPoint(x: w * 0.82, y: h * 0.16),
            control1: CGPoint(x: w * 0.64, y: h * 0.19),
            control2: CGPoint(x: w * 0.68, y: h * 0.16)
        )
        p.addLine(to: CGPoint(x: w * 0.98, y: h * 0.16))
        p.addLine(to: CGPoint(x: w * 0.98, y: h * 0.02))
        p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.02))
        p.addCurve(
            to: CGPoint(x: w * 0.36, y: h * 0.24),
            control1: CGPoint(x: w * 0.49, y: h * 0.02),
            control2: CGPoint(x: w * 0.36, y: h * 0.11)
        )
        p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.36))
        p.addLine(to: CGPoint(x: w * 0.12, y: h * 0.36))
        p.addLine(to: CGPoint(x: w * 0.12, y: h * 0.54))
        p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.54))
        p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.98))
        p.closeSubpath()
        return p
    }
}

#Preview {
    ContentView()
}