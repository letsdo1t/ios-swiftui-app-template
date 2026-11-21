import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

private enum EnhanceStep: String, CaseIterable, Identifiable {
    case importClip = "Import"
    case profile = "Profile"
    case render = "Render"
    case ready = "Ready"
    var id: String { rawValue }
}

private struct StatusLogEntry: Identifiable {
    let id = UUID()
    let timeText: String
    let message: String
}

private struct SourceClipInfo {
    let width: Int
    let height: Int
    let durationSeconds: Double

    var summary: String {
        let mins = Int(durationSeconds) / 60
        let secs = Int(durationSeconds) % 60
        return "\(width)×\(height) · \(String(format: "%d:%02d", mins, secs))"
    }
}

private struct ExportProfile {
    let outputSize: CGSize
    let targetFPS: Int32
    let presetName: String
    let bitrateMbps: Double
}

private struct ExportedVideoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Movie, .movie] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        return FileWrapper(regularFileWithContents: data)
    }
}

struct ContentView: View {
    @State private var isLightMode = false
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var exportedVideoURL: URL?
    @State private var isShowingFileExporter = false
    @State private var sourceInfo: SourceClipInfo?
    @State private var statusTitle = "Ready to import"
    @State private var statusDetail = "Select a clean clip for Story / Reels"
    @State private var currentStep: EnhanceStep = .importClip
    @State private var renderProgress: Double = 0
    @State private var logs: [StatusLogEntry] = [
        StatusLogEntry(timeText: "NOW", message: "Naise+ pro export engine ready")
    ]
    @State private var isProcessing = false
    @State private var exportError: String?
    @State private var platform = "Instagram"
    @State private var resolution = "1080p"
    @State private var fps = "60 FPS"

    private let darkBgTop = Color(red: 0.08, green: 0.14, blue: 0.24)
    private let darkBgMid = Color(red: 0.05, green: 0.08, blue: 0.15)
    private let darkBgBottom = Color(red: 0.04, green: 0.05, blue: 0.09)
    private let darkMuted = Color(red: 0.58, green: 0.65, blue: 0.74)
    private let lightBgTop = Color(red: 0.90, green: 0.95, blue: 0.99)
    private let lightBgMid = Color(red: 0.95, green: 0.97, blue: 1.00)
    private let lightBgBottom = Color(red: 0.92, green: 0.94, blue: 0.98)
    private let lightPrimary = Color(red: 0.07, green: 0.11, blue: 0.18)
    private let lightMuted = Color(red: 0.38, green: 0.45, blue: 0.56)
    private let cyanAccent = Color(red: 0.22, green: 0.74, blue: 0.97)
    private let cyanBright = Color(red: 0.49, green: 0.83, blue: 0.99)
    private let cyanDeep = Color(red: 0.06, green: 0.48, blue: 0.76)
    private let indigoAccent = Color(red: 0.51, green: 0.55, blue: 0.97)

    private var primaryText: Color { isLightMode ? lightPrimary : .white }
    private var mutedText: Color { isLightMode ? lightMuted : darkMuted }
    private var activeAccent: Color { isLightMode ? cyanDeep : cyanBright }
    private var glassBorder: Color { isLightMode ? Color.black.opacity(0.09) : Color.white.opacity(0.14) }
    private var segmentWell: Color { isLightMode ? Color.white.opacity(0.55) : Color.black.opacity(0.28) }

    private let platforms = ["Instagram", "TikTok", "WhatsApp", "Facebook"]
    private let resolutions = ["720p", "1080p", "4K"]
    private let rates = ["30 FPS", "60 FPS"]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(.top, 10)
                importArea.padding(.top, 12)
                clearStatusCard.padding(.top, 10)
                settingsPanel.padding(.top, 10)
                Spacer(minLength: 8)
                exportButton

                if exportedVideoURL != nil {
                    Button {
                        isShowingFileExporter = true
                    } label: {
                        Label("Save to Files (.mp4)", systemImage: "folder.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(activeAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(cyanAccent.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .fileExporter(
                        isPresented: $isShowingFileExporter,
                        document: ExportedVideoDocument(sourceURL: exportedVideoURL!),
                        contentType: .mpeg4Movie,
                        defaultFilename: "NaisePlus_\(platform)_\(resolution)_\(fps.replacingOccurrences(of: " ", with: ""))"
                    ) { result in
                        switch result {
                        case .success:
                            statusTitle = "Saved to Files"
                            statusDetail = "Video saved in Files app"
                            appendLog("Saved to Files app")
                        case .failure(let error):
                            exportError = error.localizedDescription
                            appendLog("Save to Files cancelled/failed")
                        }
                    }
                }

                if let exportError {
                    Text(exportError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 5)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(maxWidth: 500)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background {
                ZStack {
                    LinearGradient(
                        colors: isLightMode
                            ? [lightBgTop, lightBgMid, lightBgBottom]
                            : [darkBgTop, darkBgMid, darkBgBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Circle().fill(cyanAccent.opacity(isLightMode ? 0.22 : 0.16)).frame(width: 280, height: 280).blur(radius: 70).offset(x: -110, y: -260)
                    Circle().fill(indigoAccent.opacity(isLightMode ? 0.16 : 0.14)).frame(width: 260, height: 260).blur(radius: 75).offset(x: 130, y: 180)
                }
                .ignoresSafeArea()
            }
        }
        .foregroundStyle(primaryText)
        .preferredColorScheme(isLightMode ? .light : .dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Naise+").font(.system(size: 27, weight: .bold, design: .rounded))
                Text("AI Video Enhancer").font(.system(size: 12)).foregroundStyle(mutedText)
            }
            Spacer()
            HStack(spacing: 4) {
                modeButton(icon: "moon.fill", lightTarget: false)
                modeButton(icon: "sun.max.fill", lightTarget: true)
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(glassBorder, lineWidth: 1))
        }
    }

    private func modeButton(icon: String, lightTarget: Bool) -> some View {
        let isSelected = isLightMode == lightTarget
        return Button {
            withAnimation(.snappy(duration: 0.22)) { isLightMode = lightTarget }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? activeAccent : mutedText)
                .frame(width: 32, height: 32)
                .background(isSelected ? cyanAccent.opacity(0.2) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var importArea: some View {
        PhotosPicker(selection: $selectedVideo, matching: .videos) {
            VStack(spacing: 7) {
                Image(systemName: videoURL == nil ? "plus" : "checkmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(activeAccent)
                    .frame(width: 40, height: 40)
                    .background(cyanAccent.opacity(0.18), in: Circle())
                Text(videoURL == nil ? "Import Video" : "Change Video")
                    .font(.system(size: 16, weight: .semibold))
                Text(videoURL == nil ? "Select from Photos library" : (sourceInfo?.summary ?? "Tap to replace current clip"))
                    .font(.system(size: 11)).foregroundStyle(mutedText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        videoURL == nil
                            ? (isLightMode ? Color.black.opacity(0.14) : Color.white.opacity(0.24))
                            : cyanAccent.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1.4, dash: videoURL == nil ? [6, 5] : [])
                    )
            }
        }
        .onChange(of: selectedVideo) { _, item in
            Task { await loadVideo(item) }
        }
    }

    private var clearStatusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(exportError != nil ? Color.red : (isProcessing || videoURL != nil ? activeAccent : mutedText))
                    .frame(width: 7, height: 7)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(exportError != nil ? Color.red : (videoURL == nil ? mutedText : activeAccent))
                    .lineLimit(1)
                Spacer()
                Text(isProcessing ? "\(Int(renderProgress * 100))%" : "\(platform) · \(resolution) · \(fps)")
                    .font(.system(size: 10, weight: .semibold, design: isProcessing ? .monospaced : .default))
                    .foregroundStyle(isProcessing ? activeAccent : mutedText)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                ForEach(EnhanceStep.allCases) { step in
                    let idx = EnhanceStep.allCases.firstIndex(of: step) ?? 0
                    let activeIdx = EnhanceStep.allCases.firstIndex(of: currentStep) ?? 0
                    let done = idx <= activeIdx && (videoURL != nil || step == .importClip)
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(done ? activeAccent : glassBorder)
                            .frame(height: 3)
                        Text(step.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(done ? activeAccent : mutedText)
                    }
                }
            }

            if isProcessing {
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(segmentWell).frame(height: 4)
                        Capsule()
                            .fill(LinearGradient(colors: [cyanAccent, indigoAccent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, bar.size.width * min(1, max(0, renderProgress))), height: 4)
                    }
                }
                .frame(height: 4)
            }

            Text(statusDetail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(mutedText)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(logs.suffix(2)) { entry in
                    HStack(spacing: 6) {
                        Text(entry.timeText)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(activeAccent)
                        Text(entry.message)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(mutedText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(glassBorder, lineWidth: 1))
    }

    private var settingsPanel: some View {
        VStack(spacing: 10) {
            sectionHeading("PLATFORM", detail: platform, highlight: true)
            HStack(spacing: 6) {
                ForEach(platforms, id: \.self) { name in
                    let isSelected = platform == name
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            platform = name
                            appendLog("Target: \(name) Story/Reels")
                        }
                    } label: {
                        SocialPlatformLogo(platform: name)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .foregroundStyle(isSelected ? activeAccent : mutedText)
                            .background(isSelected ? cyanAccent.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? cyanAccent.opacity(0.65) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(4)
            .background(segmentWell, in: RoundedRectangle(cornerRadius: 13))

            Divider().overlay(glassBorder)
            sectionHeading("RESOLUTION", detail: resolutionDetail)
            choiceRow(resolutions, selection: $resolution, labelPrefix: "Res")

            Divider().overlay(glassBorder)
            sectionHeading("FRAME RATE", detail: fps == "60 FPS" ? "Smooth" : "Standard")
            choiceRow(rates, selection: $fps, labelPrefix: "FPS")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(glassBorder, lineWidth: 1))
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
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(mutedText)
            Spacer()
            Text(detail).font(.system(size: 11, weight: .semibold)).foregroundStyle(highlight ? activeAccent : mutedText)
        }
    }

    private func choiceRow(_ options: [String], selection: Binding<String>, labelPrefix: String) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection.wrappedValue == option
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selection.wrappedValue = option
                        if videoURL != nil && !isProcessing {
                            statusDetail = "Clean source · \(resolution) · \(fps)"
                        }
                        appendLog("\(labelPrefix): \(option)")
                    }
                } label: {
                    Text(option)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(isSelected ? activeAccent : mutedText)
                        .background(isSelected ? cyanAccent.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? cyanAccent.opacity(0.65) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(segmentWell, in: RoundedRectangle(cornerRadius: 13))
    }

    private var exportButton: some View {
        Button {
            Task { await exportVideo() }
        } label: {
            HStack(spacing: 10) {
                if isProcessing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                Text(isProcessing ? "Rendering \(fps)..." : "Enhance & Export").foregroundStyle(.white)
            }
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(LinearGradient(colors: [cyanAccent, indigoAccent], startPoint: .leading, endPoint: .trailing))
            .clipShape(Capsule())
        }
        .disabled(videoURL == nil || isProcessing)
        .opacity(videoURL == nil || isProcessing ? 0.55 : 1)
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append(StatusLogEntry(timeText: formatter.string(from: Date()), message: message))
        if logs.count > 16 {
            logs.removeFirst(logs.count - 16)
        }
    }

    private func cleanupTempFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    private func loadVideo(_ item: PhotosPickerItem?) async {
        cleanupTempFile(videoURL)
        cleanupTempFile(exportedVideoURL)
        videoURL = nil
        exportedVideoURL = nil
        sourceInfo = nil
        exportError = nil
        renderProgress = 0

        guard let item else {
            currentStep = .importClip
            statusTitle = "Ready to import"
            statusDetail = "Select a clean clip for Story / Reels"
            appendLog("Cleared clip")
            return
        }

        currentStep = .importClip
        statusTitle = "Importing clip"
        statusDetail = "Loading video from Photos..."
        appendLog("Importing clip")

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                statusTitle = "Import unavailable"
                statusDetail = "Could not read video data"
                appendLog("Empty video data")
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try data.write(to: url, options: .atomic)

            let asset = AVURLAsset(url: url)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let nat = try await track.load(.naturalSize)
                let tf = try await track.load(.preferredTransform)
                let tr = try await track.load(.timeRange)
                let rect = CGRect(origin: .zero, size: nat).applying(tf)
                sourceInfo = SourceClipInfo(
                    width: Int(abs(rect.width)),
                    height: Int(abs(rect.height)),
                    durationSeconds: max(0, CMTimeGetSeconds(tr.duration))
                )
            }

            videoURL = url
            currentStep = .profile
            statusTitle = "Clean source ready"
            statusDetail = "\(sourceInfo?.summary ?? "Clip") · \(resolution) · \(fps)"
            appendLog("Loaded \(sourceInfo?.summary ?? "video")")
        } catch {
            exportError = error.localizedDescription
            statusTitle = "Import failed"
            statusDetail = "Try another clip"
            appendLog("Import error")
        }
    }

    @MainActor
    private func exportVideo() async {
        guard let videoURL else {
            statusTitle = "No clip selected"
            statusDetail = "Import a video first"
            return
        }

        cleanupTempFile(exportedVideoURL)
        exportedVideoURL = nil
        isProcessing = true
        exportError = nil
        renderProgress = 0
        currentStep = .render
        statusTitle = "Rendering \(fps)"
        statusDetail = "Optimizing for \(platform) (\(resolution))..."
        appendLog("Rendering \(resolution) @ \(fps) for \(platform)")

        let targetFPS: Int32 = fps == "60 FPS" ? 60 : 30
        let chosenResolution = resolution
        let chosenPlatform = platform

        defer {
            isProcessing = false
        }

        do {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("NaisePlus_\(UUID().uuidString)")
                .appendingPathExtension("mp4")

            let profile = try await runPaduExport(
                inputURL: videoURL,
                outputURL: outputURL,
                platform: chosenPlatform,
                resolution: chosenResolution,
                targetFPS: targetFPS,
                onProgress: { p in
                    Task { @MainActor in
                        renderProgress = min(1.0, max(0.0, p))
                    }
                }
            )

            exportedVideoURL = outputURL
            renderProgress = 1.0
            currentStep = .ready
            statusTitle = "Export ready"
            statusDetail = "\(Int(profile.outputSize.width))×\(Int(profile.outputSize.height)) · \(profile.targetFPS)FPS · \(String(format: "%.1f", profile.bitrateMbps))Mbps"
            appendLog("Ready · Tap Save to Files")
        } catch {
            exportError = error.localizedDescription
            currentStep = .profile
            statusTitle = "Export failed"
            statusDetail = "Adjust settings and retry"
            appendLog("Failed: \(error.localizedDescription)")
        }
    }
}

private func buildExportProfile(
    orientedSize: CGSize,
    platform: String,
    resolution: String,
    targetFPS: Int32,
    compatiblePresets: [String]
) -> ExportProfile {
    let maxSide: CGFloat
    let basePreset: String
    switch resolution {
    case "720p":
        maxSide = 1280
        basePreset = AVAssetExportPreset1280x720
    case "1080p":
        maxSide = 1920
        basePreset = AVAssetExportPreset1920x1080
    default:
        maxSide = 2160
        basePreset = AVAssetExportPresetHighestQuality
    }

    let platformCap: CGFloat
    switch platform {
    case "WhatsApp":
        platformCap = min(maxSide, 1280)
    case "Instagram", "TikTok", "Facebook":
        platformCap = maxSide
    default:
        platformCap = maxSide
    }

    let scale = min(1.0, platformCap / max(orientedSize.width, orientedSize.height))
    let outputSize = CGSize(
        width: max(2, floor(orientedSize.width * scale / 2) * 2),
        height: max(2, floor(orientedSize.height * scale / 2) * 2)
    )

    let fpsMultiplier: Double = targetFPS == 60 ? 1.35 : 1.0
    let baseMbps: Double
    switch resolution {
    case "720p": baseMbps = 5.5
    case "1080p": baseMbps = 10.5
    default: baseMbps = 18.0
    }
    let platformFactor: Double = platform == "WhatsApp" ? 0.75 : 1.0
    let bitrateMbps = max(2.5, min(28.0, baseMbps * fpsMultiplier * platformFactor))

    let chosenPreset: String
    if compatiblePresets.contains(basePreset) {
        chosenPreset = basePreset
    } else if compatiblePresets.contains(AVAssetExportPresetHighestQuality) {
        chosenPreset = AVAssetExportPresetHighestQuality
    } else {
        chosenPreset = compatiblePresets.first ?? AVAssetExportPresetMediumQuality
    }

    return ExportProfile(
        outputSize: outputSize,
        targetFPS: targetFPS,
        presetName: chosenPreset,
        bitrateMbps: bitrateMbps
    )
}

private func runPaduExport(
    inputURL: URL,
    outputURL: URL,
    platform: String,
    resolution: String,
    targetFPS: Int32,
    onProgress: @escaping (Double) -> Void
) async throws -> ExportProfile {
    let asset = AVURLAsset(url: inputURL)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
        throw NSError(domain: "NaisePlus", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
    }

    let sourceSize = try await videoTrack.load(.naturalSize)
    let sourceTransform = try await videoTrack.load(.preferredTransform)
    let trackRange = try await videoTrack.load(.timeRange)

    let transformedRect = CGRect(origin: .zero, size: sourceSize).applying(sourceTransform)
    let orientedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    guard orientedSize.width > 0, orientedSize.height > 0 else {
        throw NSError(domain: "NaisePlus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid video dimensions"])
    }

    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    let profile = buildExportProfile(
        orientedSize: orientedSize,
        platform: platform,
        resolution: resolution,
        targetFPS: targetFPS,
        compatiblePresets: compatiblePresets
    )

    let composition = AVMutableVideoComposition()
    composition.renderSize = profile.outputSize
    composition.frameDuration = CMTime(value: 1, timescale: profile.targetFPS)

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: trackRange.duration)

    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    let scale = min(1.0, max(profile.outputSize.width, profile.outputSize.height) / max(orientedSize.width, orientedSize.height))
    let normalized = sourceTransform.concatenating(
        CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
    )
    let scaled = normalized.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    layerInstruction.setTransform(scaled, at: .zero)

    instruction.layerInstructions = [layerInstruction]
    composition.instructions = [instruction]

    guard let session = AVAssetExportSession(asset: asset, presetName: profile.presetName) else {
        throw NSError(domain: "NaisePlus", code: 3, userInfo: [NSLocalizedDescriptionKey: "Export session unavailable"])
    }

    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.videoComposition = composition
    session.shouldOptimizeForNetworkUse = true

    let progressTask = Task {
        while !Task.isCancelled {
            onProgress(Double(session.progress))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    defer { progressTask.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        session.exportAsynchronously {
            switch session.status {
            case .completed:
                continuation.resume()
            case .failed:
                continuation.resume(throwing: session.error ?? NSError(domain: "NaisePlus", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export failed"]))
            case .cancelled:
                continuation.resume(throwing: NSError(domain: "NaisePlus", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
            default:
                continuation.resume(throwing: session.error ?? NSError(domain: "NaisePlus", code: 6, userInfo: [NSLocalizedDescriptionKey: "Export interrupted"]))
            }
        }
    }

    return profile
}

private struct SocialPlatformLogo: View {
    let platform: String
    var body: some View {
        switch platform {
        case "Instagram":
            ZStack {
                RoundedRectangle(cornerRadius: 5.5).stroke(lineWidth: 1.8).frame(width: 19, height: 19)
                Circle().stroke(lineWidth: 1.8).frame(width: 8.5, height: 8.5)
                Circle().fill().frame(width: 2.3, height: 2.3).offset(x: 5.2, y: -5.2)
            }
        case "TikTok":
            TikTokShape().fill().frame(width: 17, height: 19)
        case "WhatsApp":
            ZStack {
                WhatsAppBubbleShape().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 19, height: 19)
                WhatsAppPhoneShape().fill().frame(width: 9.5, height: 9.5)
            }
        default:
            FacebookFShape().fill().frame(width: 11, height: 19)
        }
    }
}

private struct TikTokShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.68, y: h * 0.05))
        p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.05))
        p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.67))
        p.addCurve(to: CGPoint(x: w * 0.34, y: h * 0.80), control1: CGPoint(x: w * 0.50, y: h * 0.75), control2: CGPoint(x: w * 0.43, y: h * 0.80))
        p.addCurve(to: CGPoint(x: w * 0.19, y: h * 0.66), control1: CGPoint(x: w * 0.25, y: h * 0.80), control2: CGPoint(x: w * 0.19, y: h * 0.74))
        p.addCurve(to: CGPoint(x: w * 0.38, y: h * 0.52), control1: CGPoint(x: w * 0.19, y: h * 0.57), control2: CGPoint(x: w * 0.28, y: h * 0.50))
        p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.36))
        p.addCurve(to: CGPoint(x: w * 0.03, y: h * 0.66), control1: CGPoint(x: w * 0.18, y: h * 0.34), control2: CGPoint(x: w * 0.03, y: h * 0.48))
        p.addCurve(to: CGPoint(x: w * 0.35, y: h * 0.96), control1: CGPoint(x: w * 0.03, y: h * 0.83), control2: CGPoint(x: w * 0.18, y: h * 0.96))
        p.addCurve(to: CGPoint(x: w * 0.67, y: h * 0.66), control1: CGPoint(x: w * 0.53, y: h * 0.96), control2: CGPoint(x: w * 0.67, y: h * 0.83))
        p.addLine(to: CGPoint(x: w * 0.67, y: h * 0.35))
        p.addCurve(to: CGPoint(x: w * 0.96, y: h * 0.43), control1: CGPoint(x: w * 0.76, y: h * 0.40), control2: CGPoint(x: w * 0.86, y: h * 0.43))
        p.addLine(to: CGPoint(x: w * 0.96, y: h * 0.27))
        p.addCurve(to: CGPoint(x: w * 0.68, y: h * 0.05), control1: CGPoint(x: w * 0.80, y: h * 0.26), control2: CGPoint(x: w * 0.69, y: h * 0.17))
        p.closeSubpath()
        return p
    }
}

private struct WhatsAppBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.12, y: h * 0.90))
        p.addLine(to: CGPoint(x: w * 0.21, y: h * 0.68))
        p.addArc(center: CGPoint(x: w * 0.52, y: h * 0.48), radius: w * 0.44, startAngle: .degrees(145), endAngle: .degrees(115), clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct WhatsAppPhoneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
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
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.64, y: h * 0.98))
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.54))
        p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.54))
        p.addLine(to: CGPoint(x: w * 0.97, y: h * 0.36))
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.36))
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.24))
        p.addCurve(to: CGPoint(x: w * 0.82, y: h * 0.16), control1: CGPoint(x: w * 0.64, y: h * 0.19), control2: CGPoint(x: w * 0.68, y: h * 0.16))
        p.addLine(to: CGPoint(x: w * 0.98, y: h * 0.16))
        p.addLine(to: CGPoint(x: w * 0.98, y: h * 0.02))
        p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.02))
        p.addCurve(to: CGPoint(x: w * 0.36, y: h * 0.24), control1: CGPoint(x: w * 0.49, y: h * 0.02), control2: CGPoint(x: w * 0.36, y: h * 0.11))
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