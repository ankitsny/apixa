import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Learns Sony Creative Looks from the camera's own RAW+JPEG pairs.
///
/// For every JPEG whose maker notes say which Creative Look the camera used, Apixa renders the RAW with
/// no look (its neutral base) and pairs those pixels with the camera's JPEG. A 3D colour LUT per look is
/// fitted from those pairs (with a smooth global fallback for colours never seen), validated on held-out
/// shots, and saved in Apixa's library. `LookEngine` then uses the learned LUT instead of the hand-tuned
/// approximation for that look.
enum LookCalibration {
    static let size = 17

    /// Sony maker-note ColorMode → Creative Look (codes confirmed visually on real files).
    static func look(fromColorMode v: Any?) -> CreativeLook? {
        switch "\(v ?? "")" {
        case "Standard", "0": .ST
        case "Vivid", "1": .VV
        case "Portrait", "2": .PT
        case "Neutral", "12": .NT
        case "17": .SE
        case "18": .FL
        case "19": .VV2
        case "20": .IN
        case "21": .SH
        default: nil
        }
    }

    static func cameraLook(_ jpeg: URL) -> CreativeLook? {
        guard let src = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let ps = p["{PictureStyle}"] as? [String: Any] else { return nil }
        if let mono = (ps["Monochrome"] as? [Any])?.first, "\(mono)" == "1" { return .BW }
        return look(fromColorMode: (ps["ColorMode"] as? [Any])?.first)
    }

    // MARK: Storage

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apixa/look-calibration", isDirectory: true)
    }

    struct Meta: Codable {
        var look: String
        var trainShots: Int
        var testShots: Int
        var deltaEHandTuned: Double
        var deltaELearned: Double
        var created: Date
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var luts: [CreativeLook: Data?] = [:]
        var bypass = false
        var tables: [String: Data?] = [:]
    }
    private static let cache = Cache()

    /// While true, `lut(_:)` returns nil so the hand-tuned looks can be measured.
    static var bypass: Bool {
        get { cache.lock.withLock { cache.bypass } }
        set { cache.lock.withLock { cache.bypass = newValue } }
    }

    /// The learned LUT for a look (RGBA float, `size`³), or nil if none was learned.
    static func lut(_ look: CreativeLook) -> Data? {
        cache.lock.withLock {
            if cache.bypass { return nil }
            if let v = cache.luts[look] { return v }
            let d = try? Data(contentsOf: dir.appendingPathComponent("\(look.rawValue).lut"))
            cache.luts[look] = d
            return d
        }
    }

    static func save(_ look: CreativeLook, lut: Data, meta: Meta) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lut.write(to: dir.appendingPathComponent("\(look.rawValue).lut"), options: .atomic)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted; enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: dir.appendingPathComponent("\(look.rawValue).json"), options: .atomic)
        cache.lock.withLock { cache.luts[look] = lut }
    }

    /// Extra colour tables by name (e.g. "FL.rel", "ST.ILCE-6700.base").
    static func saveTable(_ lut: Data, name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lut.write(to: dir.appendingPathComponent(name + ".lut"), options: .atomic)
        cache.lock.withLock { cache.tables[name] = lut }
    }

    static func table(_ name: String) -> Data? {
        cache.lock.withLock {
            if cache.bypass { return nil }
            if let v = cache.tables[name] { return v }
            let d = try? Data(contentsOf: dir.appendingPathComponent(name + ".lut"))
            cache.tables[name] = d
            return d
        }
    }

    /// Remove a learned look (moved to the Trash, so it can be restored).
    static func forget(_ look: CreativeLook) {
        for ext in ["lut", "json", "rel.lut"] {
            let u = dir.appendingPathComponent("\(look.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        }
        cache.lock.withLock { cache.luts[look] = .some(nil); cache.tables["\(look.rawValue).rel"] = .some(nil) }
    }

    static func meta(_ look: CreativeLook) -> Meta? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: dir.appendingPathComponent("\(look.rawValue).json"))).flatMap { try? dec.decode(Meta.self, from: $0) }
    }

    static func apply(_ img: CIImage, lut: Data) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = img
        f.cubeDimension = Float(dimension(lut))
        f.cubeData = lut
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return f.outputImage ?? img
    }

    // MARK: Pixels

    /// Bumped whenever the neutral base render changes, so cached base pixels are re-rendered.
    static let baseRenderVersion = 1

    /// Disk cache of a RAW's neutral base render at compare size (keyed by path, size and date).
    static func pixelCacheURL(_ raw: URL, side: Int) -> URL? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: raw.path),
              let size = a[.size] as? Int, let date = a[.modificationDate] as? Date else { return nil }
        let key = "\(raw.path)|\(size)|\(date.timeIntervalSince1970)|\(side)|v\(baseRenderVersion)"
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent("pixels", isDirectory: true).appendingPathComponent(String(h, radix: 16) + ".px")
    }

    static func loadPixels(_ u: URL, count: Int) -> [SIMD3<Float>]? {
        guard let d = try? Data(contentsOf: u), d.count == count * 12 else { return nil }
        let f: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (0..<count).map { SIMD3(f[$0 * 3], f[$0 * 3 + 1], f[$0 * 3 + 2]) }
    }

    static func savePixels(_ px: [SIMD3<Float>], to u: URL) {
        var f = [Float](); f.reserveCapacity(px.count * 3)
        for p in px { f.append(p.x); f.append(p.y); f.append(p.z) }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? f.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: u, options: .atomic)
    }

    /// sRGB-encoded RGB triples (0…1) of an image drawn at w×h.
    static func pixels(_ img: CGImage, w: Int, h: Int) -> [SIMD3<Float>] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<(w * h)).map { SIMD3(Float(px[$0 * 4]), Float(px[$0 * 4 + 1]), Float(px[$0 * 4 + 2])) / 255 }
    }

    // MARK: Colour difference (CIE76 in Lab)

    static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func deltaE(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Double {
        var s = 0.0
        for i in a.indices { let d = lab(a[i]) - lab(b[i]); s += Double((d * d).sum().squareRoot()) }
        return s / Double(max(1, a.count))
    }

    struct Stats: Sendable { var L = 0.0, contrast = 0.0, chroma = 0.0, warmth = 0.0 }

    static func stats(_ px: [SIMD3<Float>]) -> Stats {
        let labs = px.map(lab)
        let n = Double(labs.count)
        let meanL = labs.reduce(0.0) { $0 + Double($1.x) } / n
        let varL = labs.reduce(0.0) { $0 + pow(Double($1.x) - meanL, 2) } / n
        let chroma = labs.reduce(0.0) { $0 + Double(($1.y * $1.y + $1.z * $1.z).squareRoot()) } / n
        let warmth = labs.reduce(0.0) { $0 + Double($1.z) } / n
        return Stats(L: meanL, contrast: varL.squareRoot(), chroma: chroma, warmth: warmth)
    }

    // MARK: Fitting

    /// 3D LUT from (source, target) pairs: trilinear splatting into a 17³ grid, blended with a global
    /// affine fit where data is sparse, so unseen colours still map sensibly.
    static func fit(_ pairs: [(SIMD3<Float>, SIMD3<Float>)]) -> Data {
        let n = size
        var sum = [SIMD3<Double>](repeating: .zero, count: n * n * n)
        var wsum = [Double](repeating: 0, count: n * n * n)
        // Global affine (least squares) as the prior.
        let affine = fitAffine(pairs)
        for (s, t) in pairs {
            let p = s * Float(n - 1)
            let i0 = SIMD3<Int>(Int(p.x).clamped(0, n - 2), Int(p.y).clamped(0, n - 2), Int(p.z).clamped(0, n - 2))
            let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let w = Double((dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z))
                guard w > 0 else { continue }
                let idx = ((i0.z + dz) * n + (i0.y + dy)) * n + (i0.x + dx)
                sum[idx] += SIMD3<Double>(Double(t.x), Double(t.y), Double(t.z)) * w
                wsum[idx] += w
            } } }
        }
        let prior = 6.0   // how many "samples" the affine fallback is worth at each node
        var out = [Float](repeating: 0, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let idx = (b * n + g) * n + r
            let src = SIMD3<Double>(Double(r), Double(g), Double(b)) / Double(n - 1)
            let a = affine(src)
            let v = (sum[idx] + a * prior) / (wsum[idx] + prior)
            out[idx * 4] = Float(v.x.clamped(0, 1)); out[idx * 4 + 1] = Float(v.y.clamped(0, 1))
            out[idx * 4 + 2] = Float(v.z.clamped(0, 1)); out[idx * 4 + 3] = 1
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Cube dimension of a stored LUT (RGBA float).
    static func dimension(_ lut: Data) -> Int { Int(cbrt(Double(lut.count / 16)).rounded()) }

    /// Finer LUT for well-aligned pairs: global affine + per-node residuals, with the residual spread
    /// smoothly into nodes that have little or no data (so unseen colours follow their neighbours).
    static func fitSmooth(_ pairs: [(SIMD3<Float>, SIMD3<Float>)], size n: Int = 33, lambda: Double = 0.5, iterations: Int = 120) -> Data {
        let affine = fitAffine(pairs)
        let count = n * n * n
        var sum = [SIMD3<Double>](repeating: .zero, count: count)
        var w = [Double](repeating: 0, count: count)
        for (s, t) in pairs {
            let sd = SIMD3<Double>(Double(s.x), Double(s.y), Double(s.z))
            let r = SIMD3<Double>(Double(t.x), Double(t.y), Double(t.z)) - affine(sd)
            let p = s * Float(n - 1)
            let i0 = SIMD3<Int>(Int(p.x).clamped(0, n - 2), Int(p.y).clamped(0, n - 2), Int(p.z).clamped(0, n - 2))
            let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let wt = Double((dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z))
                guard wt > 0 else { continue }
                let idx = ((i0.z + dz) * n + (i0.y + dy)) * n + (i0.x + dx)
                sum[idx] += r * wt; w[idx] += wt
            } } }
        }
        var data = sum
        for i in 0..<count where w[i] > 0 { data[i] = sum[i] / w[i] }
        var r = data
        for _ in 0..<iterations {
            for z in 0..<n { for y in 0..<n { for x in 0..<n {
                let i = (z * n + y) * n + x
                var nb = SIMD3<Double>.zero, c = 0.0
                if x > 0 { nb += r[i - 1]; c += 1 }; if x < n - 1 { nb += r[i + 1]; c += 1 }
                if y > 0 { nb += r[i - n]; c += 1 }; if y < n - 1 { nb += r[i + n]; c += 1 }
                if z > 0 { nb += r[i - n * n]; c += 1 }; if z < n - 1 { nb += r[i + n * n]; c += 1 }
                r[i] = (data[i] * w[i] + nb / c * lambda) / (w[i] + lambda)
            } } }
        }
        var out = [Float](repeating: 0, count: count * 4)
        for b in 0..<n { for g in 0..<n { for rr in 0..<n {
            let i = (b * n + g) * n + rr
            let v = affine(SIMD3<Double>(Double(rr), Double(g), Double(b)) / Double(n - 1)) + r[i]
            out[i * 4] = Float(v.x.clamped(0, 1)); out[i * 4 + 1] = Float(v.y.clamped(0, 1))
            out[i * 4 + 2] = Float(v.z.clamped(0, 1)); out[i * 4 + 3] = 1
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// target ≈ M·[r,g,b,1] per channel, solved by normal equations.
    private static func fitAffine(_ pairs: [(SIMD3<Float>, SIMD3<Float>)]) -> (SIMD3<Double>) -> SIMD3<Double> {
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var atb = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
        for (s, t) in pairs {
            let x = [Double(s.x), Double(s.y), Double(s.z), 1]
            let y = [Double(t.x), Double(t.y), Double(t.z)]
            for i in 0..<4 { for j in 0..<4 { ata[i][j] += x[i] * x[j] }; for c in 0..<3 { atb[c][i] += x[i] * y[c] } }
        }
        for i in 0..<4 { ata[i][i] += 1e-6 }
        let m = (0..<3).map { solve4(ata, atb[$0]) }
        return { v in
            let x = [v.x, v.y, v.z, 1.0]
            return SIMD3((0..<4).reduce(0) { $0 + m[0][$1] * x[$1] },
                         (0..<4).reduce(0) { $0 + m[1][$1] * x[$1] },
                         (0..<4).reduce(0) { $0 + m[2][$1] * x[$1] })
        }
    }

    private static func solve4(_ a0: [[Double]], _ b0: [Double]) -> [Double] {
        var a = a0, b = b0
        for c in 0..<4 {
            let p = (c..<4).max { abs(a[$0][c]) < abs(a[$1][c]) }!
            a.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<4 where r != c {
                let f = a[r][c] / a[c][c]
                for k in c..<4 { a[r][k] -= f * a[c][k] }
                b[r] -= f * b[c]
            }
        }
        return (0..<4).map { b[$0] / a[$0][$0] }
    }

    /// Apply a LUT to pixels on the CPU (trilinear), for validation.
    static func applyCPU(_ px: [SIMD3<Float>], _ lut: Data) -> [SIMD3<Float>] {
        let n = dimension(lut)
        let t: [Float] = lut.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let i = ((b * n + g) * n + r) * 4
            return SIMD3(t[i], t[i + 1], t[i + 2])
        }
        return px.map { c in
            let p = c * Float(n - 1)
            let r0 = Int(p.x).clamped(0, n - 2), g0 = Int(p.y).clamped(0, n - 2), b0 = Int(p.z).clamped(0, n - 2)
            let f = p - SIMD3(Float(r0), Float(g0), Float(b0))
            var v = SIMD3<Float>.zero
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let w = (dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z)
                v += at(r0 + dx, g0 + dy, b0 + dz) * w
            } } }
            return v
        }
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(hi, max(lo, self)) }
}
