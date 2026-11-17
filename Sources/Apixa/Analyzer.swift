import Foundation
import CoreGraphics
import ImageIO
import Vision

struct ScannedItem: Sendable {
    let baseName: String
    let folder: URL
    var jpeg: URL?
    var raw: URL?
    var fileDate: Date
}

enum MetricsSource: String, Sendable, Codable {
    case preview = "Embedded preview / JPEG"
    case raw = "RAW render"
}

struct AnalysisJob: Sendable {
    let id: UUID
    let displayURL: URL
    let rawURL: URL?
    let isRawOnly: Bool
    let accurateRaw: Bool
}

struct AnalysisResult: @unchecked Sendable {
    var date: Date?
    var source = MetricsSource.preview
    var sensorClip = false
    var thumb: CGImage?
    var featurePrint: VNFeaturePrintObservation?
    var visionImage: CGImage?       // transient: full analysis image, for the async aesthetics request
    var sharpness = 0.0
    var meanLuma = 0.5
    var highClip = 0.0
    var shadowClip = 0.0
    var faceQuality: Double?
    var faceSharpness: Double?
    var aesthetic: Double?
    var faces: [FaceRegion] = []
    var info: ShotInfo?
    var gps: GeoPoint?
}

/// Runs blocking work (ImageIO, pixel loops, sync Vision, Core Image renders) on a dedicated queue so it
/// never occupies Swift's cooperative thread pool. Callers bound concurrency (the analysis TaskGroup).
enum Blocking {
    private static let queue = DispatchQueue(label: "Apixa.blocking", qos: .userInitiated,
                                             attributes: .concurrent)

    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T where T: Sendable {
        await withCheckedContinuation { c in queue.async { c.resume(returning: work()) } }
    }
}

struct ImageBox: @unchecked Sendable {
    let image: CGImage?
}

enum FolderScanner {
    /// Recursively finds images and pairs RAW + JPEG by folder + base name.
    static func scan(_ root: URL) -> [ScannedItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var map: [String: ScannedItem] = [:]
        while let url = en.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            let isRaw = rawExtensions.contains(ext)
            let isJpg = jpegExtensions.contains(ext)
            guard isRaw || isJpg else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            if base.hasPrefix("._") { continue }
            let folder = url.deletingLastPathComponent()
            let key = folder.path + "/" + base.lowercased()
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let date = vals?.creationDate ?? vals?.contentModificationDate ?? Date()
            var item = map[key] ?? ScannedItem(baseName: base, folder: folder, jpeg: nil, raw: nil, fileDate: date)
            if isRaw { item.raw = url } else if item.jpeg == nil { item.jpeg = url }
            item.fileDate = min(item.fileDate, date)
            map[key] = item
        }
        return map.values.sorted { $0.fileDate < $1.fileDate }
    }
}

enum Analyzer {
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    static func analyze(_ job: AnalysisJob) async -> AnalysisResult {
        let raw = job.accurateRaw ? job.rawURL : nil
        if let raw { await ResourceGate.shared.prepare(raw) }
        // Decode, pixel stats and the synchronous Vision requests block (Vision waits on its own
        // queues). Doing that on Swift's cooperative pool starves it and deadlocks, so it runs on
        // a dedicated queue instead.
        var r = await Blocking.run { analyzeSync(job, raw: raw) }
        if let img = r.visionImage,
           let obs = try? await CalculateImageAestheticsScoresRequest().perform(on: img) {
            r.aesthetic = Double(obs.overallScore)
        }
        r.visionImage = nil
        return r
    }

    private static func analyzeSync(_ job: AnalysisJob, raw: URL?) -> AnalysisResult {
        var r = AnalysisResult()
        (r.date, r.info, r.gps) = metadata(job.displayURL)
        if let raw = job.rawURL, r.info?.camera == nil || r.gps == nil {
            let m = metadata(raw)
            r.date = r.date ?? m.date
            r.info = r.info?.camera == nil ? m.info : r.info
            r.gps = r.gps ?? m.gps
        }
        // Fast path (embedded preview / JPEG) drives thumbnails, Vision and therefore stacking.
        guard let img = loadImage(job.displayURL, maxPixel: 1600, isRaw: job.isRawOnly) else { return r }

        var s: (sharp: Double, mean: Double, hi: Double, lo: Double)
        if let raw, let a = RAWDecoder.analysisSync(raw) {
            s = lumaStats(a.gray)
            s.hi = a.clip
            r.source = .raw
            r.sensorClip = true
        } else {
            s = lumaStats(img)
        }
        r.sharpness = s.sharp
        r.meanLuma = s.mean
        r.highClip = s.hi
        r.shadowClip = s.lo
        r.thumb = resize(img, maxSide: 360)
        r.visionImage = img

        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        let fp = VNGenerateImageFeaturePrintRequest()
        fp.revision = VNGenerateImageFeaturePrintRequestRevision2
        let face = VNDetectFaceCaptureQualityRequest()
        try? handler.perform([fp, face])
        r.featurePrint = fp.results?.first
        let faces = face.results ?? []
        r.faces = faces.map { FaceRegion(rect: $0.boundingBox, quality: $0.faceCaptureQuality.map(Double.init)) }
        if let q = faces.compactMap({ $0.faceCaptureQuality }).max() {
            r.faceQuality = Double(q)
        }
        r.faceSharpness = faceSharpness(img, r.faces.map(\.rect))
        return r
    }

    /// The Rate tab's scores measured on a rendered image (used to compare a photo before and after edits).
    struct Measured: Sendable, Equatable {
        var sharpness = 0.0      // 0…1
        var exposure = 0.0       // 0…1
        var mean = 0.0, highClip = 0.0, shadowClip = 0.0
        var face: Double?        // 0…1
        var aesthetic: Double?   // 0…1
    }

    static func measure(_ box: ImageBox) async -> Measured? {
        guard let img = box.image else { return nil }
        var m: Measured = await Blocking.run {
            let s = lumaStats(img)
            var m = Measured(sharpness: PhotoAsset.absoluteSharpness(s.sharp),
                             exposure: PhotoAsset.exposureScore(mean: s.mean, highClip: s.hi, shadowClip: s.lo),
                             mean: s.mean, highClip: s.hi, shadowClip: s.lo)
            let face = VNDetectFaceCaptureQualityRequest()
            try? VNImageRequestHandler(cgImage: img, options: [:]).perform([face])
            m.face = (face.results ?? []).compactMap { $0.faceCaptureQuality }.max().map(Double.init)
            return m
        }
        if let obs = try? await CalculateImageAestheticsScoresRequest().perform(on: img) {
            m.aesthetic = (Double(obs.overallScore) + 1) / 2
        }
        return m
    }

    /// Sharpness where it matters for people photos: on the largest face (Vision rect, origin bottom-left).
    static func faceSharpness(_ img: CGImage, _ faces: [CGRect]) -> Double? {
        guard let f = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let r = CGRect(x: f.minX * W, y: (1 - f.maxY) * H, width: f.width * W, height: f.height * H).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard r.width >= 24, r.height >= 24, let crop = img.cropping(to: r) else { return nil }
        // Same scale for every face, so a close-up and a distant face are comparable.
        let side = 160
        var buf = [UInt8](repeating: 0, count: side * side)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var s = 0.0, s2 = 0.0, n = 0.0
        for y in 1..<(side - 1) { for x in 1..<(side - 1) {
            let i = y * side + x
            let l = Double(4 * Int(buf[i]) - Int(buf[i - 1]) - Int(buf[i + 1]) - Int(buf[i - side]) - Int(buf[i + side]))
            s += l; s2 += l * l; n += 1
        } }
        // Small faces were upscaled to 160 px, which softens them; scale the result back so they aren't punished.
        let up = max(1, Double(side) / Double(min(r.width, r.height)))
        return (s2 / n - (s / n) * (s / n)) * up * up
    }

    /// For cached analyses made before face sharpness existed: measure it from the display image only.
    static func faceSharpness(displayURL: URL, isRaw: Bool, faces: [CGRect]) -> Double? {
        guard !faces.isEmpty, let img = loadImage(displayURL, maxPixel: 1600, isRaw: isRaw) else { return nil }
        return faceSharpness(img, faces)
    }

    /// Fast decode. For RAW, prefers the embedded preview JPEG (much faster than a full RAW decode).
    static func loadImage(_ url: URL, maxPixel: Int, isRaw: Bool) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func thumb(always: Bool) -> CGImage? {
            var opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if always {
                opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
            } else {
                opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if isRaw, let t = thumb(always: false), max(t.width, t.height) >= min(800, maxPixel) {
            return t
        }
        return thumb(always: true)
    }

    /// Capture date (with sub-seconds), camera/exposure info and embedded GPS.
    static func metadata(_ url: URL) -> (date: Date?, info: ShotInfo?, gps: GeoPoint?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, nil, nil) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gpsDict = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var date: Date?
        if let s = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String),
           var d = exifFormatter.date(from: s) {
            if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
               let frac = Double("0." + sub.trimmingCharacters(in: .whitespaces)) {
                d += frac
            }
            date = d
        }

        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        let camera = [make, model].compactMap { $0 }.joined(separator: " ")
        let info = ShotInfo(
            camera: camera.isEmpty ? nil : camera,
            lens: exif?[kCGImagePropertyExifLensModel] as? String,
            focalLength: exif?[kCGImagePropertyExifFocalLength] as? Double,
            aperture: exif?[kCGImagePropertyExifFNumber] as? Double,
            shutter: exif?[kCGImagePropertyExifExposureTime] as? Double,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            width: props[kCGImagePropertyPixelWidth] as? Int,
            height: props[kCGImagePropertyPixelHeight] as? Int)

        var gps: GeoPoint?
        if let lat = gpsDict?[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gpsDict?[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gpsDict?[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gpsDict?[kCGImagePropertyGPSLongitudeRef] as? String
            gps = GeoPoint(latitude: latRef == "S" ? -lat : lat, longitude: lonRef == "W" ? -lon : lon,
                           altitude: gpsDict?[kCGImagePropertyGPSAltitude] as? Double)
        }
        return (date, info, gps)
    }

    static func resize(_ img: CGImage, maxSide: Int) -> CGImage? {
        let s = Double(maxSide) / Double(max(img.width, img.height))
        if s >= 1 { return img }
        let w = max(1, Int(Double(img.width) * s))
        let h = max(1, Int(Double(img.height) * s))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Sharpness = mean Laplacian variance of the 3 sharpest tiles in a 4x4 grid
    /// (so a sharp subject on a blurred background still scores well).
    /// Exposure = mean luminance + fraction of clipped highlights / crushed shadows.
    static func lumaStats(_ img: CGImage) -> (sharp: Double, mean: Double, hi: Double, lo: Double) {
        let w = img.width, h = img.height
        guard w >= 16, h >= 16 else { return (0, 0.5, 0, 0) }
        var buf = [UInt8](repeating: 0, count: w * h)
        var ok = false
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            ok = true
        }
        guard ok else { return (0, 0.5, 0, 0) }

        var sum = 0, hi = 0, lo = 0
        for v in buf {
            sum += Int(v)
            if v >= 250 { hi += 1 }
            if v <= 5 { lo += 1 }
        }
        let n = Double(w * h)

        let tiles = 4
        var tSum = [Double](repeating: 0, count: tiles * tiles)
        var tSq = [Double](repeating: 0, count: tiles * tiles)
        var tN = [Double](repeating: 0, count: tiles * tiles)
        for y in 1..<(h - 1) {
            let row = y * w
            let ty = (y * tiles / h) * tiles
            for x in 1..<(w - 1) {
                let i = row + x
                let lap = 4 * Int(buf[i]) - Int(buf[i - 1]) - Int(buf[i + 1]) - Int(buf[i - w]) - Int(buf[i + w])
                let t = ty + (x * tiles / w)
                let d = Double(lap)
                tSum[t] += d
                tSq[t] += d * d
                tN[t] += 1
            }
        }
        var vars: [Double] = (0..<(tiles * tiles)).map { t in
            let cnt = max(1, tN[t])
            let m = tSum[t] / cnt
            return tSq[t] / cnt - m * m
        }
        vars.sort(by: >)
        let sharp = (vars[0] + vars[1] + vars[2]) / 3

        return (sharp, Double(sum) / n / 255.0, Double(hi) / n, Double(lo) / n)
    }
}

/// Immutable snapshot of what stacking needs, so it can run off the main actor.
struct StackInput: @unchecked Sendable {   // VNFeaturePrintObservation is immutable; distance reads are thread-safe
    let id: UUID
    let date: Date
    let baseName: String
    let featurePrint: VNFeaturePrintObservation?
    let sharpness: Double
    let exposure: Double
    let face: Double?
    let faceSharpness: Double?
    let aesthetic: Double?
    let userRating: Int?
    let isPortrait: Bool?

    @MainActor init(_ a: PhotoAsset) {
        id = a.id; date = a.captureDate; baseName = a.baseName; featurePrint = a.featurePrint
        sharpness = a.sharpness; exposure = a.exposureScore; face = a.faceQuality; aesthetic = a.aesthetic
        userRating = a.userRating
        faceSharpness = a.faceSharpness.flatMap { $0 >= 0 ? $0 : nil }   // negative = no usable face
        isPortrait = a.thumbnail.map { $0.size.height > $0.size.width }
    }
}

struct StackScore: Sendable {
    let sharpnessScore: Double
    let score: Double
    let stars: Int
    let isBest: Bool
    var detail = RatingDetail()
}

/// Everything that went into a shot's automatic rating, for the Rate tab's breakdown.
struct RatingDetail: Sendable, Equatable {
    var faceRank: Double?        // 0…1: share of the folder's faces this one beats
    var aestheticRank: Double?   // 0…1: share of the folder this shot's aesthetics beat
    var exposure = 0.0           // 0…1
    var focus = 1.0              // 0…1 in-focus check
    var frameSharpness = 0.0     // 0…1
    var faceSharpness: Double?   // 0…1
    var content = 0.0            // weighted mix before the focus check
    var rank = 0                 // 1 = best in the folder
    var total = 0
    var rankedStars = 0          // stars from rank alone, before caps
    var cap: String?             // why the stars were capped, if they were
    var pick = 0.0               // score used to choose the best of a stack
    var pickRank = 1             // 1 = best of its stack
    var stackSize = 1
    var relativeSharpness = 1.0  // vs the sharpest shot in its stack
    var sharpnessUsesFace = false
}

struct StackOutput: Sendable {
    let groups: [[UUID]]
    let scores: [UUID: StackScore]
}

enum Stacker {
    static func distance(_ a: StackInput, _ b: StackInput) -> Float? {
        guard let fa = a.featurePrint, let fb = b.featurePrint else { return nil }
        var d: Float = 0
        do { try fa.computeDistance(&d, to: fb) } catch { return nil }
        return d
    }

    /// How different two shots may look and still stack. Shots fired within a few seconds are very likely
    /// the same picture; as the gap grows they must look more alike, so a new composition of the same
    /// scene starts its own stack.
    static func limit(_ maxDistance: Float, gap: TimeInterval) -> Float {
        maxDistance * Float(1 - 0.3 * min(1, max(0, (gap - 3) / 12)))
    }

    /// Groups consecutive shots that are close in time AND visually similar, then scores each group.
    static func build(_ inputs: [StackInput], maxGap: TimeInterval, maxDistance: Float) -> StackOutput {
        let sorted = inputs.sorted {
            $0.date == $1.date ? $0.baseName < $1.baseName : $0.date < $1.date
        }
        // A shot joins the current stack only if it is close in time, has the same orientation, looks like
        // one of the last few shots, AND still looks like the stack's first shot. The last check stops
        // gradual drift (a pose change, the car turning a corner) from chaining different scenes together.
        var groups: [[StackInput]] = []
        for a in sorted {
            if let cur = groups.last, let first = cur.first, let last = cur.last,
               a.date.timeIntervalSince(last.date) <= maxGap,
               a.isPortrait == nil || first.isPortrait == nil || a.isPortrait == first.isPortrait,
               (distance(first, a) ?? .infinity) <= maxDistance,
               cur.suffix(3).contains(where: { (distance($0, a) ?? .infinity) <= limit(maxDistance, gap: a.date.timeIntervalSince($0.date)) }) {
                groups[groups.count - 1].append(a)
            } else {
                groups.append([a])
            }
        }
        let q = qualities(inputs)
        var scores: [UUID: StackScore] = [:]
        for g in groups { score(g, quality: q, into: &scores) }
        assignStars(inputs, &scores)
        return StackOutput(groups: groups.map { $0.map(\.id) }, scores: scores)
    }

    /// Is the shot in focus? Raw sharpness depends on what's in the picture (stone paths read sharper
    /// than skin), so it only gates the score: soft shots lose, but texture earns no bonus.
    static func focus(_ a: StackInput) -> Double {
        let best = max(PhotoAsset.absoluteSharpness(a.sharpness), a.faceSharpness.map(PhotoAsset.absoluteSharpness) ?? 0)
        let t = min(1, max(0, (best - 0.5) / 0.25))
        return t * t * (3 - 2 * t)
    }

    /// Quality of every shot, 0…1, relative to the rest of the folder. Face capture quality (expression,
    /// eyes, pose) and Vision's aesthetics score are ranked within the folder so people shots and scenery
    /// are judged on the same footing; exposure adds a little; focus gates the result.
    static func qualities(_ inputs: [StackInput]) -> [UUID: (Double, RatingDetail)] {
        func ranks(_ value: (StackInput) -> Double?) -> [UUID: Double] {
            let have = inputs.compactMap { a in value(a).map { (a.id, $0) } }.sorted { $0.1 < $1.1 }
            guard have.count > 1 else { return Dictionary(uniqueKeysWithValues: have.map { ($0.0, 0.5) }) }
            return Dictionary(uniqueKeysWithValues: have.enumerated().map { ($1.0, Double($0) / Double(have.count - 1)) })
        }
        let faceRank = ranks { $0.face }, aesRank = ranks { $0.aesthetic }
        var out: [UUID: (Double, RatingDetail)] = [:]
        for a in inputs {
            let aes = aesRank[a.id] ?? 0.5
            let content = faceRank[a.id].map { 0.5 * $0 + 0.35 * aes + 0.15 * a.exposure } ?? (0.7 * aes + 0.3 * a.exposure)
            let f = focus(a)
            let d = RatingDetail(faceRank: faceRank[a.id], aestheticRank: aesRank[a.id], exposure: a.exposure, focus: f,
                                 frameSharpness: PhotoAsset.absoluteSharpness(a.sharpness),
                                 faceSharpness: a.faceSharpness.map(PhotoAsset.absoluteSharpness), content: content)
            out[a.id] = (content * (0.5 + 0.5 * f), d)
        }
        return out
    }

    static func score(_ m: [StackInput], quality: [UUID: (Double, RatingDetail)], into out: inout [UUID: StackScore]) {
        // Within a stack it's the same scene, so sharpness is comparable: face sharpness if every shot has it.
        let useFace = m.allSatisfy { $0.faceSharpness != nil }
        func subject(_ a: StackInput) -> Double { useFace ? a.faceSharpness! : a.sharpness }
        let maxSharp = max(m.map(subject).max() ?? 0, 1e-6)
        var tmp: [(UUID, Double, Double, Double, Int)] = []
        var rels: [UUID: Double] = [:]
        for a in m {
            let rel = subject(a) / maxSharp
            rels[a.id] = rel
            let aes = a.aesthetic.map { ($0 + 1) / 2 } ?? 0.5
            // Best of a burst: the best face (expression, eyes), then the sharpest frame.
            let pick = a.face.map { 0.5 * $0 + 0.25 * rel + 0.15 * aes + 0.1 * a.exposure } ?? (0.5 * rel + 0.3 * aes + 0.2 * a.exposure)
            let shown = max(PhotoAsset.absoluteSharpness(a.sharpness), a.faceSharpness.map(PhotoAsset.absoluteSharpness) ?? 0)
            tmp.append((a.id, shown, quality[a.id]?.0 ?? 0, pick, a.userRating ?? 0))
        }
        // Your star rating wins; the computed score breaks ties (and decides when nothing is rated).
        let bestID = tmp.max(by: { ($0.4, $0.3) < ($1.4, $1.3) })?.0
        let order = tmp.sorted { ($0.4, $0.3) > ($1.4, $1.3) }.map(\.0)
        for (id, sharp, q, pick, _) in tmp {
            var d = quality[id]?.1 ?? RatingDetail()
            d.pick = pick; d.pickRank = (order.firstIndex(of: id) ?? 0) + 1; d.stackSize = m.count
            d.relativeSharpness = rels[id] ?? 1; d.sharpnessUsesFace = useFace
            out[id] = StackScore(sharpnessScore: sharp, score: q, stars: 3, isBest: id == bestID, detail: d)
        }
    }

    /// Stars rank each shot within the folder (top 10% → 5★, next 25% → 4★, 35% → 3★, 20% → 2★, rest 1★),
    /// so they actually separate the keepers. Soft and badly exposed shots are capped.
    static func assignStars(_ inputs: [StackInput], _ scores: inout [UUID: StackScore]) {
        let ranked = inputs.compactMap { a in scores[a.id].map { (a, $0) } }.sorted { $0.1.score > $1.1.score }
        let n = ranked.count
        for (i, (a, sc)) in ranked.enumerated() {
            var stars: Int
            if n >= 8 {
                let p = Double(i) / Double(n)
                stars = p < 0.10 ? 5 : p < 0.35 ? 4 : p < 0.70 ? 3 : p < 0.90 ? 2 : 1
            } else {
                stars = 3   // too few shots to rank
            }
            var d = sc.detail
            d.rank = i + 1; d.total = n; d.rankedStars = stars
            if focus(a) < 0.3, stars > 2 { stars = 2; d.cap = "Capped at 2★ because it looks soft" }
            if a.exposure < 0.4, stars > 3 { stars = 3; d.cap = "Capped at 3★ because of the exposure" }
            scores[a.id] = StackScore(sharpnessScore: sc.sharpnessScore, score: sc.score, stars: stars, isBest: sc.isBest, detail: d)
        }
    }
}
