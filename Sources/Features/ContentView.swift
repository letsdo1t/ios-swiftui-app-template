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

    private let blue = Color(red: 0.19, green: 0.52, blue: 1.0)
    private let lightBlue = Color(red: 0.39, green: 0.73, blue: 1.0)
    private let muted = Color(red: 0.62, green: 0.66, blue: 0.75)
    private let platforms = ["Instagram", "TikTok", "WhatsApp", "Facebook"]
    private let resolutions = ["720p", "1080p", "4K"]
    private let rates = ["30 FPS", "60 FPS"]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 28)
                    importArea
                        .padding(.top, 42)
                    status
                        .padding(.top, 17)
                    settingsPanel
                        .padding(.top, 38)
                    exportButton
                        .padding(.top, 44)
                    if let exportedVideoURL {
                        ShareLink(item: exportedVideoURL, preview: SharePreview("Naise+ Video")) {
                            Label("Share / Save Video", systemImage: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 17)
                                .background(Color(red: 0.11, green: 0.35, blue: 0.28))
                                .clipShape(Capsule())
                        }
                        .padding(.top, 15)
                    }
                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.top, 12)
                    }
                    Spacer(minLength: 36)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.055, green: 0.12, blue: 0.23),
                             Color(red: 0.035, green: 0.065, blue: 0.12),
                             Color(red: 0.025, green: 0.045, blue: 0.085)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()
            )
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Naise+")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("AI Video Enhancer")
                    .font(.system(size: 15))
                    .foregroundStyle(muted)
            }
            Spacer()
            Image(systemName: "video")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(lightBlue)
                .frame(width: 53, height: 53)
                .background(blue.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(blue.opacity(0.55), lineWidth: 1))
        }
    }

    private var importArea: some View {
        PhotosPicker(selection: $selectedVideo, matching: .videos) {
            VStack(spacing: 17) {
                Image(systemName: "plus")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(lightBlue)
                    .frame(width: 54, height: 54)
                    .background(blue.opacity(0.22), in: Circle())
                Text("Import Video")
                    .font(.system(size: 20, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 198)
            .background(Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25)
                .stroke(blue.opacity(0.75), lineWidth: 1.2))
        }
        .onChange(of: selectedVideo) { _, item in
            Task { await loadVideo(item) }
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(videoURL == nil ? muted : lightBlue)
                .frame(width: 8, height: 8)
            Text(videoName)
                .font(.system(size: 14))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsPanel: some View {
        VStack(spacing: 19) {
            sectionHeading("PLATFORM", detail: platform)
            HStack(spacing: 4) {
                ForEach(platforms, id: \.self) { name in
                    Button { platform = name } label: {
                        Group {
                            switch name {
                            case "Instagram": Image(systemName: "camera")
                            case "TikTok": Image(systemName: "music.note")
                            case "WhatsApp": Image(systemName: "phone.bubble")
                            default: Text("f").fontWeight(.bold)
                            }
                        }
                        .font(.system(size: 23))
                        .frame(maxWidth: .infinity)
                        .frame(height: 47)
                        .foregroundStyle(platform == name ? lightBlue : muted)
                        .background(platform == name ? blue.opacity(0.22) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(platform == name ? blue : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(4)
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 14))

            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            sectionHeading("RESOLUTION", detail: resolution == "1080p" ? "Full HD" : resolution)
            choiceRow(resolutions, selection: $resolution)
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            sectionHeading("FRAME RATE", detail: fps == "60 FPS" ? "Smooth" : "Standard")
            choiceRow(rates, selection: $fps)
        }
        .padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .stroke(Color.white.opacity(0.11), lineWidth: 1))
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(muted)
            Spacer()
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(title == "PLATFORM" ? lightBlue : muted)
        }
    }

    private func choiceRow(_ values: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                Button { selection.wrappedValue = value } label: {
                    Text(value)
                        .font(.system(size: 16, weight: selection.wrappedValue == value ? .semibold : .regular))
                        .foregroundStyle(selection.wrappedValue == value ? lightBlue : muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 43)
                        .background(selection.wrappedValue == value ? blue.opacity(0.23) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(selection.wrappedValue == value ? blue : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 14))
    }

    private var exportButton: some View {
        Button { exportVideo() } label: {
            HStack(spacing: 12) {
                if isProcessing { ProgressView().tint(.white) }
                else { Image(systemName: "sparkles") }
                Text(isProcessing ? "Processing..." : "Enhance & Export")
            }
            .font(.system(size: 19, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 59)
            .background(LinearGradient(colors: [blue, Color(red: 0.12, green: 0.43, blue: 1)], startPoint: .leading, endPoint: .trailing))
            .clipShape(Capsule())
            .opacity(videoURL == nil || isProcessing ? 0.6 : 1)
        }
        .disabled(videoURL == nil || isProcessing)
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
        videoName = "Importing video..."
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                videoName = "Unable to import video"
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try data.write(to: url)
            videoURL = url
            videoName = "Video ready"
        } catch {
            videoName = "Import failed"
            exportError = error.localizedDescription
        }
    }

    private func exportVideo() {
        guard let videoURL else { return }
        isProcessing = true
        exportError = nil
        exportedVideoURL = nil
        videoName = "Exporting video..."
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: videoURL)
                guard let session = AVAssetExportSession(
                    asset: asset, presetName: AVAssetExportPresetHighestQuality
                ) else {
                    throw NSError(domain: "NaisePlus", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Unable to start export"])
                }
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")
                try await session.export(to: output, as: .mp4)
                exportedVideoURL = output
                videoName = "Video exported successfully"
            } catch {
                exportError = error.localizedDescription
                videoName = "Export failed"
            }
            isProcessing = false
        }
    }
}

#Preview {
    ContentView()
}
