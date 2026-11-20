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

    private let bgTop = Color(red: 0.03, green: 0.08, blue: 0.13)
    private let bgBottom = Color(red: 0.02, green: 0.03, blue: 0.05)
    private let surface = Color(red: 0.06, green: 0.09, blue: 0.14)
    private let iceCyan = Color(red: 0.22, green: 0.74, blue: 0.97)
    private let iceBright = Color(red: 0.49, green: 0.83, blue: 0.99)
    private let muted = Color(red: 0.56, green: 0.64, blue: 0.72)

    private let platforms = ["Instagram", "TikTok", "WhatsApp", "Facebook"]
    private let resolutions = ["720p", "1080p", "4K"]
    private let rates = ["30 FPS", "60 FPS"]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 24)

                    importArea
                        .padding(.top, 32)

                    status
                        .padding(.top, 16)

                    settingsPanel
                        .padding(.top, 30)

                    exportButton
                        .padding(.top, 34)

                    if let exportedVideoURL {
                        ShareLink(item: exportedVideoURL) {
                            Label("Share / Save Video", systemImage: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(iceBright)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(iceCyan.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(iceCyan.opacity(0.45), lineWidth: 1)
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
                    colors: [bgTop, bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Naise+")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("AI Video Enhancer")
                    .font(.system(size: 14))
                    .foregroundStyle(muted)
            }

            Spacer()

            Image(systemName: "video.fill")
                .font(.system(size: 20))
                .foregroundStyle(iceBright)
                .frame(width: 48, height: 48)
                .background(
                    iceCyan.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(iceCyan.opacity(0.35), lineWidth: 1)
                )
        }
    }

    private var importArea: some View {
        PhotosPicker(selection: $selectedVideo, matching: .videos) {
            VStack(spacing: 14) {
                Image(systemName: videoURL == nil ? "plus" : "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(iceBright)
                    .frame(width: 52, height: 52)
                    .background(iceCyan.opacity(0.16), in: Circle())

                Text(videoURL == nil ? "Import Video" : "Change Video")
                    .font(.system(size: 18, weight: .semibold))

                Text(videoURL == nil
                     ? "Select from Photos library"
                     : "Tap to replace current clip")
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 184)
            .background(surface.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        iceCyan.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.4, dash: [6, 5])
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
                .fill(videoURL == nil ? muted : iceBright)
                .frame(width: 7, height: 7)

            Text(videoName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(videoURL == nil ? muted : iceBright)
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
                        platform = name
                    } label: {
                        Image(systemName: platformIcon(name))
                            .font(.system(size: 20))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(platform == name ? iceBright : muted)
                            .background(
                                platform == name
                                    ? iceCyan.opacity(0.18)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(
                                        platform == name
                                            ? iceCyan.opacity(0.65)
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
                Color.black.opacity(0.35),
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
        .background(surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(iceCyan.opacity(0.14), lineWidth: 1)
        )
    }

    private var resolutionDetail: String {
        switch resolution {
        case "720p":
            return "HD"
        case "1080p":
            return "Full HD"
        default:
            return "Ultra HD"
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
                .foregroundStyle(muted)

            Spacer()

            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlight ? iceBright : muted)
        }
    }

    private func choiceRow(
        _ options: [String],
        selection: Binding<String>
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    Text(option)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 43)
                        .foregroundStyle(
                            selection.wrappedValue == option
                                ? iceBright
                                : muted
                        )
                        .background(
                            selection.wrappedValue == option
                                ? iceCyan.opacity(0.18)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(
                                    selection.wrappedValue == option
                                        ? iceCyan.opacity(0.65)
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
            Color.black.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 15)
        )
    }

    private func platformIcon(_ name: String) -> String {
        switch name {
        case "Instagram":
            return "camera"
        case "TikTok":
            return "music.note"
        case "WhatsApp":
            return "message"
        default:
            return "f.circle"
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
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                }

                Text(isProcessing ? "Processing Video..." : "Enhance & Export")
            }
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.47, blue: 0.98),
                        Color(red: 0.18, green: 0.65, blue: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
        }
        .disabled(videoURL == nil || isProcessing)
        .opacity(videoURL == nil || isProcessing ? 0.6 : 1)
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
            videoName = "Video imported successfully"
        } catch {
            exportError = error.localizedDescription
            videoName = "Import failed"
        }
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
        videoName = "Processing video..."

        defer {
            isProcessing = false
        }

        do {
            let asset = AVURLAsset(url: videoURL)

            let preset: String
            switch resolution {
            case "720p":
                preset = AVAssetExportPreset1280x720
            case "1080p":
                preset = AVAssetExportPreset1920x1080
            default:
                preset = AVAssetExportPreset3840x2160
            }

            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: preset
            ) else {
                throw NSError(
                    domain: "NaisePlus",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unable to create export session"
                    ]
                )
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")

            try await session.export(to: outputURL, as: .mp4)

            exportedVideoURL = outputURL
            videoName = "Video exported successfully"
        } catch {
            exportError = error.localizedDescription
            videoName = "Export failed"
        }
    }
}

#Preview {
    ContentView()
}