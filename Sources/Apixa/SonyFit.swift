import Foundation
import CoreImage
import ImageIO

/// Learns looks from Sony's own renders of a RAW (Imaging Edge exports: NAME.ARW + NAME-<LOOK>.tif).
///
/// Two colour tables, because Sony's Standard and Sony's look are the same pixels:
/// - "base": Apixa's neutral RAW render → Sony Standard, per camera model.
/// - "rel":  Sony Standard → Sony look, per look (camera-independent, pixel-exact pairs).
enum SonyFit {
    struct SceneData {
        let raw: URL
        let name: String, model: String, w: Int, h: Int
        let base: [SIMD3<Float>]                 // Apixa neutral render
        var looks: [CreativeLook: [SIMD3<Float>]]  // Sony renders
        var flat: [Int]                          // non-edge pixel indices (for base pairs)
    }

    @MainActor
    static func load(_ folders: [URL], side: Int = 600, log: (String) -> Void) async -> [SceneData] {
        var out: [SceneData] = []
        for (raw, refs) in SelfTest.sonyReferences(in: folders) {
            guard let stURL = refs[.ST], let st = LookFit.load(stURL, maxPixel: side) else { continue }
            let w = st.width, h = st.height
            let model = (CGImageSourceCreateWithURL(raw as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })?["{TIFF}"]
                .flatMap { ($0 as? [String: Any])?["Model"] as? String } ?? "Sony"
            guard let b = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: side * 2, draft: false) else { continue }
            let base = LookCalibration.pixels(b, w: w, h: h)
            var looks: [CreativeLook: [SIMD3<Float>]] = [.ST: LookCalibration.pixels(st, w: w, h: h)]
            for (l, u) in refs where l != .ST {
                if let img = LookFit.load(u, maxPixel: side) { looks[l] = LookCalibration.pixels(img, w: w, h: h) }
            }
            var flat: [Int] = []
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                let dx: SIMD3<Float> = base[i + 1] - base[i - 1], dy: SIMD3<Float> = base[i + w] - base[i - w]
                if max(abs(dx.x), abs(dx.y), abs(dx.z)) + max(abs(dy.x), abs(dy.y), abs(dy.z)) < 0.12 { flat.append(i) }
            } }
            out.append(SceneData(raw: raw, name: raw.deletingPathExtension().lastPathComponent, model: model, w: w, h: h, base: base, looks: looks, flat: flat))
            log("loaded \(raw.lastPathComponent) (\(model)), \(looks.count) looks")
        }
        return out
    }

    static func relPairs(_ s: SceneData, _ look: CreativeLook) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard let st = s.looks[.ST], let t = s.looks[look] else { return [] }
        return Array(zip(st, t))
    }

    static func basePairs(_ s: SceneData) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard let st = s.looks[.ST] else { return [] }
        return s.flat.map { (s.base[$0], st[$0]) }
    }

    /// The camera-rendered preview embedded in a RAW file.
    static func embeddedPreview(_ raw: URL, maxPixel: Int) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(raw as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary)
    }

    /// Experiment: does the RAW's embedded camera preview match Imaging Edge, and how far does a
    /// per-photo correction (learned only from that preview) close the gap to Sony's renders?
    @MainActor
    static func matchTest(_ folders: [URL]) async {
        LookCalibration.bypass = true
        let scenes = await load(folders) { _ in }
        for s in scenes {
            print("== \(s.name) (\(s.model))  camera look tag: \(LookCalibration.cameraLook(s.raw)?.rawValue ?? "?")")
            guard let p = embeddedPreview(s.raw, maxPixel: 1600) else { print("  no embedded preview"); continue }
            let prev = LookCalibration.pixels(p, w: s.w, h: s.h)
            print("  preview \(p.width)x\(p.height); ΔE to each Sony render: " + CreativeLook.allCases.compactMap { l in
                s.looks[l].map { px in String(format: "%@ %.1f", l.rawValue, LookCalibration.deltaE(s.flat.map { i in prev[i] }, s.flat.map { i in px[i] })) } }.joined(separator: "  "))
            let st = s.looks[.ST]!
            let b = s.flat.map { s.base[$0] }, t = s.flat.map { st[$0] }
            print(String(format: "  base→Sony ST now %.2f", LookCalibration.deltaE(b, t)))
            for n in [2, 3, 5, 9, 17] {
                let lut = LookCalibration.fitSmooth(Array(zip(b, t)), size: n)
                print(String(format: "  fit on Sony ST itself (ceiling), table %d: %.2f", n, LookCalibration.deltaE(LookCalibration.applyCPU(b, lut), t)))
            }
            let pv = s.flat.map { prev[$0] }
            for n in [2, 3, 5, 9, 17] {
                let lut = LookCalibration.fitSmooth(Array(zip(b, pv)), size: n)
                print(String(format: "  fit on embedded preview, table %d: vs Sony ST %.2f", n, LookCalibration.deltaE(LookCalibration.applyCPU(b, lut), t)))
            }
        }
    }

    /// Does a Standard correction (RAW → Sony Standard table) bring Apixa closer to Sony's renders?
    @MainActor
    static func baseCheck(_ lutURL: URL, _ folders: [URL]) async {
        guard let lut = try? Data(contentsOf: lutURL) else { print("no table at \(lutURL.path)"); return }
        let scenes = await load(folders) { _ in }
        for s in scenes {
            let corrected = LookCalibration.applyCPU(s.base, lut)
            var line = "\(s.name) (\(s.model)):"
            for look in CreativeLook.allCases {
                guard let t = s.looks[look] else { continue }
                let rel = look == .ST ? nil : LookCalibration.table("\(look.rawValue).rel")
                func score(_ px: [SIMD3<Float>]) -> Double {
                    let out = rel.map { LookCalibration.applyCPU(px, $0) } ?? px
                    return LookCalibration.deltaE(s.flat.map { out[$0] }, s.flat.map { t[$0] })
                }
                line += String(format: "  %@ %.1f→%.1f", look.rawValue, score(s.base), score(corrected))
            }
            print(line)
        }
    }

    /// Measures (leave-one-scene-out) and optionally saves the tables.
    @MainActor
    static func run(_ folders: [URL], save: Bool, log: (String) -> Void) async -> [String] {
        LookCalibration.bypass = true
        defer { LookCalibration.bypass = false }
        let scenes = await load(folders, log: log)
        guard !scenes.isEmpty else { return [] }
        var report: [String] = ["Look itself (Sony Standard → Sony look), ΔE on a scene left out of the fit:"]
        for look in CreativeLook.allCases where look != .ST {
            let have = scenes.filter { $0.looks[look] != nil }
            guard !have.isEmpty else { continue }
            var loo = 0.0, n = 0.0, worst = 0.0
            if have.count >= 2 {
                for k in have.indices {
                    let lut = LookCalibration.fitSmooth(have.enumerated().filter { $0.offset != k }.flatMap { relPairs($0.element, look) })
                    let e = LookCalibration.deltaE(LookCalibration.applyCPU(have[k].looks[.ST]!, lut), have[k].looks[look]!)
                    loo += e; n += 1; worst = max(worst, e)
                }
            }
            let all = LookCalibration.fitSmooth(have.flatMap { relPairs($0, look) })
            let fitE = have.map { LookCalibration.deltaE(LookCalibration.applyCPU($0.looks[.ST]!, all), $0.looks[look]!) }.reduce(0, +) / Double(have.count)
            let line = String(format: "  %-4@ %d scenes | left-out %.2f (worst %.2f) | on its own scenes %.2f", look.rawValue as NSString, have.count, n > 0 ? loo / n : .nan, worst, fitE)
            report.append(line); log(line)
            if save { try? LookCalibration.saveTable(all, name: "\(look.rawValue).rel") }
        }
        report.append("RAW → Sony Standard, per camera:")
        for model in Set(scenes.map(\.model)).sorted() {
            let mine = scenes.filter { $0.model == model }
            let before = mine.map { s in LookCalibration.deltaE(s.flat.map { s.base[$0] }, s.flat.map { s.looks[.ST]![$0] }) }.reduce(0, +) / Double(mine.count)
            var loo = Double.nan
            if mine.count >= 2 {
                loo = 0
                for k in mine.indices {
                    let lut = LookCalibration.fitSmooth(mine.enumerated().filter { $0.offset != k }.flatMap { basePairs($0.element) })
                    let s = mine[k]
                    loo += LookCalibration.deltaE(LookCalibration.applyCPU(s.flat.map { s.base[$0] }, lut), s.flat.map { s.looks[.ST]![$0] })
                }
                loo /= Double(mine.count)
            }
            if mine.count >= 2, CommandLine.arguments.contains("--variants") {
                for (size, lam) in [(2, 0.5), (3, 0.5), (5, 0.5), (9, 0.5), (9, 20.0), (17, 20.0), (33, 200.0)] {
                    var e = 0.0
                    for k in mine.indices {
                        let lut = LookCalibration.fitSmooth(mine.enumerated().filter { $0.offset != k }.flatMap { basePairs($0.element) }, size: size, lambda: lam)
                        let s = mine[k]
                        e += LookCalibration.deltaE(LookCalibration.applyCPU(s.flat.map { s.base[$0] }, lut), s.flat.map { s.looks[.ST]![$0] })
                    }
                    log(String(format: "    base variant size %d λ %.1f: left-out %.2f", size, lam, e / Double(mine.count)))
                }
                for s in mine {
                    let a = LookCalibration.stats(s.flat.map { s.base[$0] }), b = LookCalibration.stats(s.flat.map { s.looks[.ST]![$0] })
                    log(String(format: "    %@: Apixa−Sony  ΔL %+.1f  Δcontrast %+.1f  Δchroma %+.1f  Δwarmth %+.1f", s.name, a.L - b.L, a.contrast - b.contrast, a.chroma - b.chroma, a.warmth - b.warmth))
                }
            }
            let all = LookCalibration.fitSmooth(mine.flatMap(basePairs))
            let own = mine.map { s in LookCalibration.deltaE(LookCalibration.applyCPU(s.flat.map { s.base[$0] }, all), s.flat.map { s.looks[.ST]![$0] }) }.reduce(0, +) / Double(mine.count)
            let line = String(format: "  %@: %d scenes | now %.2f | left-out %.2f | on its own scenes %.2f", model, mine.count, before, loo, own)
            report.append(line); log(line)
            // Not saved: this correction changes from scene to scene, so a fixed table makes new photos worse.
        }
        return report
    }
}
