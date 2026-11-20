import SwiftUI
import PhotosUI
import AVFoundation

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

    // Palet Arctic Ice
    private let bgTop = Color(red: 0.03, green: 0.08, blue: 0.13)
    private let bgBottom = Color(red: 0.02, green: 0.03, blue: 0.05)
    private let surface = Color(red: 0.06, green: 0.09, blue: 0.14)
    private let iceCyan = Color(red: 0.22, green: 0.74, blue: 0.97)   // #38BDF8
    private let iceBright = Color(red: 0.49, green: 0.83, blue: 0.99) // #7DD3FC
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
                        ShareLink(item: exportedVideoURL, preview: SharePreview("Naise+ Video")) {
                            Label("Share / Save Video", systemImage: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(iceBright)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(iceCyan.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(iceCyan.opacity(0.45), lineWidth: 1)
                                )
                        }
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    // MARK: - Header
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Naise+")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text("AI Video Enhancer")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(muted)
            }
            Spacer()
            Image(systemName: "video.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iceBright)
                .frame(width: 48, height: 48)
                .background(iceCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(iceCyan.opacity(0.35), lineWidth: 1)
                )
        }
    }

    // MARK: - Import Area
    private var importArea: some View {
        PhotosPicker(selection: $selectedVideo, matching: .videos) {
            VStack(spacing: 14) {
                Image(systemName: videoURL == nil ? "plus" : "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(iceBright)
                    .frame(width: 52, height: 52)
                    .background(iceCyan.opacity(0.16), in: Circle())

                VStack(spacing: 4) {
                    Text(videoURL == nil ? "Import Video" : "Change Video")
                        .font(.system(size: 18, weight: .semibold))
                    Text(videoURL == nil ? "Select from Photos library" : "Tap to replace current clip")
                        .font(.system(size: 13))
                        .foregroundStyle(muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 184)
            .background(videoURL == nil ? surface.opacity(0.75) : iceCyan.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        iceCyan.opacity(videoURL == nil ? 0.35 : 0.75),
                        style: StrokeStyle(lineWidth: 1.4, dash: videoURL == nil ? [6, 5] : [])
                    )
            )
        }
        .onChange(of: selectedVideo) { _, item in
            Task { await loadVideo(item) }
        }
    }

    // MARK: - Status
    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(videoURL == nil ? muted.opacity(0.6) : iceBright)
                .frame(width: 7, height: 7)
            Text(videoName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(videoURL == nil ? muted : iceBright)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Settings Panel
    private var settingsPanel: some View {
        VStack(spacing: 18) {
            sectionHeading("PLATFORM", detail: platform, highlight: true)
            HStack(spacing: 6) {
                ForEach(platforms, id: \.self) { name in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            platform = name
                        }
                    } label: {
                        PlatformGlyph(name: name)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(platform == name ? iceBright : muted)
                            .background(platform == name ? iceCyan.opacity(0.18) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(platform == name ? iceCyan.opacity(0.65) : .clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(4)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Divider().overlay(Color.white.opacity(0.08))

            sectionHeading("RESOLUTION", detail: resolutionDetail)
            choiceRow(resolutions, selection: $resolution)

            Divider().overlay(Color.white.opacity(0.08))

            sectionHeading("FRAME RATE", detail: fps == "60 FPS" ? "Smooth" : "Standard")
            choiceRow(rates, selection: $fps)
        }
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(iceCyan.opacity(0.14), lineWidth: 1)
        )
    }

    private var resolutionDetail: String {
        switch resolution {
        case "720p": return "HD"
        case "1080p": return "Full HD"
        default: return "Ultra HD"
        }
    }

    private func sectionHeading(_ title: String, detail: String, highlight: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(muted)
            Spacer()
            Text(detail)
                .font(.system(size: 12, weight: .semibold