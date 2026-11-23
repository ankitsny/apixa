import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage

/// Learns looks from a colour-chart RAW rendered by Imaging Edge (CHART.ARW + CHART-<LOOK>.TIF).
/// Patch colours are sampled outside the app (chart.json + samples/<apixa|LOOK>.json: [r,g,b,sd] per patch);
/// this fits Apixa's neutral render → Sony look directly, one table per look ("<LOOK>.chart.lut").
enum ChartFit {
    /// Apixa's neutral render of a RAW, full size, as a 16-bit sRGB TIFF.
    static func renderTIFF(_ raw: URL, to out: URL) async -> Bool {
        Develop.lensCorrectionOff = true
        guard let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: nil, draft: false),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { return false }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let _ = { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true }(),
              let out16 = ctx.makeImage() else { return false }
        CGImageDestinationAddImage(dest, out16, nil)
        return CGImageDestinationFinalize(dest)
    }

    typealias Pair = (SIMD3<Float>, SIMD3<Float>)
    nonisolated static let lambda = Double(ProcessInfo.processInfo.environment["CHART_LAMBDA"] ?? "") ?? 0.2
    nonisolated static let size = Int(ProcessInfo.processInfo.environment["CHART_SIZE"] ?? "") ?? 33
    nonisolated static let iters = Int(ProcessInfo.processInfo.environment["CHART_ITERS"] ?? "") ?? 200
    nonisolated static func inner(_ c: SIMD3<Float>) -> Bool { c.min() > 0.004 && c.max() < 0.996 }

    static func loadSamples(_ u: URL) -> [[Float]]? {
        (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[Double]] }?.map { $0.map(Float.init) }
    }

    /// Clean pairs (both renders flat at the patch), Apixa → Sony.
    static func pairs(_ a: [[Float]], _ s: [[Float]]) -> [Pair] {
        zip(a, s).compactMap { x, y in
            guard x[3] < 0.01, y[3] < 0.01 else { return nil }
            let c = { (v: [Float]) in SIMD3(min(1, max(0, v[0])), min(1, max(0, v[1])), min(1, max(0, v[2]))) }
            return (c(x), c(y))
        }
    }

    static func dE(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> (mean: Double, p95: Double) {
        let d = zip(a, b).map { x, y -> Double in let v = LookCalibration.lab(x) - LookCalibration.lab(y); return Double((v * v).sum().squareRoot()) }.sorted()
        return (d.reduce(0, +) / Double(max(1, d.count)), d.isEmpty ? 0 : d[min(d.count - 1, d.count * 95 / 100)])
    }

    @MainActor
    static func run(chartDirs: [URL], scenes: [URL], save: Bool, log: (String) -> Void) async {
        let sdirs = chartDirs.map { $0.appendingPathComponent("samples") }
        let apixas = sdirs.map { loadSamples($0.appendingPathComponent("apixa.json")) }
        guard apixas.allSatisfy({ $0 != nil }) else { log("missing samples/apixa.json"); return }
        let looks = CreativeLook.allCases.filter { l in sdirs.allSatisfy { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(l.rawValue).json").path) } }
        var tables: [CreativeLook: Data] = [:]
        log("chart fit — held-out patches (5-fold), ΔE mean / p95")
        for look in looks {
            var acc: [Pair] = []
            for (k, d) in sdirs.enumerated() {
                guard let sony = loadSamples(d.appendingPathComponent("\(look.rawValue).json")) else { continue }
                acc += pairs(apixas[k]!, sony)
            }
            let p = acc
            // 5-fold cross-validation on the chart.
            var pred: [SIMD3<Float>] = [], truth: [SIMD3<Float>] = []
            await withTaskGroup(of: ([SIMD3<Float>], [SIMD3<Float>]).self) { g in
                for k in 0..<5 {
                    g.addTask {
                        let train = p.enumerated().filter { $0.offset % 5 != k }.map(\.element)
                        let test = p.enumerated().filter { $0.offset % 5 == k }.map(\.element)
                        let lut = LookCalibration.fitSmooth(train, size: ChartFit.size, lambda: ChartFit.lambda, iterations: ChartFit.iters)
                        return (LookCalibration.applyCPU(test.map(\.0), lut), test.map(\.1))
                    }
                }
                for await (a, b) in g { pred += a; truth += b }
            }
            let none = dE(p.map(\.0), p.map(\.1))
            let cv = dE(pred, truth)
            // Held-out error on patches neither render clipped (ordinary colours).
            var pIn: [SIMD3<Float>] = [], tIn: [SIMD3<Float>] = []
            await withTaskGroup(of: ([SIMD3<Float>], [SIMD3<Float>]).self) { g in
                for k in 0..<5 {
                    g.addTask {
                        let train = p.enumerated().filter { $0.offset % 5 != k }.map(\.element)
                        let test = p.enumerated().filter { $0.offset % 5 == k && ChartFit.inner($0.element.0) && ChartFit.inner($0.element.1) }.map(\.element)
                        let lut = LookCalibration.fitSmooth(train, size: ChartFit.size, lambda: ChartFit.lambda, iterations: ChartFit.iters)
                        return (LookCalibration.applyCPU(test.map(\.0), lut), test.map(\.1))
                    }
                }
                for await (a, b) in g { pIn += a; tIn += b }
            }
            let cvIn = dE(pIn, tIn)
            log(String(format: "      unclipped %d: table %.2f / %.2f", pIn.count, cvIn.mean, cvIn.p95))
            tables[look] = LookCalibration.fitSmooth(p, size: ChartFit.size, lambda: ChartFit.lambda, iterations: ChartFit.iters)
            log(String(format: "%@  %4d patches | untouched %.2f / %.2f | table %.2f / %.2f", look.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0), p.count, none.mean, none.p95, cv.mean, cv.p95))
        }

        if !scenes.isEmpty {
            Develop.lensCorrectionOff = true
            log("\nreal Imaging Edge scenes — ΔE mean: current tables → chart table")
            let data = await SonyFit.load(scenes, log: { _ in })
            for s in data {
                var line = "\(s.name) (\(s.model)):"
                for look in looks {
                    guard let sony = s.looks[look], let t = tables[look] else { continue }
                    let current: [SIMD3<Float>]
                    if look == .ST { current = s.base }
                    else if let rel = LookCalibration.table("\(look.rawValue).rel") { current = LookCalibration.applyCPU(s.base, rel) }
                    else { current = s.base }
                    let a = dE(current, sony).mean, b = dE(LookCalibration.applyCPU(s.base, t), sony).mean
                    line += String(format: "  %@ %.2f→%.2f", look.rawValue, a, b)
                }
                log(line)
            }
        }
        if save {
            for (look, t) in tables { try? LookCalibration.saveTable(t, name: "\(look.rawValue).chart") }
            log("\nsaved \(tables.count) chart tables to \(LookCalibration.dir.path)")
        }
    }

    // MARK: Deterministic "Sony" decode — RAW 7, no boost / tone map, scene-linear; table input encoding.

    nonisolated static let headroom: Float = 1.25

    nonisolated static func configureLinear(_ f: CIRAWFilter) {
        let v = CIRAWDecoderVersion(rawValue: "7")
        if f.supportedDecoderVersions.contains(v) { f.decoderVersion = v }
        f.boostAmount = 0; f.boostShadowAmount = 0; f.extendedDynamicRangeAmount = 2
        if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
        f.baselineExposure = 0
        f.isLensCorrectionEnabled = false
    }

    nonisolated static func srgbToLinear(_ v: Float) -> Float { let a = abs(v); let l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4); return v < 0 ? -l : l }
    nonisolated static func linearToSRGB(_ v: Float) -> Float { let a = max(0, v); return a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055 }

    /// Extended-sRGB-encoded decoder value → table coordinate (Rec.2020 primaries, gamma 2.2, headroom).
    nonisolated static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = SIMD3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
        let r = 0.6274 * l.x + 0.3293 * l.y + 0.0433 * l.z
        let g = 0.0691 * l.x + 0.9195 * l.y + 0.0114 * l.z
        let b = 0.0164 * l.x + 0.0880 * l.y + 0.8956 * l.z
        let e = { (x: Float) in min(1, pow(max(0, x) / headroom, 1 / 2.2)) }
        return SIMD3(e(r), e(g), e(b))
    }

    /// Scene render through the linear decode, resized to w×h, extended sRGB floats.
    nonisolated static func linearPixels(_ raw: URL, w: Int, h: Int) -> [SIMD3<Float>]? {
        guard let f = CIRAWFilter(imageURL: raw) else { return nil }
        configureLinear(f)
        let side = max(f.nativeSize.width, f.nativeSize.height)
        if side > 0 { f.scaleFactor = Float(min(1, Double(max(w, h) * 2) / side)) }
        guard var img = f.outputImage else { return nil }
        img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        var buf = [Float](repeating: 0, count: w * h * 4)
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        ctx.render(img, toBitmap: &buf, rowBytes: w * 16, bounds: CGRect(x: img.extent.minX, y: img.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        return (0..<(w * h)).map { SIMD3(buf[$0 * 4], buf[$0 * 4 + 1], buf[$0 * 4 + 2]) }
    }

    /// Fit + validate tables on the linear decode. Charts need samples-d7/apixa.json (RAW 7, linear) + Sony looks.
    @MainActor
    static func runLinear(chartDirs: [URL], scenes: [URL], save: Bool, log: (String) -> Void) async {
        let sdirs = chartDirs.map { $0.appendingPathComponent("samples-d7") }
        let looks = CreativeLook.allCases.filter { l in sdirs.allSatisfy { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(l.rawValue).json").path) } }
        var tables: [CreativeLook: Data] = [:]
        log("linear decode (RAW 7) — chart held-out ΔE mean / p95")
        for look in looks {
            var acc: [Pair] = []
            for d in sdirs {
                guard let a = loadSamples(d.appendingPathComponent("apixa.json")), let sony = loadSamples(d.appendingPathComponent("\(look.rawValue).json")) else { continue }
                for (x, y) in zip(a, sony) where x[3] < 0.01 && y[3] < 0.01 {
                    acc.append((encode(SIMD3(x[0], x[1], x[2])), SIMD3(y[0], y[1], y[2])))
                }
            }
            let p = acc
            var pred: [SIMD3<Float>] = [], truth: [SIMD3<Float>] = []
            await withTaskGroup(of: ([SIMD3<Float>], [SIMD3<Float>]).self) { g in
                for k in 0..<5 {
                    g.addTask {
                        let train = p.enumerated().filter { $0.offset % 5 != k }.map(\.element)
                        let test = p.enumerated().filter { $0.offset % 5 == k }.map(\.element)
                        let lut = LookCalibration.fitSmooth(train, size: ChartFit.size, lambda: ChartFit.lambda, iterations: ChartFit.iters)
                        return (LookCalibration.applyCPU(test.map(\.0), lut), test.map(\.1))
                    }
                }
                for await (a, b) in g { pred += a; truth += b }
            }
            if let dump = ProcessInfo.processInfo.environment["CHART_DUMP"], look.rawValue == (ProcessInfo.processInfo.environment["CHART_DUMP_LOOK"] ?? "ST") {
                // order of pred/truth follows fold order; recompute inputs in the same order
                var ins: [SIMD3<Float>] = []
                for k in 0..<5 { ins += p.enumerated().filter { $0.offset % 5 == k }.map(\.element.0) }
                _ = ins
                let rows = zip(pred, truth).map { [$0.0.x, $0.0.y, $0.0.z, $0.1.x, $0.1.y, $0.1.z].map(Double.init) }
                try? JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: dump))
            }
            let inner = zip(pred, truth).filter { ChartFit.inner($0.1) }
            let all = dE(pred, truth), ord = dE(inner.map(\.0), inner.map(\.1))
            tables[look] = LookCalibration.fitSmooth(p, size: ChartFit.size, lambda: ChartFit.lambda, iterations: ChartFit.iters)
            log(String(format: "%@ %4d patches | all %.2f / %.2f | unclipped (%d) %.2f / %.2f", look.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0), p.count, all.mean, all.p95, inner.count, ord.mean, ord.p95))
        }
        if !scenes.isEmpty {
            Develop.lensCorrectionOff = true
            log("\nreal Imaging Edge scenes — ΔE mean: current (RAW 9 + tables) → linear RAW 7 + chart table")
            let data = await SonyFit.load(scenes, log: { _ in })
            for s in data {
                guard let px = linearPixels(s.raw, w: s.w, h: s.h) else { continue }
                let enc = px.map(encode)
                var line = "\(s.name) (\(s.model)):"
                for look in looks {
                    guard let sony = s.looks[look], let t = tables[look] else { continue }
                    let current: [SIMD3<Float>]
                    if look != .ST, let rel = LookCalibration.table("\(look.rawValue).rel") { current = LookCalibration.applyCPU(s.base, rel) } else { current = s.base }
                    let mine = LookCalibration.applyCPU(enc, t)
                    let fl = s.flat
                    line += String(format: "  %@ %.2f→%.2f (flat %.2f→%.2f)", look.rawValue, dE(current, sony).mean, dE(mine, sony).mean,
                                   dE(fl.map { current[$0] }, fl.map { sony[$0] }).mean, dE(fl.map { mine[$0] }, fl.map { sony[$0] }).mean)
                }
                if let sony = s.looks[.ST], let t = tables[.ST] {
                    let mine = LookCalibration.applyCPU(enc, t)
                    var bias = SIMD3<Float>(0, 0, 0)
                    var bins = [Int: (SIMD3<Float>, Int)]()
                    for i in s.flat { let a = LookCalibration.lab(mine[i]), b = LookCalibration.lab(sony[i]); bias += a - b
                        let k = min(4, Int(b.x / 20)); var e = bins[k] ?? (.zero, 0); e.0 += a - b; e.1 += 1; bins[k] = e }
                    bias /= Float(max(1, s.flat.count))
                    line += String(format: "\n      ST flat bias L %+.2f a %+.2f b %+.2f |", bias.x, bias.y, bias.z)
                    for k in bins.keys.sorted() { let e = bins[k]!; let m = e.0 / Float(e.1); line += String(format: " L%d-%d(%d): %+.1f %+.1f %+.1f", k * 20, k * 20 + 20, e.1, m.x, m.y, m.z) }
                }
                log(line)
            }
        }
        if save {
            for (look, t) in tables { try? LookCalibration.saveTable(t, name: "\(look.rawValue).lin") }
            log("\nsaved \(tables.count) linear tables")
        }
    }

    // MARK: RAW 9 — chart + scene tables, leave-one-scene-out

    /// Flat-pixel pairs (Apixa neutral → Sony look) from a scene, at most `cap`.
    nonisolated static func scenePairs(_ s: SonyFit.SceneData, _ look: CreativeLook, cap: Int = 6000) -> [Pair] {
        guard let sony = s.looks[look] else { return [] }
        let step = max(1, s.flat.count / cap)
        return stride(from: 0, to: s.flat.count, by: step).map { (s.base[s.flat[$0]], sony[s.flat[$0]]) }
    }

    struct Mixed: Sendable { var scene: String; var look: CreativeLook; var current: Double; var chart: Double; var scenes: Double; var mixed: Double; var currentLOO: Double = .nan; var chartSTrel: Double = .nan }

    @MainActor
    static func runMixed(chartDirs: [URL], scenes: [URL], log: (String) -> Void) async -> (data: [SonyFit.SceneData], rows: [Mixed], chartPairs: [CreativeLook: [Pair]]) {
        let sdirs = chartDirs.map { $0.appendingPathComponent("samples") }
        var chart: [CreativeLook: [Pair]] = [:]
        for look in CreativeLook.allCases {
            for d in sdirs {
                guard let a = loadSamples(d.appendingPathComponent("apixa.json")), let y = loadSamples(d.appendingPathComponent("\(look.rawValue).json")) else { continue }
                chart[look, default: []] += pairs(a, y)
            }
        }
        let data = await SonyFit.load(scenes, log: { _ in })
        let chartC = chart
        let chartST = chart[.ST].map { LookCalibration.fitSmooth($0, size: 33, lambda: 0.05, iterations: 400) }
        var rows: [Mixed] = []
        await withTaskGroup(of: Mixed?.self) { g in
            for (k, s) in data.enumerated() {
                for look in CreativeLook.allCases where s.looks[look] != nil {
                    let others = data.enumerated().filter { $0.offset != k }.map(\.element)
                    let rel = look == .ST ? nil : LookCalibration.table("\(look.rawValue).rel")
                    g.addTask {
                        let sony = s.looks[look]!
                        let current = rel.map { LookCalibration.applyCPU(s.base, $0) } ?? s.base
                        let sp = others.flatMap { scenePairs($0, look) }
                        let cp = chartC[look] ?? []
                        func score(_ p: [Pair]) -> Double {
                            guard !p.isEmpty else { return .nan }
                            return dE(LookCalibration.applyCPU(s.base, LookCalibration.fitSmooth(p, size: 33, lambda: 0.05, iterations: 400)), sony).mean
                        }
                        // The installed method, retrained without this scene: Sony ST → look from the other scenes, on Apixa's render.
                        var loo = Double.nan, hyb = Double.nan
                        if look == .ST {
                            loo = dE(s.base, sony).mean
                            if let c = chartST { hyb = dE(LookCalibration.applyCPU(s.base, c), sony).mean }
                        } else {
                            let rp = others.flatMap { o -> [Pair] in let a = SonyFit.relPairs(o, look); let st = max(1, a.count / 40000); return stride(from: 0, to: a.count, by: st).map { a[$0] } }
                            if !rp.isEmpty {
                                let t = LookCalibration.fitSmooth(rp)
                                loo = dE(LookCalibration.applyCPU(s.base, t), sony).mean
                                if let c = chartST { hyb = dE(LookCalibration.applyCPU(LookCalibration.applyCPU(s.base, c), t), sony).mean }
                            }
                        }
                        return Mixed(scene: s.name, look: look, current: dE(current, sony).mean, chart: score(cp), scenes: score(sp), mixed: score(cp + sp), currentLOO: loo, chartSTrel: hyb)
                    }
                }
            }
            for await r in g { if let r { rows.append(r) } }
        }
        rows.sort { ($0.scene, CreativeLook.allCases.firstIndex(of: $0.look)!) < ($1.scene, CreativeLook.allCases.firstIndex(of: $1.look)!) }
        log("scene look | installed (in-sample) | installed method, scene left out | chart only | chart ST + look tables (left out) | other scenes | chart + other scenes")
        for r in rows { log(String(format: "%@ %@ | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f", r.scene, r.look.rawValue, r.current, r.currentLOO, r.chart, r.chartSTrel, r.scenes, r.mixed)) }
        let names = ["installed", "installed-LOO", "chart", "chartST+rel-LOO", "scenes", "mixed"]
        for col in 0..<6 {
            let v = rows.map { [$0.current, $0.currentLOO, $0.chart, $0.chartSTrel, $0.scenes, $0.mixed][col] }.filter { !$0.isNaN }
            log(String(format: "mean %@: %.2f", names[col], v.reduce(0, +) / Double(max(1, v.count))))
        }
        return (data, rows, chart)
    }
}
