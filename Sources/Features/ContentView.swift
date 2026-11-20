import SwiftUI
import PhotosUI
import AVFoundation

struct ContentView: View {
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isProcessing = false
    @State private var exportedVideoURL: URL?
    @State private var exportError: String?
    @State private var videoName = "Belum pilih video"
    @State private var platform = "Instagram"
    @State private var resolution = "1080p"
    @State private var fps = "60 FPS"

    let platforms = ["Instagram", "TikTok", "WhatsApp", "Facebook"]
    let resolutions = ["720p", "1080p", "4K"]
    let frameRates = ["30 FPS", "60 FPS"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "video.badge.waveform")
                        .font(.system(size: 65))
                        .foregroundStyle(.cyan)

                    Text("CLEAR VIDEO")
                        .font(.system(size: 30, weight: .bold))

                    Text("Video Enhancer for iOS")
                        .foregroundStyle(.secondary)

                    PhotosPicker(
                        selection: $selectedVideo,
                        matching: .videos
                    ) {
                        Label("Import Video", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.cyan)
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onChange(of: selectedVideo) { _, newVideo in
    guard let newVideo else {
        videoURL = nil
        videoName = "Belum pilih video"
        return
    }

    Task {
        videoName = "Sedang membaca video..."

        do {
            guard let data = try await newVideo.loadTransferable(type: Data.self) else {
                videoName = "Gagal membaca video"
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")

            try data.write(to: url)

            videoURL = url
            videoName = "Video berjaya dimuatkan ✅"
        } catch {
            videoURL = nil
            videoName = "Ralat membaca video: \(error.localizedDescription)"
        }
    }
}

                    Text(videoName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Platform")
                            .font(.headline)

                        Picker("Platform", selection: $platform) {
                            ForEach(platforms, id: \.self) { item in
                                Text(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Resolution")
                            .font(.headline)

                        Picker("Resolution", selection: $resolution) {
                            ForEach(resolutions, id: \.self) { item in
                                Text(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Frame Rate")
                            .font(.headline)

                        Picker("FPS", selection: $fps) {
                            ForEach(frameRates, id: \.self) { item in
                                Text(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .background(.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    Button(action: {
    exportVideo()
}) {
                        Label("Enhance & Export", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(selectedVideo == nil)

                    Text("High Quality • Smooth • Clean")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.black)
            .foregroundStyle(.white)
            .navigationTitle("Clear Video")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
extension ContentView {
    func exportVideo() {
        guard let videoURL else {
            videoName = "Sila pilih video dahulu"
            return
        }

        isProcessing = true
        exportError = nil
        exportedVideoURL = nil
        videoName = "Sedang menyediakan video..."

        Task {
            do {
                let asset = AVURLAsset(url: videoURL)

                guard let session = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetHighestQuality
                ) else {
                    throw NSError(
                        domain: "NaisePlus",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Tidak dapat menyediakan eksport"
                        ]
                    )
                }

                let outputURL = FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")

                try await session.export(
                    to: outputURL,
                    as: .mp4
                )

                exportedVideoURL = outputURL
                videoName = "Video berjaya dieksport ✅"

            } catch {
                exportError = error.localizedDescription
                videoName = "Eksport gagal"
            }

            isProcessing = false
        }
    }
}
#Preview {
    ContentView()
}