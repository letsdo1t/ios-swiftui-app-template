import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

enum NaiseTheme: String, CaseIterable, Identifiable {
    case obsidianOLED = "01 · Obsidian OLED"
    case frostedGlass = "02 · Frosted Glass"
    case daylightAlabaster = "03 · Daylight Alabaster"
    case monochromePro = "04 · Monochrome Pro"
    case emeraldTitanium = "05 · Emerald Titanium"

    var id: String { rawValue }

    var shortBadge: String {
        switch self {
        case .obsidianOLED: return "OLED"
        case .frostedGlass: return "GLASS"
        case .daylightAlabaster: return "LIGHT"
        case .monochromePro: return "REC"
        case .emeraldTitanium: return "PRO"
        }
    }

    var isLight: Bool {
        self == .daylightAlabaster
    }

    var bgTop: Color {
        switch self {
        case .obsidianOLED: return .black
        case .frostedGlass: return Color(red: 0.08, green: 0.14, blue: 0.24)
        case .daylightAlabaster: return Color(red: 0.97, green: 0.97, blue: 0.96)
        case .monochromePro: return Color(red: 0.07, green: 0.07, blue: 0.08)
        case .emeraldTitanium: return Color(red: 0.04, green: 0.09, blue: 0.07)
        }
    }

    var bgBottom: Color {
        switch self {
        case .obsidianOLED: return .black
        case .frostedGlass: return Color(red: 0.04, green: 0.05, blue: 0.09)
        case .daylightAlabaster: return Color(red: 0.95, green: 0.95, blue: 0.94)
        case .monochromePro: return Color(red: 0.06, green: 0.06, blue: 0.07)
        case .emeraldTitanium: return Color(red: 0.03, green: 0.05, blue: 0.04)
        }
    }

    var surface: Color {
        switch self {
        case .obsidianOLED: return Color(red: 0.05, green: 0.06, blue: 0.08)
        case .frostedGlass: return Color.white.opacity(0.07)
        case .daylightAlabaster: return .white
        case .monochromePro: return Color(red: 0.09, green: 0.10, blue: 0.11)
        case .emeraldTitanium: return Color(red: 0.06, green: 0.09, blue: 0.08)
        }
    }

    var segmentWell: Color {
        isLight ? Color(red: 0.94, green: 0.95, blue: 0.96) : Color.black.opacity(0.35)
    }

    var accent: Color {
        switch self {
        case .obsidianOLED: return Color(red: 0.49, green: 0.83, blue: 0.99)
        case .frostedGlass: return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .daylightAlabaster: return Color(red: 0.08, green: 0.09, blue: 0.10)
        case .monochromePro: return Color(red: 0.96, green: 0.96, blue: 0.98)
        case .emeraldTitanium: return Color(red: 0.20, green: 0.83, blue: 0.60)
        }
    }

    var badgeAccent: Color {
        self == .monochromePro ? Color(red: 0.97, green: 0.44, blue: 0.44) : accent
    }

    var primaryText: Color {
        isLight ? Color(red: 0.08, green: 0.09, blue: 0.10) : .white
    }

    var mutedText: Color {
        isLight ? Color(red: 0.42, green: 0.46, blue: 0.52) : Color(red: 0.56, green: 0.62, blue: 0.69)
    }

    var ctaText: Color {
        switch self {
        case .daylightAlabaster: return .white
        case .obsidianOLED, .frostedGlass, .monochromePro, .emeraldTitanium:
            return Color(red: 0.03, green: 0.06, blue: 0.08)
        }
    }
}

struct ContentView: View {
    @State private var selectedTheme: NaiseTheme = .emeraldTitanium
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var exportedVideoURL: URL?
    @State private var videoName = "Ready to import"
    @State private var isProcessing = false
    @State private var exportError: String?
    @State private var platform = "Instagram"
    @State private var resolution = "1080p"
    @State private var fps = "60 FPS"

    private let platforms = ["Instagram", "TikTok", "WhatsApp", "Facebook"]
    private let resolutions = ["720p", "1080p", "4K"]
    private let rates = ["30 FPS", "60 FPS"]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    themeSwitcher
                        .padding(.top, 14)

                    header
                        .padding(.top, 20)

                    importArea
                        .padding(.top, 28)

                    status
                        .padding(.top, 14)

                    settingsPanel
                        .padding(.top, 26)

                    exportButton
                        .padding(.top, 30)

                    if let exportedVideoURL {
                        ShareLink(item: exportedVideoURL) {
                            Label("Share / Save Video", systemImage: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(selectedTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(selectedTheme.accent.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(selectedTheme.accent.opacity(0.45), lineWidth: 1)
                                )
                        }
                        .padding(.top, 14)
                    }

                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .background(
                LinearGradient(
                    colors: [selectedTheme.bgTop, selectedTheme.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
        .foregroundStyle(selectedTheme.primaryText)
        .preferredColorScheme(selectedTheme.isLight ? .light : .dark)
    }

    private var themeSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NaiseTheme.allCases) { theme in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            selectedTheme = theme
                        }
                    } label: {
                        Text(theme.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(
                                selectedTheme == theme
                                    ? selectedTheme.ctaText
                                    : selectedTheme.mutedText
                            )
                            .background(
                                selectedTheme == theme
                                    ? selectedTheme.accent
                                    : selectedTheme.surface
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(selectedTheme.accent.opacity(0.22), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Naise+")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("AI Video Enhancer")
                    .font(.system(size: 14))
                    .foregroundStyle(selectedTheme.mutedText)
            }

            Spacer()

            Text(selectedTheme.shortBadge)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(selectedTheme.badgeAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    selectedTheme.badgeAccent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selectedTheme.badgeAccent.opacity(0.35), lineWidth: 1)
                )
        }
    }

    private var importArea: some View {
        PhotosPicker(selection: $selectedVideo, matching: .videos) {
            VStack(spacing: 14) {
                Image(systemName: videoURL == nil ? "plus" : "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(selectedTheme.accent)
                    .frame(width: 52, height: 52)
                    .background(selectedTheme.accent.opacity(0.15), in: Circle())

                Text(videoURL == nil ? "Import Video" : "Change Video")
                    .font(.system(size: 18, weight: .semibold))

                Text(videoURL == nil
                     ? "Select from Photos library"
                     : "Tap to replace current clip")
                    .font(.system(size: 13))
                    .foregroundStyle(selectedTheme.mutedText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(selectedTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        selectedTheme.accent.opacity(videoURL == nil ? 0.45 : 0.8),
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

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(videoURL == nil ? selectedTheme.mutedText : selectedTheme.accent)
                .frame(width: 7, height: 7)

            Text(videoName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(videoURL == nil ? selectedTheme.mutedText : selectedTheme.accent)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsPanel: some View {
        VStack(spacing: 18) {
            sectionHeading("PLATFORM", detail: platform, highlight: true)

            HStack(spacing: 6) {
                ForEach(platforms, id: \.self) { name in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            platform = name
                        }
                    } label: {
                        Image(systemName: platformIcon(name))
                            .font(.system(size: 19))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(
                                platform == name
                                    ? (selectedTheme.isLight ? .white : selectedTheme.accent)
                                    : selectedTheme.mutedText
                            )
                            .background(
                                platform == name
                                    ? (selectedTheme.isLight ? selectedTheme.accent : selectedTheme.accent.opacity(0.18))
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(
                                        platform == name
                                            ? selectedTheme.accent.opacity(0.65)
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
                selectedTheme.segmentWell,
                in: RoundedRectangle(cornerRadius: 15)
            )

            Divider()

            sectionHeading("RESOLUTION", detail: resolutionDetail)
            choiceRow(resolutions, selection: $resolution)

            Divider()

            sectionHeading(
                "FRAME RATE",
                detail: fps == "60 FPS" ? "Smooth" : "Standard"
            )
            choiceRow(rates, selection: $fps)
        }
        .padding(18)
        .background(selectedTheme.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(selectedTheme.accent.opacity(0.14), lineWidth: 1)
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
                .foregroundStyle(selectedTheme.mutedText)

            Spacer()

            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlight ? selectedTheme.accent : selectedTheme.mutedText)
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
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 43)
                        .foregroundStyle(
                            isSelected
                                ? (selectedTheme.isLight ? .white : selectedTheme.accent)
                                : selectedTheme.mutedText
                        )
                        .background(
                            isSelected
                                ? (selectedTheme.isLight ? selectedTheme.accent : selectedTheme.accent.opacity(0.18))
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(
                                    isSelected
                                        ? selectedTheme.accent.opacity(0.65)
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
            selectedTheme.segmentWell,
            in: RoundedRectangle(cornerRadius: 15)
        )
    }

    private func platformIcon(_ name: String) -> String {
        switch name {
        case "Instagram": return "camera"
        case "TikTok": return "music.note"
        case "WhatsApp": return "message"
        default: return "f.circle"
        }
    }

    private var exportButton: some View {
        Button {
            Task {
                await exportVideo()
            }
        } label: {
            HStack(spacing: 12) {
                if isProcessing {
                    ProgressView()
                        .tint(selectedTheme.ctaText)
                } else {
                    Image(systemName: "sparkles")
                }

                Text(isProcessing ? "Processing Video..." : "Enhance & Export")
            }
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(selectedTheme.ctaText)
            .background(
                selectedTheme == .frostedGlass
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.74, blue: 0.97),
                                Color(red: 0.51, green: 0.55, blue: 0.97)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    : AnyShapeStyle(selectedTheme.accent)
            )
            .clipShape(Capsule())
        }
        .disabled(videoURL == nil || isProcessing)
        .opacity(videoURL == nil || isProcessing ? 0.55 : 1)
    }

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

    private func resolvedPreset(for asset: AVAsset) async -> String {
        let desired: String
        switch resolution {
        case "720p": desired = AVAssetExportPreset1280x720
        case "1080p": desired = AVAssetExportPreset1920x1080
        default: desired = AVAssetExportPreset3840x2160
        }

        let compatible = await AVAssetExportSession.exportPresets(compatibleWith: asset)
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
            let preset = await resolvedPreset(for: asset)

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

            let composition = try await AVMutableVideoComposition.videoComposition(with: asset)
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

#Preview {
    ContentView()
}