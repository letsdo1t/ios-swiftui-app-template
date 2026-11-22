import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import UniformTypeIdentifiers

// MARK: - Models

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
    let width: Int      // oriented (after rotation)
    let height: Int
    let durationSeconds: Double
    let fps: Double

    var summary: String {
        let mins = Int(durationSeconds) / 60
        let secs = Int(durationSeconds) % 60
        return "\(width)×\(height) · \(String(format: "%d:%02d", mins, secs)) · \(Int(fps.rounded()))fps"
    }
}

/// Video dari PhotosPicker: disalin terus ke file (tak load seluruh video dalam RAM).
private struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

private struct ExportedVideoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Movie, .movie] }
    let sourceURL: URL

    init(sourceURL: URL) { self.sourceURL = sourceURL }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Tanpa .immediate → tak baca seluruh file masuk memori
        try FileWrapper(url: sourceURL, options: [])
    }
}

// MARK: - Export planning (pure logic, mudah di-test)

private struct EnhanceSettings {
    var platform: String
    var resolution: String
    var requestedFPS: Int
    var upscale: Bool
    var useAI: Bool
    var detail: Double = 1.0     // pengganda sharpen: Natural 0.6 / Crisp 1.0 / Strong 1.8
}

private struct ExportPlan {
    let outputSize: CGSize
    let fps: Int
    let bitrate: Int          // bits per second
    let upscaled: Bool
    var usedAI = false
    var aiRequested = false

    var summary: String {
        "\(Int(outputSize.width))×\(Int(outputSize.height)) · \(fps)fps · \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps" + (usedAI ? " · AI" : (aiRequested ? " · AI skipped" : ""))
    }
}

private func planExport(orientedSize: CGSize, sourceFPS: Double, settings: EnhanceSettings, durationSeconds: Double) -> ExportPlan {
    // "4K" = sisi panjang 3840 (versi lama tersilap 2160)
    var targetLong: CGFloat = switch settings.resolution {
    case "720p": 1280
    case "1080p": 1920
    default: 3840
    }
    if settings.platform == "WhatsApp" { targetLong = min(targetLong, 1280) }

    let srcLong = max(orientedSize.width, orientedSize.height)
    var scale = targetLong / srcLong
    if settings.upscale {
        scale = min(scale, 2.0)      // jangan upscale melampau
    } else {
        scale = min(scale, 1.0)
    }

    let w = max(2, (orientedSize.width * scale / 2).rounded() * 2)
    let h = max(2, (orientedSize.height * scale / 2).rounded() * 2)

    // FPS: jangan "reka" frame. 30fps → 60fps cuma duplicate frame (membazir bitrate, tak lagi smooth).
    let srcRounded = max(1, Int(sourceFPS.rounded()))
    let fps = max(1, min(settings.requestedFPS, srcRounded))

    // Bitrate ikut bilangan pixel (bpp ≈ 0.19 @30fps), bukan nombor tetap.
    let pixels = Double(w * h)
    let fpsScale = pow(Double(fps) / 30.0, 0.7)
    var bitrate = pixels * 30.0 * 0.19 * fpsScale
    if settings.platform == "WhatsApp" { bitrate *= 0.75 }
    bitrate = min(45_000_000, max(3_000_000, bitrate))
    if settings.platform == "WhatsApp" {
        // Kekalkan setiap fail di bawah ~14 MB (selamat bawah had 16 MB yang sering disebut)
        let cap = (14_000_000.0 * 8.0) / max(1.0, durationSeconds) - 192_000.0
        bitrate = min(bitrate, max(900_000.0, cap))
    }

    return ExportPlan(
        outputSize: CGSize(width: w, height: h),
        fps: fps,
        bitrate: Int(bitrate),
        upscaled: scale > 1.001
    )
}

/// Bahagikan klip panjang kepada bahagian sama panjang (setiap satu ≤ partSeconds).
/// partSeconds nil atau klip pendek → satu fail sahaja.
private func partPlan(total: Double, partSeconds: Double?) -> (count: Int, each: Double) {
    guard let partSeconds, partSeconds > 0, total > partSeconds + 0.5 else {
        return (1, max(total, 0.01))
    }
    let count = Int((total / partSeconds).rounded(.up))
    return (count, total / Double(count))
}

// MARK: - Transcoder (AVAssetReader → CoreImage/Metal → AVAssetWriter)

private enum NaiseError: LocalizedError {
    case noVideoTrack, invalidSize, cannotStartReader(String), cannotStartWriter(String)
    case unsupportedSettings, failed(String), cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found"
        case .invalidSize: return "Invalid video dimensions"
        case .cannotStartReader(let m): return "Cannot read clip: \(m)"
        case .cannotStartWriter(let m): return "Cannot write clip: \(m)"
        case .unsupportedSettings: return "This device can't encode these settings. Try a lower resolution."
        case .failed(let m): return m
        case .cancelled: return "Export cancelled"
        }
    }
}

private final class NaiseTranscoder: @unchecked Sendable {
    private let ciContext: CIContext
    private let lock = NSLock()
    private var cancelledFlag = false

    init() {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
    }

    func cancel() { lock.lock(); cancelledFlag = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    private func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    func export(
        inputURL: URL,
        outputDirectory: URL,
        settings: EnhanceSettings,
        partSeconds: Double?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (urls: [URL], plan: ExportPlan) {
        try await withTaskCancellationHandler {
            let asset = AVURLAsset(url: inputURL)
            let duration = try await asset.load(.duration)
            let layout = partPlan(total: CMTimeGetSeconds(duration), partSeconds: partSeconds)

            var urls: [URL] = []
            var currentOutput: URL?
            var lastResult: ExportPlan?

            do {
                for index in 0..<layout.count {
                    let out = outputDirectory
                        .appendingPathComponent("NaisePlus_\(UUID().uuidString)_p\(index + 1)")
                        .appendingPathExtension("mp4")
                    currentOutput = out

                    var segment: CMTimeRange?
                    if layout.count > 1 {
                        segment = CMTimeRange(
                            start: CMTime(seconds: layout.each * Double(index), preferredTimescale: 600),
                            duration: CMTime(seconds: layout.each, preferredTimescale: 600)
                        )
                    }

                    let finishedParts = Double(index)
                    let allParts = Double(layout.count)
                    lastResult = try await run(
                        inputURL: inputURL,
                        outputURL: out,
                        settings: settings,
                        segment: segment,
                        onProgress: { p in onProgress((finishedParts + p) / allParts) }
                    )
                    urls.append(out)
                    currentOutput = nil
                }
            } catch {
                if let currentOutput { try? FileManager.default.removeItem(at: currentOutput) }
                for url in urls { try? FileManager.default.removeItem(at: url) }
                throw error
            }

            guard let finalPlan = lastResult else { throw NaiseError.failed("Nothing was exported") }
            return (urls: urls, plan: finalPlan)
        } onCancel: {
            self.cancel()
        }
    }

    private func run(
        inputURL: URL,
        outputURL: URL,
        settings: EnhanceSettings,
        segment: CMTimeRange?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportPlan {
        let asset = AVURLAsset(url: inputURL)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw NaiseError.noVideoTrack }

        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let timeRange = try await vTrack.load(.timeRange)
        let nominalFPS = Double(try await vTrack.load(.nominalFrameRate))
        let characteristics = try await vTrack.load(.mediaCharacteristics)
        let isHDR = characteristics.contains(.containsHDRVideo)

        let orient = orientation(for: transform)
        let swap = (orient == .left || orient == .right)
        let orientedSize = swap
            ? CGSize(width: natural.height, height: natural.width)
            : natural
        guard orientedSize.width > 0, orientedSize.height > 0 else { throw NaiseError.invalidSize }

        let sourceFPS = nominalFPS > 0 ? nominalFPS : 30
        let activeRange: CMTimeRange = segment.map {
            CMTimeRange(start: CMTimeAdd(timeRange.start, $0.start), duration: $0.duration)
        } ?? timeRange
        let basePlan = planExport(
            orientedSize: orientedSize,
            sourceFPS: sourceFPS,
            settings: settings,
            durationSeconds: max(0.01, CMTimeGetSeconds(activeRange.duration))
        )

        // AI super-resolution (iOS 26+). Nil → automatik guna mod Clean.
        let aiStage: NaiseFrameUpscaler? = settings.useAI
            ? await makeNaiseAIUpscaler(
                width: Int(orientedSize.width),
                height: Int(orientedSize.height),
                requiredScale: basePlan.outputSize.height / orientedSize.height
            )
            : nil
        var planWithAI = basePlan
        planWithAI.usedAI = (aiStage != nil)
        planWithAI.aiRequested = settings.useAI
        let plan = planWithAI
        let outW = plan.outputSize.width, outH = plan.outputSize.height
        let outRect = CGRect(origin: .zero, size: plan.outputSize)

        try? FileManager.default.removeItem(at: outputURL)

        // ---- Reader ----
        let reader = try AVAssetReader(asset: asset)
        if segment != nil { reader.timeRange = activeRange }

        var vReadSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if isHDR {
            // HDR (HLG/Dolby Vision iPhone) → tukar ke SDR Rec.709 supaya warna tak pudar
            vReadSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
        let vOutput = AVAssetReaderTrackOutput(track: vTrack, outputSettings: vReadSettings)
        vOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(vOutput) else { throw NaiseError.cannotStartReader("video output") }
        reader.add(vOutput)

        var aOutput: AVAssetReaderTrackOutput?
        if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000
            ])
            if reader.canAdd(out) { reader.add(out); aOutput = out }
        }

        // ---- Writer ----
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // faststart → upload cepat mula

        func videoSettings(codec: AVVideoCodecType, bitrate: Int) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: plan.fps * 2,
                AVVideoExpectedSourceFrameRateKey: plan.fps,
                AVVideoAllowFrameReorderingKey: true
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(outW),
                AVVideoHeightKey: Int(outH),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: compression
            ]
        }

        // H.264 dulu (paling serasi dengan IG/TikTok/WhatsApp); kalau device tak support, jatuh ke HEVC
        var chosen = videoSettings(codec: .h264, bitrate: plan.bitrate)
        if !writer.canApply(outputSettings: chosen, forMediaType: .video) {
            chosen = videoSettings(codec: .hevc, bitrate: Int(Double(plan.bitrate) * 0.7))
            guard writer.canApply(outputSettings: chosen, forMediaType: .video) else { throw NaiseError.unsupportedSettings }
        }

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: chosen)
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outW),
                kCVPixelBufferHeightKey as String: Int(outH),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        guard writer.canAdd(vInput) else { throw NaiseError.cannotStartWriter("video input") }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if aOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aInput = input }
        }

        guard reader.startReading() else {
            throw NaiseError.cannotStartReader(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw NaiseError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        let startTime = activeRange.start
        writer.startSession(atSourceTime: startTime)

        // ---- Per-frame pipeline ----
        let totalSeconds = max(0.001, CMTimeGetSeconds(activeRange.duration))
        let startSeconds = CMTimeGetSeconds(startTime)
        let interval = 1.0 / Double(plan.fps)
        let needsDrop = sourceFPS > Double(plan.fps) + 1.5   // contoh 60 → 30
        let sharpness: Double = {
            var s: Double = switch settings.platform {
            case "WhatsApp": 0.30
            case "TikTok", "Instagram": 0.22
            default: 0.18
            }
            if plan.upscaled { s += 0.06 }
            return min(1.2, s * settings.detail)
        }()
        let denoiseLevel: Float = plan.upscaled ? 0.015 : 0.008
        let allowDenoise = max(outW, outH) <= 2500    // 4K: skip, terlalu berat & tak perlu
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = ciContext
        let srcW = orientedSize.width, srcH = orientedSize.height

        func enhance(_ buffer: CVPixelBuffer, pts: CMTime) -> CIImage {
            var image = CIImage(cvPixelBuffer: buffer).oriented(orient)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

            // 1) Denoise dulu di resolusi asal (murah & elak noise di-upscale)
            if allowDenoise {
                let nr = CIFilter.noiseReduction()
                nr.inputImage = image
                nr.noiseLevel = denoiseLevel
                nr.sharpness = 0.30
                if let out = nr.outputImage { image = out.cropped(to: CGRect(x: 0, y: 0, width: srcW, height: srcH)) }
            }

            // 2) AI super-resolution (kalau tersedia) sebelum resize akhir
            if let aiStage, let up = aiStage.upscale(image, pts: pts, context: ctx) {
                image = up
            }

            // 3) Lanczos resize ke saiz akhir (kualiti jauh lebih baik dari affine biasa)
            let curW = image.extent.width, curH = image.extent.height
            if abs(outH - curH) > 0.5 || abs(outW - curW) > 0.5 {
                let scaleY = outH / curH
                let scaleX = outW / curW
                let lz = CIFilter.lanczosScaleTransform()
                lz.inputImage = image
                lz.scale = Float(scaleY)
                lz.aspectRatio = Float(scaleX / scaleY)
                if let out = lz.outputImage { image = out }
            }
            image = image.cropped(to: outRect)

            // 3) Sharpen LEPAS resize (versi lama sharpen sebelum denoise → effect hilang)
            let sh = CIFilter.sharpenLuminance()
            sh.inputImage = image
            sh.sharpness = Float(sharpness)
            if let out = sh.outputImage { image = out.cropped(to: outRect) }

            // 4) Colour sedikit
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.contrast = 1.02
            cc.saturation = 1.01
            cc.brightness = 0
            if let out = cc.outputImage { image = out.cropped(to: outRect) }
            return image
        }

        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "naise.video.write", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "naise.audio.write", qos: .userInitiated)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExportPlan, Error>) in
            var videoDone = false
            var nextEmit = startSeconds
            var lastReported = 0.0

            group.enter()
            vInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                guard !videoDone else { return }
                while vInput.isReadyForMoreMediaData {
                    var finish = isCancelled || reader.status != .reading || writer.status != .writing
                    var sampleToProcess: CMSampleBuffer?
                    if !finish {
                        sampleToProcess = vOutput.copyNextSampleBuffer()
                        finish = (sampleToProcess == nil)
                    }
                    if finish {
                        videoDone = true
                        vInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = sampleToProcess,
                          let srcBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let t = CMTimeGetSeconds(pts)

                    if needsDrop {
                        if t < nextEmit - interval * 0.4 { continue }
                        nextEmit += interval
                        if nextEmit < t { nextEmit = t + interval }
                    }

                    var ok = true
                    autoreleasepool {
                        guard let pool = adaptor.pixelBufferPool else { ok = false; return }
                        var dst: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
                        guard let dstBuffer = dst else { ok = false; return }
                        ctx.render(enhance(srcBuffer, pts: pts), to: dstBuffer, bounds: outRect, colorSpace: colorSpace)
                        ok = adaptor.append(dstBuffer, withPresentationTime: pts)
                    }
                    if !ok {
                        reader.cancelReading()
                        videoDone = true
                        vInput.markAsFinished()
                        group.leave()
                        return
                    }

                    let p = min(1, max(0, (t - startSeconds) / totalSeconds))
                    if p - lastReported >= 0.01 { lastReported = p; onProgress(p) }
                }
            }

            if let aInput, let aOutput {
                var audioDone = false
                group.enter()
                aInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
                    guard !audioDone else { return }
                    while aInput.isReadyForMoreMediaData {
                        if isCancelled || reader.status != .reading || writer.status != .writing {
                            audioDone = true; aInput.markAsFinished(); group.leave(); return
                        }
                        guard let sample = aOutput.copyNextSampleBuffer() else {
                            audioDone = true; aInput.markAsFinished(); group.leave(); return
                        }
                        if !aInput.append(sample) {
                            audioDone = true; aInput.markAsFinished(); group.leave(); return
                        }
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) { [self] in
                aiStage?.finish()
                if isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    cont.resume(throwing: NaiseError.cancelled)
                    return
                }
                if reader.status == .failed {
                    writer.cancelWriting()
                    cont.resume(throwing: NaiseError.failed(reader.error?.localizedDescription ?? "Read failed"))
                    return
                }
                if writer.status == .failed {
                    cont.resume(throwing: NaiseError.failed(writer.error?.localizedDescription ?? "Write failed"))
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        onProgress(1)
                        var done = plan
                        done.usedAI = aiStage?.isActive ?? false
                        cont.resume(returning: done)
                    } else {
                        cont.resume(throwing: NaiseError.failed(writer.error?.localizedDescription ?? "Finalize failed"))
                    }
                }
            }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme

private var isLightMode: Bool {
    colorScheme == .light
}
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var exportedURLs: [URL] = []
    @State private var partLength = "30s"
    @State private var sourceInfo: SourceClipInfo?
    @State private var statusTitle = "Ready to import"
    @State private var statusDetail = "Select a clean clip for Story / Reels"
    @State private var currentStep: EnhanceStep = .importClip
    @State private var renderProgress: Double = 0
    @State private var logs: [StatusLogEntry] = [
        StatusLogEntry(timeText: "NOW", message: "Naise+ Metal engine ready")
    ]
    @State private var isProcessing = false
    @State private var exportError: String?
    @State private var platform = "Instagram"
    @State private var resolution = "1080p"
    @State private var fps = "30 FPS"
    @State private var upscale = true
    @State private var useAI = false
    @State private var detail = "Crisp"
    @State private var shareItem: ShareItem?
    @State private var activeTranscoder: NaiseTranscoder?

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
    private let detailLevels = ["Natural", "Crisp", "Strong"]
    private let partLengths = ["30s", "60s", "Off"]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var detailMultiplier: Double {
        switch detail {
        case "Natural": return 0.6
        case "Strong": return 1.8
        default: return 1.0
        }
    }

    private var fpsDetail: String {
        guard let info = sourceInfo else { return "Never above source fps" }
        let src = Int(info.fps.rounded())
        let req = fps == "60 FPS" ? 60 : 30
        return req >= src ? "Source \(src) fps · kept" : "\(src) → \(req) fps"
    }

    private var currentSettings: EnhanceSettings {
        EnhanceSettings(
            platform: platform,
            resolution: resolution,
            requestedFPS: fps == "60 FPS" ? 60 : 30,
            upscale: upscale,
            useAI: useAI,
            detail: detailMultiplier
        )
    }

    /// WhatsApp: potong klip panjang kepada bahagian (macam PureStatus). Platform lain: satu fail.
    private var partSeconds: Double? {
        guard platform == "WhatsApp" else { return nil }
        switch partLength {
        case "30s": return 30
        case "60s": return 60
        default: return nil
        }
    }

    /// Preview output sebenar sebelum render
    private var plannedSummary: String {
        guard let info = sourceInfo else { return "\(resolution) · \(fps)" }
        let layout = partPlan(total: info.durationSeconds, partSeconds: partSeconds)
        let plan = planExport(
            orientedSize: CGSize(width: info.width, height: info.height),
            sourceFPS: info.fps,
            settings: currentSettings,
            durationSeconds: layout.each
        )
        return "Output \(plan.summary)" + (layout.count > 1 ? " · \(layout.count) parts" : "")
    }

    private var detailText: String {
        (videoURL != nil && !isProcessing && currentStep == .profile) ? plannedSummary : statusDetail
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header.padding(.top, 10)
                    importArea.padding(.top, 12)
                    clearStatusCard.padding(.top, 10)
                    settingsPanel.padding(.top, 10)
                    Spacer(minLength: 12)
                    exportButton

                    if !exportedURLs.isEmpty {
                        HStack(spacing: 8) {
                            secondaryButton("Save to Photos", icon: "photo.badge.plus") {
                                Task { await saveToPhotos() }
                            }
                            secondaryButton("Share / Files", icon: "square.and.arrow.up") {
                                shareItem = ShareItem(urls: exportedURLs)
                            }
                        }
                        .padding(.top, 8)
                    }

                    if let exportError {
                        Text(exportError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .padding(.top, 5)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .frame(maxWidth: 500)
                .frame(width: geometry.size.width)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
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
        .sheet(item: $shareItem) { item in
            ActivityView(urls: item.urls)
        }
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activeAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(cyanAccent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text("Naise+")
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text("AI Video Enhancer")
                .font(.system(size: 12))
                .foregroundStyle(mutedText)
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
        .disabled(isProcessing)
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

            Text(detailText)
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
            sectionHeading("MAX FRAME RATE", detail: fpsDetail)
            choiceRow(rates, selection: $fps, labelPrefix: "FPS")

            Divider().overlay(glassBorder)
            sectionHeading("DETAIL", detail: detail == "Strong" ? "Max sharpen" : (detail == "Crisp" ? "Balanced" : "Subtle"))
            choiceRow(detailLevels, selection: $detail, labelPrefix: "Detail")

            if platform == "WhatsApp" {
                Divider().overlay(glassBorder)
                sectionHeading("SPLIT LONG CLIPS", detail: partLength == "Off" ? "Single file" : "Parts up to \(partLength)")
                choiceRow(partLengths, selection: $partLength, labelPrefix: "Split")
            }

            Divider().overlay(glassBorder)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("UPSCALE TO TARGET").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(mutedText)
                    Text("Lanczos resize, keeps more detail after IG/TikTok re-compress")
                        .font(.system(size: 10)).foregroundStyle(mutedText).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: $upscale).labelsHidden().tint(cyanAccent)
            }

            if #available(iOS 26.0, *) {
                Divider().overlay(glassBorder)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI SUPER RESOLUTION").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(mutedText)
                        Text("On-device ML · best for 720p or lower clips · auto-falls back")
                            .font(.system(size: 10)).foregroundStyle(mutedText).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: $useAI).labelsHidden().tint(cyanAccent)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(glassBorder, lineWidth: 1))
        .disabled(isProcessing)
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
            if isProcessing {
                activeTranscoder?.cancel()
            } else {
                Task { await exportVideo() }
            }
        } label: {
            HStack(spacing: 10) {
                if isProcessing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                Text(isProcessing ? "Rendering… tap to cancel" : "Enhance & Export").foregroundStyle(.white)
            }
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(LinearGradient(colors: [cyanAccent, indigoAccent], startPoint: .leading, endPoint: .trailing))
            .clipShape(Capsule())
        }
        .disabled(videoURL == nil)
        .opacity(videoURL == nil ? 0.55 : 1)
    }

    // MARK: Logic

    private func appendLog(_ message: String) {
        logs.append(StatusLogEntry(timeText: Self.timeFormatter.string(from: Date()), message: message))
        if logs.count > 16 { logs.removeFirst(logs.count - 16) }
    }

    private func cleanupTempFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanupExported() {
        for url in exportedURLs { try? FileManager.default.removeItem(at: url) }
        exportedURLs = []
    }
    @MainActor
private func loadVideo(_ item: PhotosPickerItem?) async {
    cleanupTempFile(videoURL)
    cleanupExported()

    videoURL = nil
    sourceInfo = nil
    exportError = nil
    renderProgress = 0

    guard let item else {
        currentStep = .importClip
        statusTitle = "Ready to import"
        statusDetail = "Select a video from Photos"
        return
    }

    currentStep = .importClip
    statusTitle = "Importing clip"
    statusDetail = "Loading video from Photos..."

    do {
        guard let picked = try await item.loadTransferable(
            type: PickedVideo.self
        ) else {
            statusTitle = "Import failed"
            statusDetail = "Unable to load video"
            return
        }

        let url = picked.url
        let asset = AVURLAsset(url: url)

        guard let track = try await asset
            .loadTracks(withMediaType: .video).first else {
            cleanupTempFile(url)
            throw NaiseError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFPS = try await track.load(.nominalFrameRate)

        let rect = CGRect(
            origin: .zero,
            size: naturalSize
        ).applying(transform)

        sourceInfo = SourceClipInfo(
            width: Int(abs(rect.width)),
            height: Int(abs(rect.height)),
            durationSeconds: max(0, CMTimeGetSeconds(duration)),
            fps: nominalFPS > 0 ? Double(nominalFPS) : 30
        )

        videoURL = url
        currentStep = .profile
        statusTitle = "Source ready"
        statusDetail = sourceInfo?.summary ?? "Video loaded"

        appendLog("Video imported successfully")

    } catch {
        exportError = error.localizedDescription
        statusTitle = "Import failed"
        statusDetail = "Try another video"
        appendLog("Import error")
    }
}
    /// Saiz fail terbesar (setiap bahagian), untuk semak had saiz WhatsApp
    private func fileSizeText(_ urls: [URL]) -> String {
        var largest: Int64 = 0
        for url in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                largest = max(largest, size.int64Value)
            }
        }
        return largest > 0 ? String(format: "%.1f MB", Double(largest) / 1_048_576) : ""
    }

    @MainActor
private func exportVideo() async {
    guard let videoURL else { return }

    cleanupExported()
    isProcessing = true
    exportError = nil
    renderProgress = 0
    currentStep = .render
    statusTitle = "Uploading & Processing"
    statusDetail = "FFmpeg server is processing your video"
    appendLog("Connecting to Naise+ server")

    UIApplication.shared.isIdleTimerDisabled = true

    defer {
        isProcessing = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    do {
        let output = try await NaiseServerEngine.process(
            videoURL: videoURL,
            resolution: resolution,
            fps: fps == "60 FPS" ? 60 : 30
        )

        exportedURLs = [output]
        renderProgress = 1
        currentStep = .ready
        statusTitle = "Export ready"
        statusDetail = "Server processed MP4 · \(fileSizeText([output]))"
        appendLog("FFmpeg processing completed")
    } catch {
        exportError = error.localizedDescription
        currentStep = .profile
        statusTitle = "Export failed"
        statusDetail = "Check server and Cloudflare connection"
        appendLog("Server error: \(error.localizedDescription)")
    }
}

    @MainActor
    private func saveToPhotos() async {
        let urls = exportedURLs
        guard !urls.isEmpty else { return }
        // Tanpa key ni iOS akan crash app terus masa minta kebenaran Photos
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            // Key belum ada dalam Info.plist → guna share sheet sistem (tak perlukan kebenaran).
            // Pilih "Save Video" dalam sheet tu.
            exportError = nil
            shareItem = ShareItem(urls: urls)
            statusTitle = "Tap Save Video"
            statusDetail = "In the share sheet, choose Save Video"
            appendLog("Share sheet opened (no Info.plist key)")
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            exportError = "Allow Photos access (Add Photos only) in Settings to save the video."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
            exportError = nil
            statusTitle = "Saved to Photos"
            statusDetail = urls.count > 1
                ? "\(urls.count) parts saved. Post them one by one from your library"
                : "Open the app and pick it from your library"
            appendLog("Saved to Photos")
        } catch {
            exportError = error.localizedDescription
            appendLog("Save to Photos failed")
        }
    }
}

// MARK: - Share sheet (fallback Save to Photos)

private struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct ActivityView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Platform logos

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