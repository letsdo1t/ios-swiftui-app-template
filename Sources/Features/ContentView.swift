import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var selectedVideo: PhotosPickerItem?
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
                    }.onChange(of: selectedVideo) { _, newVideo in
    if newVideo != nil {
        videoName = "Video berjaya dipilih ✅"
    } else {
        videoName = "Belum pilih video"
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
    videoName = "Sedang menyediakan video..."
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

#Preview {
    ContentView()
}