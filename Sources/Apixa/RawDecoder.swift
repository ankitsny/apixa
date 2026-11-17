import Foundation
import CoreImage
import Metal
import Synchronization

/// RAW decoding through Core Image's RAW 9 decoder (macOS 27).
///
/// - Decoder versions are requested by raw value ("9" / "9.dng"), per Apple DTS guidance, and only
///   when listed in `supportedDecoderVersions`; otherwise the filter keeps its default decoder.
/// - The working colour space is left at Core Image's default (DTS: custom working spaces + 9.dng
///   can tint on some devices).
/// - One Metal-backed `CIContext` is shared by every render.
enum RAWDecoder {
    /// A CIContext renders one image at a time (it holds a lock for the whole render), so a single
    /// shared context serialized every render in the app. A small pool of contexts on the same GPU lets
    /// renders (and the RAW decodes inside them) run in parallel; each call takes the next one.
    private static let pool: [CIContext] = {
        let n = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let dev = MTLCreateSystemDefaultDevice()
        return (0..<n).map { i in
            let opts: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "Apixa.RAW.\(i)"]
            return dev.map { CIContext(mtlDevice: $0, options: opts) } ?? CIContext(options: opts)
        }
    }()
    private static let nextIndex = Mutex(0)

    static var context: CIContext {
        let i = nextIndex.withLock { v in defer { v &+= 1 }; return v }
        return pool[i % pool.count]
    }

    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let extendedLinear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Version string actually used for a file, for display ("RAW 9", "RAW 8", …).
    static func label(for url: URL) -> String {
        guard let f = CIRAWFilter(imageURL: url) else { return "RAW" }
        configure(f, url: url)
        return "RAW " + f.decoderVersion.rawValue.replacingOccurrences(of: ".dng", with: " DNG")
    }

    /// Display-referred render, longest side ≈ `maxPixel`. `draft` trades a little quality for ~3× speed.
    static func render(_ url: URL, maxPixel: Int, draft: Bool) async -> CGImage? {
        await ResourceGate.shared.prepare(url)
        return await Blocking.run { ImageBox(image: renderSync(url, maxPixel: maxPixel, draft: draft)) }.image
    }

    /// Blocking; call off the cooperative pool (via `Blocking.run`) after `ResourceGate.prepare`.
    static func renderSync(_ url: URL, maxPixel: Int, draft: Bool, colorSpace: CGColorSpace? = nil) -> CGImage? {
        guard let f = makeFilter(url, maxPixel: maxPixel) else { return nil }
        f.isDraftModeEnabled = draft
        guard let img = output(f) ?? fallbackOutput(url, maxPixel: maxPixel, draft: draft) else { return nil }
        return context.createCGImage(img, from: img.extent.integralInward, format: .RGBA8,
                                     colorSpace: colorSpace ?? displayP3)
    }

    /// Accurate-analysis measurements from ONE RAW decode (the decoder is serialized system-wide, so
    /// decodes are the cost that matters). Renders linear, un-tone-mapped data once, then derives:
    /// - sensor highlight clipping: in this render green saturates at ≈1.0 and red/blue at their
    ///   white-balance gain, so each channel's ceiling is its own max — counted only once that max
    ///   reaches sensor white (≥0.95), so a dim, unclipped frame never reads as "clipped"
    /// - a display-referred grayscale image (baseline exposure + sRGB encoding) for sharpness/brightness.
    static func analysisSync(_ url: URL, maxPixel: Int = 1000) -> (gray: CGImage, clip: Double)? {
        guard let f = makeFilter(url, maxPixel: maxPixel) else { return nil }
        f.isDraftModeEnabled = true
        let baseline = f.baselineExposure
        f.exposure = 0
        f.baselineExposure = 0
        f.boostAmount = 0
        f.boostShadowAmount = 0
        if f.isHighlightRecoverySupported { f.isHighlightRecoveryEnabled = false }
        f.extendedDynamicRangeAmount = 2
        guard let img = output(f) else { return nil }

        let r = img.extent.integralInward
        let w = Int(r.width), h = Int(r.height)
        guard w >= 16, h >= 16 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(img, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: r,
                           format: .RGBAf, colorSpace: extendedLinear)
        }
        let n = w * h
        var ceiling: [Float] = [0, 0, 0]
        for i in 0..<n {
            for c in 0..<3 where px[i * 4 + c] > ceiling[c] { ceiling[c] = px[i * 4 + c] }
        }
        let th = ceiling.map { $0 >= 0.95 ? $0 * 0.95 : Float.infinity }
        let gain = Float(pow(2, Double(baseline)))
        var gray = [UInt8](repeating: 0, count: n)
        var clipped = 0
        for i in 0..<n {
            let p = i * 4
            if px[p] >= th[0] || px[p + 1] >= th[1] || px[p + 2] >= th[2] { clipped += 1 }
            let y = min(1, max(0, (0.2126 * px[p] + 0.7152 * px[p + 1] + 0.0722 * px[p + 2]) * gain))
            let e = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
            gray[i] = UInt8(e * 255 + 0.5)
        }
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage() else { return nil }
        // Linear output is bottom-up in CI coordinates; the gray buffer is top-down, so flip isn't needed
        // for sharpness/brightness statistics (they're orientation-independent).
        return (cg, Double(clipped) / Double(n))
    }

    // MARK: - Filter setup

    /// The decoder's output, minus a 1px border when downscaled: at fractional scaled sizes the
    /// decoder rounds its extent up and emits a partially empty edge row/column.
    static func output(_ f: CIRAWFilter) -> CIImage? {
        guard let img = f.outputImage else { return nil }
        guard f.scaleFactor < 1 else { return img }
        return img.cropped(to: img.extent.insetBy(dx: 1, dy: 1))
    }

    private static func makeFilter(_ url: URL, maxPixel: Int) -> CIRAWFilter? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        configure(f, url: url)
        let side = max(f.nativeSize.width, f.nativeSize.height)
        if side > 0 { f.scaleFactor = Float(min(1, Double(maxPixel) / side)) }
        return f
    }

    static func configure(_ f: CIRAWFilter, url: URL) {
        let wanted = CIRAWDecoderVersion(rawValue: url.pathExtension.lowercased() == "dng" ? "9.dng" : "9")
        if f.supportedDecoderVersions.contains(wanted) { f.decoderVersion = wanted }
    }

    /// RAW 9 produced nothing (e.g. resources missing) — retry with the file's default decoder.
    private static func fallbackOutput(_ url: URL, maxPixel: Int, draft: Bool) -> CIImage? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        let side = max(f.nativeSize.width, f.nativeSize.height)
        if side > 0 { f.scaleFactor = Float(min(1, Double(maxPixel) / side)) }
        f.isDraftModeEnabled = draft
        return output(f)
    }
}

/// macOS 27 decoders can need on-demand resources. Download them once per camera model + decoder
/// version, sharing one in-flight download between concurrent callers.
actor ResourceGate {
    static let shared = ResourceGate()
    private var tasks: [String: Task<Void, Never>] = [:]

    func prepare(_ url: URL) async {
        guard let f = CIRAWFilter(imageURL: url) else { return }
        RAWDecoder.configure(f, url: url)
        let tiff = f.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? url.pathExtension.lowercased()
        let key = model + "|" + f.decoderVersion.rawValue
        if let t = tasks[key] { return await t.value }
        let t = Task.detached(priority: .userInitiated) {
            guard let g = CIRAWFilter(imageURL: url) else { return }
            RAWDecoder.configure(g, url: url)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                _ = g.downloadResources(timeout: 60) { _ in c.resume() }
            }
        }
        tasks[key] = t
        await t.value
    }
}
