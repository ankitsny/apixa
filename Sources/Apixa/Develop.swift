import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Renders a shot with `Adjustments` applied. Blocking work goes through `Blocking.run`.
/// Originals are only ever read.
enum Develop {
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A rendered image plus its scale relative to the original (1 = full resolution).
    struct Rendered: @unchecked Sendable {
        let image: CGImage
        let scale: Double
    }

    /// `maxPixel: nil` = full resolution. `applyCrop: false` keeps straightening but shows the whole
    /// frame (used while the crop tool is open).
    static func render(raw: URL?, jpeg: URL?, useRaw: Bool, adjustments adj: Adjustments,
                       maxPixel: Int?, draft: Bool, applyCrop: Bool = true) async -> CGImage? {
        await renderScaled(raw: raw, jpeg: jpeg, useRaw: useRaw, adjustments: adj, maxPixel: maxPixel,
                           draft: draft, applyCrop: applyCrop)?.image
    }

    /// Decode a RAW into the cache ahead of time (no develop, no output image), so showing it later
    /// only costs the develop step.
    static func warm(raw: URL, adjustments adj: Adjustments, maxPixel: Int?, hdr: Bool = false) async {
        await ResourceGate.shared.prepare(raw)
        _ = await Blocking.run { cachedRaw(raw, adj: adj, maxPixel: maxPixel, draft: false, interactive: false, hdr: hdr) != nil }
    }

    /// Apple's auto-enhance (the analysis behind the magic wand in Photos), expressed as Apixa's own
    /// sliders so the result stays visible and editable. Tone and colour edits are replaced; white
    /// balance, crop, noise settings and the look are kept.
    static func autoAdjust(raw: URL?, jpeg: URL?, useRaw: Bool, current: Adjustments) async -> Adjustments? {
        var base = current
        base.exposure = 0; base.contrast = 0; base.highlights = 0; base.shadows = 0; base.whites = 0; base.blacks = 0
        base.vibrance = 0; base.saturation = 0; base.curves = Curves()
        var probe = base; probe.look = nil; probe.crop = nil
        guard let cg = await render(raw: raw, jpeg: jpeg, useRaw: useRaw, adjustments: probe, maxPixel: 1024, draft: true) else { return nil }
        let box = ImageBox(image: cg)
        let start = base
        return await Blocking.run {
            guard let cg = box.image else { return nil }
            var out = start
            for f in CIImage(cgImage: cg).autoAdjustmentFilters(options: [.redEye: false]) {
                switch f.name {
                case "CIVibrance":
                    out.vibrance = min(1, max(-1, (f.value(forKey: "inputAmount") as? Double) ?? 0))
                case "CIHighlightShadowAdjust":
                    out.shadows = min(1, max(-1, (f.value(forKey: "inputShadowAmount") as? Double) ?? 0))
                    out.highlights = min(0, max(-1, ((f.value(forKey: "inputHighlightAmount") as? Double) ?? 1) - 1))
                case "CIToneCurve":
                    let pts = (0...4).compactMap { f.value(forKey: "inputPoint\($0)") as? CIVector }
                        .map { CurvePoint(x: min(1, max(0, Double($0.x))), y: min(1, max(0, Double($0.y)))) }
                        .sorted { $0.x < $1.x }
                    if pts.count == 5, pts.contains(where: { abs($0.x - $0.y) > 0.004 }) {
                        var curve = pts
                        curve[0].x = 0; curve[4].x = 1
                        out.curves.master = curve
                    }
                default: break   // face balance (skin tone) has no slider here
                }
            }
            return out
        }
    }

    /// `interactive`: while a slider is moving. RAW decoder settings that changed since the last decode
    /// are approximated on the cached decode (instant); the caller follows up with an exact render.
    /// `hdr`: keep highlights above SDR white (for an HDR-capable screen); the result is a half-float,
    /// extended-range image tagged with its headroom. Edits and looks are unchanged below white.
    static func renderScaled(raw: URL?, jpeg: URL?, useRaw: Bool, adjustments adj: Adjustments,
                             maxPixel: Int?, draft: Bool, applyCrop: Bool = true, interactive: Bool = false,
                             hdr: Bool = false) async -> Rendered? {
        if useRaw, let raw { await ResourceGate.shared.prepare(raw) }
        return await Blocking.run {
            renderSync(raw: raw, jpeg: jpeg, useRaw: useRaw, adj: adj, maxPixel: maxPixel, draft: draft,
                       applyCrop: applyCrop, interactive: interactive, hdr: hdr)
        }
    }

    private static func renderSync(raw: URL?, jpeg: URL?, useRaw: Bool, adj: Adjustments,
                                   maxPixel: Int?, draft: Bool, applyCrop: Bool, interactive: Bool = false,
                                   hdr: Bool = false) -> Rendered? {
        var image: (CIImage, Double)?
        if useRaw, let raw { image = cachedRaw(raw, adj: adj, maxPixel: maxPixel, draft: draft, interactive: interactive, hdr: hdr) }
        if image == nil, let src = jpeg ?? raw { image = jpegImage(src, adj: adj, maxPixel: maxPixel, hdr: hdr) }
        guard var (img, scale) = image else { return nil }
        // HDR: edits and looks run on the SDR part (clipped at white, exactly what SDR shows); the
        // highlights' extra brightness is multiplied back afterwards as a gain, like an HDR gain map.
        var hdrParts: (sdr: CIImage, hdr: CIImage)?
        if hdr { let (sdr, full) = HDR.split(img); hdrParts = (sdr, full); img = sdr }
        if let profile = adj.look?.profile {
            // A Picture Profile stands in for the camera; your edits go on top of it.
            img = ProfileEngine.apply(img, profile)
            img = common(img, adj)
        } else {
            img = common(img, adj)
            if let look = adj.look { img = LookEngine.apply(img, look, isRaw: useRaw && raw != nil) }
        }
        if let hdrParts { img = HDR.restore(img, hdr: hdrParts.hdr, sdr: hdrParts.sdr) }
        img = geometry(img, adj, applyCrop: applyCrop)
        scale = scale > 0 ? scale : 1
        if hdr, let cg = HDR.makeImage(img) { return Rendered(image: cg, scale: scale) }
        guard let cg = RAWDecoder.context.createCGImage(img, from: img.extent.integralInward, format: .RGBA8,
                                                        colorSpace: displayP3) else { return nil }
        return Rendered(image: cg, scale: scale)
    }

    // MARK: Geometry — straighten, then crop

    /// Largest rect with the image's own aspect that fits inside it after rotating by `degrees`.
    static func inscribedScale(width W: Double, height H: Double, degrees: Double) -> Double {
        let t = abs(degrees) * .pi / 180, c = cos(t), s = sin(t)
        return min(W / (W * c + H * s), H / (W * s + H * c))
    }

    static func geometry(_ input: CIImage, _ adj: Adjustments, applyCrop: Bool) -> CIImage {
        var img = input
        let e = input.extent
        if adj.angle != 0 {
            let rad = -adj.angle * .pi / 180   // positive slider = clockwise
            let t = CGAffineTransform(translationX: e.midX, y: e.midY).rotated(by: rad).translatedBy(x: -e.midX, y: -e.midY)
            img = img.clampedToExtent().transformed(by: t)
            let k = inscribedScale(width: e.width, height: e.height, degrees: adj.angle)
            let w = e.width * k, h = e.height * k
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
        }
        if applyCrop, let c = adj.crop, c != .full {
            let b = img.extent
            // Normalized top-left rect → Core Image's bottom-left coordinates.
            let r = CGRect(x: b.minX + c.x * b.width, y: b.minY + (1 - c.y - c.h) * b.height,
                           width: c.w * b.width, height: c.h * b.height)
            img = img.cropped(to: r)
        }
        let o = img.extent
        return img.transformed(by: CGAffineTransform(translationX: -o.minX, y: -o.minY))
    }

    // MARK: Decode cache

    /// The decoder-stage settings; a cached decode is reusable when these match.
    private struct RawStage: Hashable {
        var exposure, temperature, tint, contrast, toneMapping, noiseReduction, sharpening: Double
        var dro = 0
        var linear = false
        var hdr = false
        /// Temperature / tint are ABSOLUTE for RAW (as-shot or look WB, plus your offset), so the
        /// approximation can move between looks with different white balance.
        init(_ a: Adjustments, wb: (k: Double, tint: Double)? = nil) {
            exposure = a.exposure; contrast = a.contrast
            toneMapping = a.toneMapping; noiseReduction = a.noiseReduction; sharpening = a.sharpening
            temperature = (wb?.k ?? 0) + a.temperature
            tint = (wb?.tint ?? 0) + a.tint
            dro = a.look?.dro ?? 0
            linear = a.look?.profile != nil
        }
    }

    /// As-shot white balance per RAW (cheap header read, cached).
    private final class WBCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [URL: (Double, Double)] = [:]
        func get(_ url: URL) -> (k: Double, tint: Double) {
            if let v = lock.withLock({ map[url] }) { return v }
            var v = (6500.0, 0.0)
            if let f = CIRAWFilter(imageURL: url) {
                RAWDecoder.configure(f, url: url)
                v = (Double(f.neutralTemperature), Double(f.neutralTint))
            }
            lock.withLock { map[url] = v }
            return v
        }
    }
    private static let asShot = WBCache()

    /// Decoder white balance before your temperature/tint offsets.
    private static func baseWB(_ url: URL, _ a: Adjustments) -> (k: Double, tint: Double) {
        let shot = asShot.get(url)
        guard let look = a.look, LookEngine.needsDecoder(look) else { return shot }
        return LookEngine.whiteBalance(look, asShotK: shot.k, asShotTint: shot.tint)
    }

    private struct CacheKey: Hashable { let url: URL; let maxPixel: Int; let draft: Bool }

    /// Materialized (GPU-rendered, half-float, extended-range) decodes, so edits after the decoder don't
    /// re-run it. Small LRU; full-resolution decodes are big, so at most a few are kept.
    private final class DecodeCache: @unchecked Sendable {
        /// 1/16 of RAM, between 512 MB and 3 GB (a 26 MP half-float decode is ~210 MB).
        static let budget = min(3e9, max(5.12e8, Double(ProcessInfo.processInfo.physicalMemory) / 16))
        private let lock = NSLock()
        private var items: [(key: CacheKey, stage: RawStage, image: CIImage, scale: Double)] = []

        func exact(_ k: CacheKey, _ s: RawStage) -> (CIImage, Double)? {
            lock.withLock { items.first { $0.key == k && $0.stage == s }.map { ($0.image, $0.scale) } }
        }
        func latest(_ k: CacheKey) -> (stage: RawStage, image: CIImage, scale: Double)? {
            lock.withLock { items.first { $0.key == k }.map { ($0.stage, $0.image, $0.scale) } }
        }
        func put(_ k: CacheKey, _ s: RawStage, _ img: CIImage, _ scale: Double) {
            lock.withLock {
                items.removeAll { $0.key == k && $0.stage == s }
                items.insert((k, s, img, scale), at: 0)
                var full = 0
                items = items.filter { e in
                    if e.key.maxPixel == 0 { full += 1; return full <= 1 }
                    return true
                }
                // Memory budget instead of a fixed count: many small decodes (grids, batch jobs) fit,
                // a couple of big ones still evict the rest.
                var bytes = 0.0
                items = items.filter { e in
                    bytes += Double(e.image.extent.width * e.image.extent.height) * 8
                    return bytes <= Self.budget || e.key == k
                }
            }
        }
    }

    private static let decodes = DecodeCache()

    /// One decode per (file, size) at a time: concurrent requests wait for it and reuse the result
    /// instead of all decoding the same RAW (the decoder runs one decode at a time system-wide anyway).
    private final class KeyLocks: @unchecked Sendable {
        private let lock = NSLock()
        private var locks: [CacheKey: NSLock] = [:]
        func lock(for k: CacheKey) -> NSLock {
            lock.withLock {
                if let l = locks[k] { return l }
                let l = NSLock()
                locks[k] = l
                return l
            }
        }
    }
    private static let inFlight = KeyLocks()
    private static let extendedLinearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    private static func cachedRaw(_ url: URL, adj: Adjustments, maxPixel: Int?, draft: Bool, interactive: Bool,
                                  hdr: Bool = false) -> (CIImage, Double)? {
        let key = CacheKey(url: url, maxPixel: maxPixel ?? 0, draft: draft)
        var stage = RawStage(adj, wb: baseWB(url, adj))
        stage.hdr = hdr
        if let hit = decodes.exact(key, stage) { return hit }
        if interactive, let near = decodes.latest(key) {
            return (approximate(near.image, from: near.stage, to: stage), near.scale)
        }
        let gate = inFlight.lock(for: key)
        gate.lock()
        defer { gate.unlock() }
        // Someone else may have just decoded it while we waited.
        if let hit = decodes.exact(key, stage) { return hit }
        if interactive, let near = decodes.latest(key) {
            return (approximate(near.image, from: near.stage, to: stage), near.scale)
        }
        guard let (img, scale) = rawImage(url, adj: adj, maxPixel: maxPixel, draft: draft, hdr: hdr) else { return nil }
        let r = img.extent.integralInward
        guard let cg = RAWDecoder.context.createCGImage(img, from: r, format: .RGBAh, colorSpace: extendedLinearP3) else {
            return (img, scale)
        }
        let materialized = CIImage(cgImage: cg)
        decodes.put(key, stage, materialized, scale)
        return (materialized, scale)
    }

    /// Fast stand-ins for decoder settings while dragging (exact decode follows on release).
    private static func approximate(_ input: CIImage, from a: RawStage, to b: RawStage) -> CIImage {
        var img = input
        if b.exposure != a.exposure {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(b.exposure - a.exposure)
            img = f.outputImage ?? img
        }
        if b.temperature != a.temperature || b.tint != a.tint {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - (b.temperature - a.temperature), y: -(b.tint - a.tint))
            img = f.outputImage ?? img
        }
        if b.contrast != a.contrast {
            let f = CIFilter.colorCurves()
            f.inputImage = img
            f.curvesData = ToneMath.contrastLUT(1 + (b.contrast - a.contrast) * 0.5)
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            img = f.outputImage ?? img
        }
        return img
    }

    // MARK: RAW path — light, colour and detail applied inside the RAW 9 decoder

    /// Chart measurements only (CLI): lens correction moves and shades flat patches.
    nonisolated(unsafe) static var lensCorrectionOff = false

    private static func rawImage(_ url: URL, adj: Adjustments, maxPixel: Int?, draft: Bool, hdr: Bool = false) -> (CIImage, Double)? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        RAWDecoder.configure(f, url: url)
        let side = max(f.nativeSize.width, f.nativeSize.height)
        if let maxPixel, side > 0 { f.scaleFactor = Float(min(1, Double(maxPixel) / side)) }
        f.isDraftModeEnabled = draft
        if lensCorrectionOff { f.isLensCorrectionEnabled = false }
        // HDR: let the decoder keep highlight detail above SDR white (~1 stop on typical Sony RAWs).
        if hdr { f.extendedDynamicRangeAmount = 2 }

        f.exposure = Float(adj.exposure)
        let wb = baseWB(url, adj)
        if adj.temperature != 0 || adj.tint != 0 || (adj.look.map(LookEngine.needsDecoder) ?? false) {
            f.neutralTemperature = clamp(Float(wb.k + adj.temperature), 2000, 50000)
            f.neutralTint = clamp(Float(wb.tint + adj.tint), -150, 150)
        }
        if adj.look?.profile != nil {
            // Picture Profile: bypass the camera tone curve; the profile's gamma replaces it.
            f.boostAmount = 0
            f.boostShadowAmount = 0
            f.extendedDynamicRangeAmount = 2
            if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
        } else if let dro = adj.look?.dro, dro > 0, f.isLocalToneMapSupported {
            f.localToneMapAmount = clamp(f.localToneMapAmount + Float(dro) * 0.12, 0, 1)
        }
        if f.isContrastSupported, adj.contrast != 0 {
            f.contrastAmount = clamp(f.contrastAmount + Float(adj.contrast), -1, 1)
        }
        if f.isLocalToneMapSupported, adj.toneMapping != 0 {
            f.localToneMapAmount = clamp(f.localToneMapAmount + Float(adj.toneMapping), 0, 1)
        }
        if f.isLuminanceNoiseReductionSupported, adj.noiseReduction != 0 {
            f.luminanceNoiseReductionAmount = clamp(f.luminanceNoiseReductionAmount + Float(adj.noiseReduction), 0, 1)
        }
        if f.isColorNoiseReductionSupported, adj.noiseReduction != 0 {
            f.colorNoiseReductionAmount = clamp(f.colorNoiseReductionAmount + Float(adj.noiseReduction), 0, 1)
        }
        if f.isSharpnessSupported, adj.sharpening != 0 {
            f.sharpnessAmount = clamp(f.sharpnessAmount + Float(adj.sharpening), 0, 1)
        }
        return RAWDecoder.output(f).map { ($0, Double(f.scaleFactor)) }
    }

    // MARK: JPEG/HEIC path — equivalent Core Image filters

    /// Decoded + downscaled JPEG/HEIC, cached so slider moves only re-run the (GPU) filters.
    private static func jpegBase(_ url: URL, maxPixel: Int?, hdr: Bool = false) -> (CIImage, Double)? {
        let key = CacheKey(url: url, maxPixel: maxPixel ?? 0, draft: false)
        var stage = RawStage(Adjustments())
        stage.hdr = hdr
        if let hit = decodes.exact(key, stage) { return hit }
        // HDR: HLG/PQ HEIFs and gain-map JPEG/HEICs (iPhone, newer cameras) open with their full range.
        var opts: [CIImageOption: Any] = [.applyOrientationProperty: true]
        if hdr { opts[.expandToHDR] = true }
        guard var img = CIImage(contentsOf: url, options: opts) else { return nil }
        let side = max(img.extent.width, img.extent.height)
        var scale = 1.0
        if let maxPixel, side > CGFloat(maxPixel) {
            let s = CIFilter.lanczosScaleTransform()
            s.inputImage = img
            scale = Double(maxPixel) / Double(side)
            s.scale = Float(scale)
            img = s.outputImage ?? img
        }
        let cg = hdr
            ? RAWDecoder.context.createCGImage(img, from: img.extent.integralInward, format: .RGBAh, colorSpace: extendedLinearP3)
            : RAWDecoder.context.createCGImage(img, from: img.extent.integralInward, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        guard let cg else { return (img, scale) }
        let m = CIImage(cgImage: cg)
        decodes.put(key, stage, m, scale)
        return (m, scale)
    }

    private static func jpegImage(_ url: URL, adj: Adjustments, maxPixel: Int?, hdr: Bool = false) -> (CIImage, Double)? {
        guard let base = jpegBase(url, maxPixel: maxPixel, hdr: hdr) else { return nil }
        var img = base.0
        let scale = base.1
        if adj.temperature != 0 || adj.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - adj.temperature, y: -adj.tint)
            img = f.outputImage ?? img
        }
        if adj.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(adj.exposure)
            img = f.outputImage ?? img
        }
        if adj.contrast != 0 {
            // Pivot at mid-grey on encoded values so contrast doesn't darken/brighten the whole image.
            let f = CIFilter.colorCurves()
            f.inputImage = img
            f.curvesData = ToneMath.contrastLUT(1 + adj.contrast * 0.5)
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            img = f.outputImage ?? img
        }
        if adj.noiseReduction != 0 || adj.sharpening != 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = img.clampedToExtent()
            // CINoiseReduction does nothing below ~0.02, so map the slider onto its useful range.
            f.noiseLevel = adj.noiseReduction > 0 ? Float(0.015 + 0.065 * adj.noiseReduction) : 0
            f.sharpness = Float(0.4 + 1.6 * adj.sharpening)
            img = f.outputImage?.cropped(to: img.extent) ?? img
        }
        return (img, scale)
    }

    // MARK: Shared — local highlights/shadows, colour, tone curves

    private static func common(_ input: CIImage, _ adj: Adjustments) -> CIImage {
        // Neighbourhood filters sample past the edges; clamp so borders don't darken, crop back after.
        var img = denoise(input.clampedToExtent(), adj, extent: input.extent)
        if adj.highlights < 0 || adj.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(1 + min(0, adj.highlights))   // negative = local recovery
            f.shadowAmount = Float(adj.shadows)                     // -1 deepen … +1 lift
            img = f.outputImage ?? img
        }
        if adj.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(adj.vibrance)
            img = f.outputImage ?? img
        }
        if adj.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(1 + adj.saturation)
            img = f.outputImage ?? img
        }
        if ToneCurve.isActive(adj) {
            let f = CIFilter.colorCurves()
            f.inputImage = img
            f.curvesData = ToneCurve.lut(adj)
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = sRGB
            img = f.outputImage ?? img
        }
        return img.cropped(to: input.extent)
    }

    /// Strong NR (extra luminance pass, + median when high) and colour-noise smoothing (chroma only).
    private static func denoise(_ input: CIImage, _ adj: Adjustments, extent: CGRect) -> CIImage {
        var img = input
        if adj.colorNoise > 0 {
            img = chromaDenoise(img, amount: adj.colorNoise, extent: extent)
        }
        if adj.strongNoise > 0 {
            if adj.strongNoise > 0.5 {
                let m = CIFilter.median()
                m.inputImage = img
                img = m.outputImage ?? img
            }
            let f = CIFilter.noiseReduction()
            f.inputImage = img
            f.noiseLevel = Float(0.02 + 0.09 * adj.strongNoise)
            f.sharpness = Float(0.25 + 0.3 * (1 - adj.strongNoise))
            img = f.outputImage ?? img
        }
        return img
    }

    /// Colour-noise reduction: to Y/Cb/Cr (sRGB-encoded, BT.709), blur only Cb/Cr, back to RGB.
    /// Brightness detail is untouched; only colour speckle is smoothed.
    private static func chromaDenoise(_ input: CIImage, amount: Double, extent: CGRect) -> CIImage {
        func matrix(_ img: CIImage, _ r: [CGFloat], _ g: [CGFloat], _ b: [CGFloat], bias: [CGFloat] = [0, 0, 0],
                    resetAlpha: Bool = false) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = img
            f.rVector = CIVector(x: r[0], y: r[1], z: r[2], w: 0)
            f.gVector = CIVector(x: g[0], y: g[1], z: g[2], w: 0)
            f.bVector = CIVector(x: b[0], y: b[1], z: b[2], w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: resetAlpha ? 0 : 1)
            f.biasVector = CIVector(x: bias[0], y: bias[1], z: bias[2], w: resetAlpha ? 1 : 0)
            return f.outputImage ?? img
        }
        let encoded = input.applyingFilter("CILinearToSRGBToneCurve")
        let ycc = matrix(encoded, [0.2126, 0.7152, 0.0722], [-0.1146, -0.3854, 0.5], [0.5, -0.4542, -0.0458], bias: [0, 0.5, 0.5])
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ycc.clampedToExtent()
        // Radius in proportion to the render size (colour noise is a few pixels wide at full resolution).
        blur.radius = Float(max(1.2, Double(max(extent.width, extent.height)) / 6000 * (2 + 10 * amount)))
        guard let blurred = blur.outputImage?.cropped(to: ycc.extent) else { return input }
        let yOnly = matrix(ycc, [1, 0, 0], [0, 0, 0], [0, 0, 0])
        let cOnly = matrix(blurred, [0, 0, 0], [0, 1, 0], [0, 0, 1])
        let add = CIFilter.additionCompositing()
        add.inputImage = yOnly
        add.backgroundImage = cOnly
        guard let sum = add.outputImage else { return input }
        // Addition also adds alpha (1 + 1 = 2), which halves the un-premultiplied colour: undo that.
        let merged = matrix(sum, [2, 0, 0], [0, 2, 0], [0, 0, 2], resetAlpha: true)
        let rgb = matrix(merged, [1, 0, 1.5748], [1, -0.1873, -0.4681], [1, 1.8556, 0],
                         bias: [-1.5748 * 0.5, (0.1873 + 0.4681) * 0.5, -1.8556 * 0.5])
        return rgb.applyingFilter("CISRGBToneCurveToLinear")
    }

    // MARK: Save a copy

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpeg = "JPEG", heic = "HEIC", tiff = "TIFF"
        var id: String { rawValue }
        var ext: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
        var type: UTType { self == .jpeg ? .jpeg : self == .heic ? .heic : .tiff }
    }

    struct SaveOptions: Sendable {
        var format = Format.jpeg
        var quality = 0.92
        var maxPixel: Int? = nil
        var includeLocation = true
    }

    /// Renders and writes a new file. Refuses to write over any existing file (originals included).
    static func saveCopy(raw: URL?, jpeg: URL?, useRaw: Bool, adjustments: Adjustments, location: GeoPoint?,
                         rating: Int? = nil, options: SaveOptions, to dest: URL) async throws {
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw CocoaError(.fileWriteFileExists) }
        guard let cg = await render(raw: raw, jpeg: jpeg, useRaw: useRaw, adjustments: adjustments,
                                    maxPixel: options.maxPixel, draft: false) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let source = (useRaw ? raw : jpeg) ?? jpeg ?? raw
        let ok = await Blocking.run { () -> Bool in
            var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality]
            if let source, let src = CGImageSourceCreateWithURL(source as CFURL, nil),
               let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                for k in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                    if let v = meta[k] { props[k] = v }
                }
                if options.includeLocation, location == nil, let g = meta[kCGImagePropertyGPSDictionary] {
                    props[kCGImagePropertyGPSDictionary] = g
                }
            }
            if options.includeLocation, let loc = location { props[kCGImagePropertyGPSDictionary] = gpsDictionary(loc) }
            if let rating {
                var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
                iptc[kCGImagePropertyIPTCStarRating] = rating
                props[kCGImagePropertyIPTCDictionary] = iptc
            }
            props[kCGImagePropertyOrientation] = 1
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            guard let d = CGImageDestinationCreateWithURL(dest as CFURL, options.format.type.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(d, cg, props as CFDictionary)
            return CGImageDestinationFinalize(d)
        }
        if !ok { throw CocoaError(.fileWriteUnknown) }
    }

    static func gpsDictionary(_ g: GeoPoint) -> [CFString: Any] {
        var d: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(g.latitude),
            kCGImagePropertyGPSLatitudeRef: g.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(g.longitude),
            kCGImagePropertyGPSLongitudeRef: g.longitude >= 0 ? "E" : "W",
        ]
        if let alt = g.altitude {
            d[kCGImagePropertyGPSAltitude] = abs(alt)
            d[kCGImagePropertyGPSAltitudeRef] = alt >= 0 ? 0 : 1
        }
        return d
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, v)) }
}

/// Global tone shaping: whites/blacks/positive highlights as a parametric curve, then the user's master
/// curve, then per-channel curves — baked into one per-channel lookup table for `CIColorCurves`.
enum ToneCurve {
    static func isActive(_ a: Adjustments) -> Bool {
        a.whites != 0 || a.blacks != 0 || a.highlights > 0 || !a.curves.isIdentity
    }

    /// Parametric + master curve for one input level (0...1).
    static func master(_ x: Double, _ a: Adjustments) -> Double {
        var y = x
        y += 0.20 * a.blacks * pow(1 - x, 4)
        y += 0.20 * a.whites * pow(x, 4)
        if a.highlights > 0 { y += 0.22 * a.highlights * exp(-pow((x - 0.75) / 0.16, 2)) }
        y = min(1, max(0, y))
        return CurveMath.eval(a.curves.master, y)
    }

    static func lut(_ a: Adjustments, samples n: Int = 1024) -> Data {
        var out = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            let m = master(x, a)
            out[i * 3] = Float(CurveMath.eval(a.curves.red, m))
            out[i * 3 + 1] = Float(CurveMath.eval(a.curves.green, m))
            out[i * 3 + 2] = Float(CurveMath.eval(a.curves.blue, m))
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Monotone cubic (Fritsch–Carlson) interpolation: smooth, and never overshoots between points.
enum CurveMath {
    static func eval(_ pts: [CurvePoint], _ x: Double) -> Double {
        let p = pts.sorted { $0.x < $1.x }
        guard p.count >= 2 else { return x }
        if x <= p[0].x { return clamp01(p[0].y) }
        if x >= p[p.count - 1].x { return clamp01(p[p.count - 1].y) }
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(1e-9, p[i + 1].x - p[i].x) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x, t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return clamp01(y)
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}

extension CGRect {
    /// Largest whole-pixel rect inside this one (`integral` rounds outward).
    var integralInward: CGRect {
        let x0 = minX.rounded(.up), y0 = minY.rounded(.up)
        let x1 = maxX.rounded(.down), y1 = maxY.rounded(.down)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
