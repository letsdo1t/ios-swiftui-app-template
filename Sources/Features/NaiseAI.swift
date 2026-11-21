import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// Peringkat AI untuk satu frame. Dipanggil dari NaiseTranscoder.
protocol NaiseFrameUpscaler: AnyObject {
    /// Terima CIImage (origin 0,0, sudah dipusing betul), pulangkan versi di-upscale.
    /// Pulang nil kalau gagal → pemanggil guna jalan Clean (Lanczos) untuk frame tu.
    func upscale(_ image: CIImage, pts: CMTime, context: CIContext) -> CIImage?
    func finish()
}

/// Cuba sediakan AI super-resolution (VideoToolbox VTFrameProcessor, iOS 26+).
/// Pulang nil kalau: iOS < 26, Xcode lama, device tak support, model tak dapat dimuat turun,
/// resolusi di luar had, atau upscale yang diperlukan terlalu kecil (< 1.25×).
func makeNaiseAIUpscaler(width: Int, height: Int, requiredScale: Double) async -> NaiseFrameUpscaler? {
#if compiler(>=6.2)
    if #available(iOS 26.0, *) {
        return await NaiseVTSuperResolution.make(width: width, height: height, requiredScale: requiredScale)
    }
#endif
    return nil
}

#if compiler(>=6.2)

@available(iOS 26.0, *)
private final class NaiseVTSuperResolution: NaiseFrameUpscaler, @unchecked Sendable {
    private let processor = VTFrameProcessor()
    private let srcPool: CVPixelBufferPool
    private let dstPool: CVPixelBufferPool
    private let width: Int
    private let height: Int
    private let outWidth: Int
    private let outHeight: Int
    private var previousSource: VTFrameProcessorFrame?
    private var previousOutput: VTFrameProcessorFrame?
    private var consecutiveFailures = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init(srcPool: CVPixelBufferPool, dstPool: CVPixelBufferPool, width: Int, height: Int, factor: Int) {
        self.srcPool = srcPool
        self.dstPool = dstPool
        self.width = width
        self.height = height
        self.outWidth = width * factor
        self.outHeight = height * factor
    }

    static func make(width: Int, height: Int, requiredScale: Double) async -> NaiseFrameUpscaler? {
        guard requiredScale >= 1.25 else { return nil }
        guard VTSuperResolutionScalerConfiguration.isSupported else { return nil }

        let factors = VTSuperResolutionScalerConfiguration.supportedScaleFactors.sorted()
        guard let factor = factors.first(where: { Double($0) >= requiredScale }) ?? factors.last else { return nil }

        guard let config = VTSuperResolutionScalerConfiguration(
            frameWidth: width,
            frameHeight: height,
            scaleFactor: factor,
            inputType: .video,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else { return nil }

        // Model ML mungkin perlu dimuat turun sekali (perlu internet kali pertama)
        if config.configurationModelStatus != .ready {
            let ok: Bool = await withCheckedContinuation { cont in
                config.downloadConfigurationModel { error in
                    cont.resume(returning: error == nil)
                }
            }
            guard ok, config.configurationModelStatus == .ready else { return nil }
        }

        guard
            let srcPool = makePool(config.sourcePixelBufferAttributes, width: width, height: height),
            let dstPool = makePool(config.destinationPixelBufferAttributes, width: width * factor, height: height * factor)
        else { return nil }

        let instance = NaiseVTSuperResolution(srcPool: srcPool, dstPool: dstPool, width: width, height: height, factor: factor)
        do {
            try instance.processor.startSession(configuration: config)
        } catch {
            return nil
        }
        return instance
    }

    private static func makePool(_ attributes: [String: any Sendable], width: Int, height: Int) -> CVPixelBufferPool? {
        var attrs: [String: Any] = attributes
        if attrs[kCVPixelBufferWidthKey as String] == nil { attrs[kCVPixelBufferWidthKey as String] = width }
        if attrs[kCVPixelBufferHeightKey as String] == nil { attrs[kCVPixelBufferHeightKey as String] = height }
        if attrs[kCVPixelBufferPixelFormatTypeKey as String] == nil {
            attrs[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        }
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()   // wajib IOSurface-backed
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as NSDictionary as CFDictionary, &pool)
        return pool
    }

    private final class ResultBox: @unchecked Sendable {
        var error: Error?
    }

    func upscale(_ image: CIImage, pts: CMTime, context: CIContext) -> CIImage? {
        // Kalau AI gagal berkali-kali, berhenti cuba (elak perlahan)
        if consecutiveFailures >= 5 { return nil }

        var srcBuf: CVPixelBuffer?
        var dstBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, srcPool, &srcBuf)
        CVPixelBufferPoolCreatePixelBuffer(nil, dstPool, &dstBuf)
        guard let srcBuf, let dstBuf,
              let srcFrame = VTFrameProcessorFrame(buffer: srcBuf, presentationTimeStamp: pts),
              let dstFrame = VTFrameProcessorFrame(buffer: dstBuf, presentationTimeStamp: pts)
        else { consecutiveFailures += 1; return nil }

        context.render(image, to: srcBuf, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)

        guard let params = VTSuperResolutionScalerParameters(
            sourceFrame: srcFrame,
            previousFrame: previousSource,
            previousOutputFrame: previousOutput,
            opticalFlow: nil,
            submissionMode: .sequential,
            destinationFrame: dstFrame
        ) else { consecutiveFailures += 1; return nil }

        // Jambatan async → sync (kita berada di queue GCD, bukan thread Swift concurrency)
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let processor = self.processor
        Task.detached {
            do { try await processor.process(parameters: params) }
            catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()

        if box.error != nil {
            consecutiveFailures += 1
            previousSource = nil      // reset rantaian temporal
            previousOutput = nil
            return nil
        }

        consecutiveFailures = 0
        previousSource = srcFrame
        previousOutput = dstFrame
        return CIImage(cvPixelBuffer: dstBuf)
    }

    func finish() {
        processor.endSession()
    }
}

#endif
