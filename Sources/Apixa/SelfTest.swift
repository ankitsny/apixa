import Foundation
import SwiftUI
import AppKit
import ImageIO
import CoreImage

/// `Apixa --selftest <folder> [--accurate]` — headless pipeline check (scan → analyze → stack → score),
/// prints a summary and exits. Used for verification without the UI.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments

        if let i = args.firstIndex(of: "--developtest"), i + 2 < args.count {
            return developTest(URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--stackdump"), i + 2 < args.count {
            return stackDump(URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--lookcompare"), i + 2 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            let folders = args[(i + 2)...].filter { !$0.hasPrefix("--") && CreativeLook(rawValue: $0) == nil }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                // Results also go to stdout; progress streams live on stderr and to <out>/lookcompare.log.
                setvbuf(stdout, nil, _IOLBF, 0)
                for line in await lookCompare(folders, out: out, save: !args.contains("--dry")) { print(line) }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--lookfit"), i + 1 < args.count {
            // Fit each look's parameters to Sony's renders: NAME-ST.tif → NAME-<LOOK>.tif.
            let folders = args[(i + 1)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            LookCalibration.bypass = true
            var fitted: [String: [Double]] = [:]
            let sets = sonyReferences(in: folders)
            print("\(sets.count) reference scenes: " + sets.map { $0.raw.lastPathComponent }.joined(separator: ", "))
            print("look scenes | ΔE all: built-in → fit | left-out scene: built-in → fit | parameters")
            for look in CreativeLook.allCases where look != .ST {
                let scenes: [LookFit.Scene] = sets.compactMap { set in
                    guard let s = set.refs[.ST].flatMap({ LookFit.load($0, maxPixel: 360) }),
                          let t = set.refs[look].flatMap({ LookFit.load($0, maxPixel: 360) }) else { return nil }
                    return LookFit.Scene(st: s, target: t)
                }
                guard !scenes.isEmpty else { continue }
                let r = LookFit.fit(look: look, scenes: scenes)
                fitted[look.rawValue] = LookFit.vector(r.params)
                let v = LookFit.vector(r.params).map { String(format: "%.3f", $0) }
                print(String(format: "%-4@ %d | %5.2f → %5.2f | %5.2f → %5.2f | ", look.rawValue as NSString, scenes.count, r.eStart, r.eFit, r.eTestStart, r.eTestFit)
                      + zip(LookFit.names, v).map { "\($0)=\($1)" }.joined(separator: " "))
            }
            let u = URL(fileURLWithPath: CommandLine.arguments.contains("--json") ? CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--json")! + 1] : NSTemporaryDirectory() + "apixa-lookfit.json")
            try? JSONEncoder().encode(fitted).write(to: u); print("wrote \(u.path)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--measuretest"), i + 1 < args.count {
            // Scores of a RAW before and after a sample edit (what the Rate tab's "Edited version" shows).
            let raw = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                var e = Adjustments(); e.exposure = 1.2; e.sharpening = 0.6
                for (name, adj) in [("original", Adjustments()), ("edited (+1.2 EV, sharpen)", e)] {
                    let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: adj, maxPixel: 1600, draft: false)
                    if let m = await Analyzer.measure(ImageBox(image: img)) {
                        print(String(format: "%@: sharp %.2f exposure %.2f mean %.2f hi %.3f lo %.3f face %@ aes %@", name, m.sharpness, m.exposure, m.mean, m.highClip, m.shadowClip,
                                     m.face.map { String(format: "%.2f", $0) } ?? "-", m.aesthetic.map { String(format: "%.2f", $0) } ?? "-"))
                    }
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--scopetest"), i + 2 < args.count {
            // Draw the three scopes for an image file to PNGs (no window needed).
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary),
                  let sc = Scopes.compute(cg) else { print("cannot read image"); exit(1) }
            for kind in ScopeKind.allCases {
                let r = ImageRenderer(content: ScopesView(scopes: sc, kind: kind).frame(width: 330, height: kind == .vectorscope ? 330 : 240).environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.cgImage {
                    let u = URL(fileURLWithPath: args[i + 2]).appendingPathComponent("scope-\(kind.rawValue).png")
                    if let d = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                    print("wrote \(u.lastPathComponent)")
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--autoundo"), i + 1 < args.count {
            // Auto on → undo → redo → manual change → Auto off, checked through the store like the UI does.
            Task { @MainActor in
                let store = LibraryStore()
                store.load(URL(fileURLWithPath: args[i + 1]))
                while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
                guard let a = store.assets.first else { print("no shots"); exit(1) }
                let saved = a.adjustments
                a.adjustments = Adjustments(); a.adjustments.contrast = 0.3
                await store.toggleAuto(a, usesRaw: false)
                print("after auto: on=\(a.adjustments.isAutoOn) contrast=\(a.adjustments.contrast) shadows=\(a.adjustments.shadows) undoTitle=\(store.undoTitle ?? "nil")")
                store.undo()
                print("after undo: on=\(a.adjustments.isAutoOn) contrast=\(a.adjustments.contrast) auto=\(a.adjustments.auto == nil ? "nil" : "set")")
                store.redo()
                a.adjustments.exposure = 0.5
                print("after manual change: on=\(a.adjustments.isAutoOn)")
                a.adjustments.exposure = 0
                await store.toggleAuto(a, usesRaw: false)
                print("after auto off: on=\(a.adjustments.isAutoOn) contrast=\(a.adjustments.contrast) auto=\(a.adjustments.auto == nil ? "nil" : "set")")
                a.adjustments = saved
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--autotest"), i + 2 < args.count {
            // Auto-enhance values for a RAW, and the Apple filters rendered on it (written to <out>).
            let raw = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            Task { @MainActor in
                if let a = await Develop.autoAdjust(raw: raw, jpeg: nil, useRaw: true, current: Adjustments()) {
                    print(String(format: "auto: shadows %+.2f highlights %+.2f vibrance %+.2f curve ", a.shadows, a.highlights, a.vibrance)
                          + a.curves.master.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined(separator: " "))
                    if let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 700, draft: true) { save(img, out.appendingPathComponent("auto.jpg")) }
                } else { print("auto: nil") }
                if let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: 700, draft: true) { save(img, out.appendingPathComponent("plain.jpg")) }
                for r in LookRecipe.appleFilters {
                    var a = Adjustments(); a.look = r
                    if let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 700, draft: true) {
                        save(img, out.appendingPathComponent("apple-\(r.name).jpg")); print("rendered \(r.name)")
                    }
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--auditdump"), i + 2 < args.count {
            return auditDump(URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--basecheck"), i + 2 < args.count {
            let folders = args[(i + 2)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in setvbuf(stdout, nil, _IOLBF, 0); await SonyFit.baseCheck(URL(fileURLWithPath: args[i + 1]), folders); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--matchtest"), i + 1 < args.count {
            let folders = args[(i + 1)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in setvbuf(stdout, nil, _IOLBF, 0); await SonyFit.matchTest(folders); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--sonyfit"), i + 1 < args.count {
            let folders = args[(i + 1)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                setvbuf(stdout, nil, _IOLBF, 0)
                _ = await SonyFit.run(folders, save: args.contains("--save")) { print($0) }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--refexport"), i + 2 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            let folders = args[(i + 2)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                await refExport(folders, out: out)
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--camfit"), i + 3 < args.count {
            // Fit look parameters to the camera's own JPEGs; score built-in / Sony-fitted / camera-fitted on held-out shots.
            let sony = (try? JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))) ?? [:]
            let outJSON = URL(fileURLWithPath: args[i + 2])
            let folders = args[(i + 3)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                setvbuf(stdout, nil, _IOLBF, 0)
                await camFit(sony: sony, out: outJSON, folders: folders)
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--handcheck"), i + 2 < args.count {
            // Built-in look parameters vs fitted ones (JSON from --lookfit), scored on camera JPEGs.
            let fitted = (try? JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))) ?? [:]
            let folders = args[(i + 2)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                setvbuf(stdout, nil, _IOLBF, 0)
                await handCheck(fitted: fitted, folders: folders)
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--refcompare"), i + 2 < args.count {
            // Sony-rendered references next to a RAW: NAME.ARW + NAME-<LOOK>.tif/jpg (e.g. from Imaging Edge).
            let out = URL(fileURLWithPath: args[i + 1])
            let folders = args[(i + 2)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                setvbuf(stdout, nil, _IOLBF, 0)
                for line in await refCompare(folders, out: out) { print(line) }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--nrtest"), i + 1 < args.count {
            let raw = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                @MainActor func noise(_ a: Adjustments) async -> (Double, Double) {
                    guard let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: a, maxPixel: nil, draft: false),
                          let crop = img.cropping(to: CGRect(x: img.width / 2 - 300, y: img.height / 2 - 300, width: 600, height: 600)) else { return (.nan, .nan) }
                    if a.colorNoise > 0 && a.strongNoise == 0 {
                        save(crop, URL(fileURLWithPath: CommandLine.arguments.last!).appendingPathComponent("nr-colour.png"))
                    }
                    if a == Adjustments() { save(crop, URL(fileURLWithPath: CommandLine.arguments.last!).appendingPathComponent("nr-none.png")) }
                    let w = 600, h = 600; var px = [UInt8](repeating: 0, count: w * h * 4)
                    let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    c.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
                    // Laplacian std of luma (grain) and of R−G (colour speckle).
                    func lapStd(_ v: (Int) -> Double) -> Double {
                        var s = 0.0, s2 = 0.0, n = 0.0
                        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                            let i = y * w + x
                            let l = 4 * v(i) - v(i - 1) - v(i + 1) - v(i - w) - v(i + w)
                            s += l; s2 += l * l; n += 1 } }
                        return (s2 / n - (s / n) * (s / n)).squareRoot()
                    }
                    let luma: (Int) -> Double = { 0.2126 * Double(px[$0 * 4]) + 0.7152 * Double(px[$0 * 4 + 1]) + 0.0722 * Double(px[$0 * 4 + 2]) }
                    // Proper colour-difference channels (BT.709 Cb/Cr), so brightness edges don't count as colour noise.
                    let cr: (Int) -> Double = { Double(px[$0 * 4]) - luma($0) }
                    let cb: (Int) -> Double = { Double(px[$0 * 4 + 2]) - luma($0) }
                    return (lapStd(luma), (lapStd(cr) + lapStd(cb)) / 2)
                }
                var cases: [(String, Adjustments)] = [("none", Adjustments())]
                var a = Adjustments(); a.noiseReduction = 1; cases.append(("Noise reduction 100%", a))
                a = Adjustments(); a.strongNoise = 0.5; cases.append(("Strong NR 50%", a))
                a = Adjustments(); a.strongNoise = 1; cases.append(("Strong NR 100%", a))
                a = Adjustments(); a.colorNoise = 1; cases.append(("Colour noise 100%", a))
                a = Adjustments(); a.noiseReduction = 1; a.strongNoise = 1; a.colorNoise = 1; cases.append(("all three at 100%", a))
                for (n, adj) in cases {
                    let r = await noise(adj)
                    print(String(format: "%-22@ grain %5.2f   colour speckle %5.2f", n as NSString, r.0, r.1))
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--darktest"), i + 1 < args.count {
            let raw = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                func luma(_ a: Adjustments) async -> (Double, Double) {
                    guard let img = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 400, draft: false) else { return (.nan, .nan) }
                    let w = 64, h = 64; var px = [UInt8](repeating: 0, count: w * h * 4)
                    let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                    var y = 0.0, rb = 0.0
                    for k in 0..<(w * h) {
                        let r = Double(px[k * 4]), g = Double(px[k * 4 + 1]), b = Double(px[k * 4 + 2])
                        y += 0.2126 * r + 0.7152 * g + 0.0722 * b; rb += r - b
                    }
                    return (y / Double(w * h), rb / Double(w * h))
                }
                let base = await luma(Adjustments())
                print(String(format: "%-26@ luma %5.1f  R-B %5.1f", "no look" as NSString, base.0, base.1))
                for l in LookRecipe.builtIn + MyLooksStore.load().filter({ $0.group == "More Recipes" }) {
                    var a = Adjustments(); a.look = l
                    let m = await luma(a)
                    print(String(format: "%-26@ luma %5.1f (%+5.1f)  R-B %5.1f (%+5.1f)", l.name as NSString, m.0, m.0 - base.0, m.1, m.1 - base.1))
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--importlooks"), i + 2 < args.count {
            // Parse a recipe text file into the user's My Looks (dry run with --dry).
            let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
            let looks = RecipeParser.parse(text, group: args[i + 2])
            for r in looks { print("\(r.name) → \(r.settingsLine)") }
            if !args.contains("--dry") {
                var mine = MyLooksStore.load()
                mine.removeAll { m in looks.contains { $0.id == m.id } }
                MyLooksStore.save(mine + looks)
                print("saved \(looks.count) → \(MyLooksStore.url.path)")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--looktest"), i + 3 < args.count {
            return lookTest(raw: URL(fileURLWithPath: args[i + 1]), jpeg: URL(fileURLWithPath: args[i + 2]), out: URL(fileURLWithPath: args[i + 3]))
        }
        if let i = args.firstIndex(of: "--facedump"), i + 2 < args.count {
            return faceDump(URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--perftest"), i + 2 < args.count {
            return perfTest(URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--metatest"), i + 1 < args.count {
            return metaTest(URL(fileURLWithPath: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--statetest"), i + 1 < args.count {
            return stateTest(URL(fileURLWithPath: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--trashtest"), i + 1 < args.count {
            return trashTest(URL(fileURLWithPath: args[i + 1]))
        }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let accurate = args.contains("--accurate")
        Task { @MainActor in
            let t0 = Date()
            let store = LibraryStore()
            store.accurateRaw = accurate
            store.load(url)
            while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            let secs = Date().timeIntervalSince(t0)
            let a = store.assets
            print("shots=\(a.count) pairs=\(a.filter(\.isPair).count) rawOnly=\(a.filter(\.isRawOnly).count) analyzed=\(a.filter(\.analyzed).count) secs=\(String(format: "%.1f", secs))")
            print("stacks(>1)=\(store.stacks.filter { $0.members.count > 1 }.count) groups=\(store.stacks.count) largest=\(store.stacks.map(\.members.count).max() ?? 0)")
            var hist = [Int](repeating: 0, count: 6)
            for x in a { hist[x.stars] += 1 }
            print("status: \(store.statusMessage ?? "")")
            print("stars 1..5:", hist[1...].map(String.init).joined(separator: " "), " faces=\(a.filter { $0.faceQuality != nil }.count) aesthetics=\(a.filter { $0.aesthetic != nil }.count) source=\(Set(a.map(\.metricsSource.rawValue)))")
            for s in (store.stacks.count < 10 ? store.stacks : store.stacks.filter({ $0.members.count > 1 })).prefix(6) {
                print("  stack:", s.members.map { "\($0.baseName)\($0.isBest ? "👑" : "")[\($0.stars)★ s=\(String(format: "%.2f", $0.sharpnessScore)) e=\(String(format: "%.2f", $0.exposureScore)) clip=\(String(format: "%.3f", $0.highlightClip))]" }.joined(separator: " "))
            }
            exit(0)
        }
    }

    /// Renders the first shot of a folder: JPEG, RAW (RAW 9), embedded preview, and an edited RAW export.
    static func developTest(_ folder: URL, out: URL) {
        Task { @MainActor in
            guard let item = FolderScanner.scan(folder).first else { print("no shots"); exit(1) }
            var edit = Adjustments()
            edit.exposure = 0.7; edit.shadows = 0.5; edit.highlights = 0.6; edit.temperature = 800
            edit.noiseReduction = 0.5; edit.whites = -0.3; edit.blacks = 0.2; edit.vibrance = 0.3
            edit.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1)]
            edit.curves.blue = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 0.95)]
            func save(_ name: String, _ cg: CGImage?) {
                guard let cg else { print("\(name): nil"); return }
                let u = out.appendingPathComponent(name + ".jpg")
                let d = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil)!
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
                print("\(name): \(cg.width)x\(cg.height)")
            }
            var t = Date()
            save("jpeg", await Develop.render(raw: item.raw, jpeg: item.jpeg, useRaw: false, adjustments: .init(), maxPixel: 1200, draft: false))
            if let raw = item.raw {
                print("decoder:", RAWDecoder.label(for: raw))
                save("embedded", Analyzer.loadImage(raw, maxPixel: 1200, isRaw: true))
                t = Date()
                save("raw9", await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: .init(), maxPixel: 1200, draft: false))
                print("raw9 render ms:", Int(Date().timeIntervalSince(t) * 1000))
                t = Date()
                save("raw9-draft-edited", await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: edit, maxPixel: 1400, draft: true))
                print("draft edit render ms:", Int(Date().timeIntervalSince(t) * 1000))
            }
            if let cg = Analyzer.loadImage(item.jpeg ?? item.raw!, maxPixel: 1200, isRaw: item.jpeg == nil), let sc = Scopes.compute(cg) {
                let peak = sc.luma.firstIndex(of: sc.luma.max() ?? 0) ?? -1
                print("scopes: lumaPeakBin=\(peak) clipHi=\(String(format: "%.3f", sc.clippedHighlights)) clipLo=\(String(format: "%.3f", sc.clippedShadows)) waveform=\(sc.waveform.map { "\($0.width)x\($0.height)" } ?? "nil") vectorscope=\(sc.vectorscope.map { "\($0.width)x\($0.height)" } ?? "nil")")
                for (name, img) in [("waveform", sc.waveform), ("vectorscope", sc.vectorscope)] { save(name, img) }
            }
            save("jpeg-edited", await Develop.render(raw: nil, jpeg: item.jpeg, useRaw: false, adjustments: edit, maxPixel: 1200, draft: false))
            t = Date()
            let exp = out.appendingPathComponent("export-full.jpg")
            try? FileManager.default.removeItem(at: exp)
            do {
                let loc = GeoPoint(latitude: 13.3409, longitude: 74.7421, altitude: 12)
                try await Develop.saveCopy(raw: item.raw, jpeg: item.jpeg, useRaw: item.raw != nil, adjustments: edit,
                                           location: loc, rating: 4, options: .init(), to: exp)
                do {
                    try await Develop.saveCopy(raw: item.raw, jpeg: item.jpeg, useRaw: false, adjustments: edit,
                                               location: nil, options: .init(), to: exp)
                    print("OVERWRITE NOT BLOCKED")
                } catch { print("overwrite refused: ok") }
                let src = CGImageSourceCreateWithURL(exp as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
                let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
                print("export: \(props[kCGImagePropertyPixelWidth]!)x\(props[kCGImagePropertyPixelHeight]!) date=\(exif?[kCGImagePropertyExifDateTimeOriginal] ?? "none") gps=\(gps?[kCGImagePropertyGPSLatitude] ?? "none")\(gps?[kCGImagePropertyGPSLatitudeRef] ?? "") rating=\(iptc?[kCGImagePropertyIPTCStarRating] ?? "none") ms=\(Int(Date().timeIntervalSince(t) * 1000))")
            } catch { print("export failed:", error) }
            exit(0)
        }
    }

    /// Rejects the first two shots, trashes them, undoes (files must come back), redoes, undoes again.
    static func trashTest(_ folder: URL) {
        Task { @MainActor in
            let store = LibraryStore()
            store.load(folder)
            while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            let victims = Array(store.assets.prefix(2))
            let files = victims.flatMap(\.allURLs)
            let fm = FileManager.default
            func present() -> Int { files.filter { fm.fileExists(atPath: $0.path) }.count }
            for v in victims { store.setDecision(v, .reject) }
            print("files=\(files.count) present=\(present()) undo=\(store.undoTitle ?? "-")")
            store.trashRejects()
            print("after trash: present=\(present()) assets=\(store.assets.count) undo=\(store.undoTitle ?? "-") | \(store.statusMessage ?? "")")
            store.undo()
            print("after undo:  present=\(present()) assets=\(store.assets.count) redo=\(store.redoTitle ?? "-") | \(store.statusMessage ?? "")")
            store.redo()
            print("after redo:  present=\(present()) assets=\(store.assets.count)")
            store.undo()
            store.undo(); store.undo()   // undo the two rejects
            print("final: present=\(present()) assets=\(store.assets.count) decisions=\(victims.map(\.decision.rawValue))")
            exit(0)
        }
    }

    /// Sets a mark, rating, location and edit; reloads the folder; checks they came back from the library.
    static func stateTest(_ folder: URL) {
        Task { @MainActor in
            @MainActor func open() async -> LibraryStore {
                let s = LibraryStore()
                s.load(folder)
                while s.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
                return s
            }
            let s1 = await open()
            print("first open: \(s1.statusMessage ?? "")")
            guard let a = s1.assets.first else { print("no shots"); exit(1) }
            s1.setDecision(a, .keep)
            s1.setRating(a, 2)
            s1.setLocation([a], GeoPoint(latitude: 13.34, longitude: 74.74))
            let old = a.adjustments
            a.adjustments.exposure = 0.5
            s1.commitAdjustments(a, from: old, name: "Exposure")
            print("undo title: \(s1.undoTitle ?? "-")")
            s1.flushSave()
            let s2 = await open()
            print("second open: \(s2.statusMessage ?? "")")
            if let b = s2.assets.first(where: { $0.baseName == a.baseName }) {
                print("restored: decision=\(b.decision.rawValue) rating=\(b.userRating.map(String.init) ?? "nil") loc=\(b.location != nil) exposure=\(b.adjustments.exposure) best-follows-rating=\(b.displayStars)")
                // clean up so the user's library starts clean
                s2.setDecision(b, .undecided); s2.setRating(b, nil); s2.setLocation([b], nil); s2.resetAdjustments(b)
                s2.flushSave()
            }
            exit(0)
        }
    }

    /// For the largest stacks: per-shot time gap, feature distance to previous / to first member, and a contact sheet.
    static func stackDump(_ folder: URL, out: URL) {
        Task { @MainActor in
            let store = LibraryStore()
            store.load(folder)
            while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            func d(_ a: PhotoAsset, _ b: PhotoAsset) -> Float {
                guard let fa = a.featurePrint, let fb = b.featurePrint else { return .nan }
                var x: Float = 0; try? fa.computeDistance(&x, to: fb); return x
            }
            let big = store.stacks.sorted { $0.members.count > $1.members.count }.prefix(4)
            for (n, s) in big.enumerated() {
                let m = s.members
                print("== stack \(n) size=\(m.count) span=\(Int(m.last!.captureDate.timeIntervalSince(m[0].captureDate)))s")
                var line = ""
                for (i, a) in m.enumerated() {
                    let gap = i == 0 ? 0 : a.captureDate.timeIntervalSince(m[i - 1].captureDate)
                    line += String(format: "%@ gap=%.1f dPrev=%.2f dFirst=%.2f\n", a.baseName, gap,
                                   i == 0 ? 0 : d(a, m[i - 1]), d(a, m[0]))
                }
                print(line, terminator: "")
                // contact sheet: up to 24 thumbs, 6 per row
                let thumbs = m.prefix(24).compactMap { $0.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                let cw = 240, ch = 160, cols = 6, rows = (thumbs.count + cols - 1) / cols
                guard let ctx = CGContext(data: nil, width: cw * cols, height: ch * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cw * cols, height: ch * rows))
                for (i, t) in thumbs.enumerated() {
                    let r = CGRect(x: (i % cols) * cw, y: (rows - 1 - i / cols) * ch, width: cw, height: ch).insetBy(dx: 3, dy: 3)
                    let sc = min(r.width / CGFloat(t.width), r.height / CGFloat(t.height))
                    ctx.draw(t, in: CGRect(x: r.midX - CGFloat(t.width) * sc / 2, y: r.midY - CGFloat(t.height) * sc / 2,
                                           width: CGFloat(t.width) * sc, height: CGFloat(t.height) * sc))
                }
                let u = out.appendingPathComponent("stack\(n).jpg")
                let dst = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil)!
                CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
            }
            exit(0)
        }
    }

    /// Location + rating into originals (COPIES!), verify JPEG pixels unchanged, sidecar merge, then undo.
    static func metaTest(_ folder: URL) {
        Task { @MainActor in
            let store = LibraryStore()
            store.load(folder)
            while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            guard let a = store.assets.first(where: { $0.isPair }), let jpg = a.jpegURL, let raw = a.rawURL else { print("need a RAW+JPEG pair"); exit(1) }
            func pixels(_ u: URL) -> Data {
                let src = CGImageSourceCreateWithURL(u as CFURL, nil)!
                let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                return img.dataProvider!.data! as Data
            }
            func show(_ tag: String) {
                let j = MetadataWriter.read(jpg), r = MetadataWriter.read(raw)
                print("\(tag): jpeg gps=\(j.gps.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "none") rating=\(j.rating.map(String.init) ?? "none") | raw-sidecar gps=\(r.gps.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "none") rating=\(r.rating.map(String.init) ?? "none")")
            }
            let before = pixels(jpg)
            let sizeBefore = (try? jpg.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            show("before")
            store.setLocation([a], GeoPoint(latitude: 13.3409, longitude: 74.7421))
            store.setRating(a, 4)
            while store.pendingFileWrites > 0 || true {
                try? await Task.sleep(for: .milliseconds(1500))
                if store.pendingFileWrites == 0 { break }
            }
            show("after set")
            let after = pixels(jpg)
            let sizeAfter = (try? jpg.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            print("jpeg pixels identical: \(before == after)  size \(sizeBefore) -> \(sizeAfter) bytes")
            if let x = try? String(contentsOf: Sidecar.url(for: raw), encoding: .utf8),
               let r = x.range(of: "GPSLatitude[^/]{0,40}", options: .regularExpression) { print("sidecar:", x[r]) }
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(jpg as CFURL, nil)!, 0, nil) as! [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            print("exif lens still there: \(exif?[kCGImagePropertyExifLensModel] ?? "MISSING")  maker note keys: \((props[kCGImagePropertyMakerAppleDictionary] != nil) ? "apple" : "n/a")")
            let side = Sidecar.url(for: raw)
            if let x = try? String(contentsOf: side, encoding: .utf8) {
                print("sidecar keeps darktable data: \(x.contains("darktable")) has Rating: \(x.contains("Rating")) has GPS: \(x.contains("GPSLatitude"))")
            }
            store.undo(); store.undo()
            try? await Task.sleep(for: .milliseconds(1500))
            while store.pendingFileWrites > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            show("after undo")
            print("jpeg pixels still identical: \(pixels(jpg) == before)")
            print("status: \(store.statusMessage ?? "")")
            exit(0)
        }
    }

    /// Slider responsiveness on a RAW: cold render, post-decoder edit, decoder edit while dragging, exact.
    /// Also writes crop/straighten and clipping-overlay samples for visual checks.
    static func perfTest(_ raw: URL, out: URL) {
        Task { @MainActor in
            func t(_ name: String, _ adj: Adjustments, interactive: Bool = false, draft: Bool = false) async -> CGImage? {
                let s = Date()
                let r = await Develop.renderScaled(raw: raw, jpeg: nil, useRaw: true, adjustments: adj, maxPixel: 2400,
                                                   draft: draft, interactive: interactive)
                print(String(format: "%-34@ %5d ms", name as NSString, Int(Date().timeIntervalSince(s) * 1000)))
                return r?.image
            }
            var a = Adjustments()
            _ = await t("first render (cold decode)", a)
            let fs = Date()
            _ = await Develop.renderScaled(raw: raw, jpeg: nil, useRaw: true, adjustments: a, maxPixel: nil, draft: false)
            print(String(format: "%-34@ %5d ms", "full resolution (cold decode)" as NSString, Int(Date().timeIntervalSince(fs) * 1000)))
            let siblings = ((try? FileManager.default.contentsOfDirectory(at: raw.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.uppercased() == raw.pathExtension.uppercased() && $0 != raw }.sorted { $0.path < $1.path }.prefix(3)
            for (n, other) in siblings.enumerated() {
                let os = Date()
                _ = await Develop.renderScaled(raw: other, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 2400, draft: false)
                let m1 = Int(Date().timeIntervalSince(os) * 1000)
                let ds = Date()
                _ = await Develop.renderScaled(raw: other, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 1400, draft: true)
                print(String(format: "next photo %d: screen %5d ms · quick draft after %5d ms", n + 1, m1, Int(Date().timeIntervalSince(ds) * 1000)))
            }
            for other in siblings.prefix(1) {
                let ds = Date()
                _ = await RAWDecoder.render(other.deletingLastPathComponent().appendingPathComponent(siblings.last!.lastPathComponent), maxPixel: 1400, draft: true)
                print(String(format: "draft-only decode of a decoded file %5d ms", Int(Date().timeIntervalSince(ds) * 1000)))
            }
            a.shadows = 0.4; a.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
            _ = await t("shadows + curve (cached decode)", a)
            a.vibrance = 0.3; a.whites = -0.2
            _ = await t("vibrance + whites (cached decode)", a)
            a.exposure = 0.5
            _ = await t("exposure drag tick (approx)", a, interactive: true)
            a.exposure = 0.7
            _ = await t("exposure drag tick (approx)", a, interactive: true)
            _ = await t("exposure release (exact decode)", a)
            a.noiseReduction = 0.8
            _ = await t("noise reduction release (exact)", a)
            // Visual samples
            var c = Adjustments(); c.angle = 8; c.crop = CropRect(x: 0.1, y: 0.1, w: 0.6, h: 0.7)
            if let img = await t("straighten 8° + crop", c) { save(img, out.appendingPathComponent("crop.jpg")) }
            if let base = await t("plain (for clipping)", Adjustments()), let o = ClippingOverlay.apply(base) {
                save(o, out.appendingPathComponent("clipping.jpg"))
            }
            exit(0)
        }
    }

    static func save(_ cg: CGImage, _ u: URL) {
        let d = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
    }

    /// Rows: a query face + its 6 nearest faces (distance printed), for calibrating the match threshold.
    static func faceDump(_ folder: URL, out: URL) {
        Task { @MainActor in
            let store = LibraryStore()
            store.load(folder)
            while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            let t0 = Date()
            await store.indexFaces()
            while store.isIndexingFaces { try? await Task.sleep(for: .milliseconds(200)) }
            var all: [(PhotoAsset, Int)] = []
            for a in store.assets { for i in a.faces.indices where a.facePrints.indices.contains(i) && a.facePrints[i] != nil && (a.faces[i].quality ?? 0) > 0.3 { all.append((a, i)) } }
            print("indexed faces: \(all.count) in \(Int(Date().timeIntervalSince(t0)))s")
            guard !all.isEmpty else { print("no indexed faces"); exit(1) }
            let queries = stride(from: 0, to: all.count, by: max(1, all.count / 8)).prefix(8).map { all[$0] }
            let cell = 110, cols = 7
            let ctx = CGContext(data: nil, width: cell * cols, height: cell * queries.count, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cell * cols, height: cell * queries.count))
            func crop(_ a: PhotoAsset, _ i: Int) -> CGImage? {
                guard let img = Analyzer.loadImage(a.displayURL, maxPixel: 1600, isRaw: a.isRawOnly) else { return nil }
                let W = CGFloat(img.width), H = CGFloat(img.height), r = a.faces[i].rect
                let side = max(r.width * W, r.height * H) * 1.3
                return img.cropping(to: CGRect(x: r.midX * W - side / 2, y: (1 - r.midY) * H - side / 2, width: side, height: side).integral)
            }
            for (row, q) in queries.enumerated() {
                let near = all.filter { !($0.0 === q.0 && $0.1 == q.1) }
                    .map { ($0, FaceIndex.distance(q.0.facePrints[q.1], $0.0.facePrints[$0.1])) }
                    .sorted { $0.1 < $1.1 }.prefix(cols - 1)
                print("row \(row): \(q.0.baseName) → " + near.map { String(format: "%@ %.2f", $0.0.0.baseName, $0.1) }.joined(separator: " | "))
                let items = [(q, Float(0))] + near.map { ($0.0, $0.1) }
                for (c, it) in items.enumerated() {
                    if let img = crop(it.0.0, it.0.1) {
                        ctx.draw(img, in: CGRect(x: c * cell + 3, y: (queries.count - 1 - row) * cell + 3, width: cell - 6, height: cell - 6))
                    }
                }
            }
            save(ctx.makeImage()!, out.appendingPathComponent("faces.jpg"))
            exit(0)
        }
    }

    /// Contact sheet of every built-in look + white-balance direction checks on each render path.
    static func lookTest(raw: URL, jpeg: URL, out: URL) {
        Task { @MainActor in
            func rb(_ cg: CGImage?) -> Double {
                guard let cg else { return .nan }
                let w = 64, h = 64; var px = [UInt8](repeating: 0, count: w * h * 4)
                let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                var r = 0.0, b = 0.0
                for i in 0..<(w * h) { r += Double(px[i * 4]); b += Double(px[i * 4 + 2]) }
                return (r - b) / Double(w * h)
            }
            var warm = Adjustments(); warm.temperature = 2000
            let base = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: .init(), maxPixel: 600, draft: false)
            let exact = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: warm, maxPixel: 600, draft: false)
            var warm2 = Adjustments(); warm2.temperature = 1000
            _ = await Develop.renderScaled(raw: raw, jpeg: nil, useRaw: true, adjustments: warm2, maxPixel: 600, draft: false)
            let approx = await Develop.renderScaled(raw: raw, jpeg: nil, useRaw: true, adjustments: warm, maxPixel: 600, draft: false, interactive: true)?.image
            let jb = await Develop.render(raw: nil, jpeg: jpeg, useRaw: false, adjustments: .init(), maxPixel: 600, draft: false)
            let jw = await Develop.render(raw: nil, jpeg: jpeg, useRaw: false, adjustments: warm, maxPixel: 600, draft: false)
            print(String(format: "R-B  raw base %.1f | raw +2000K exact %.1f | approx %.1f || jpeg base %.1f | jpeg +2000K %.1f",
                         rb(base), rb(exact), rb(approx), rb(jb), rb(jw)))
            var amber = Adjustments(); amber.look = LookRecipe(name: "t", group: "t", base: .ST, shiftAB: 5)
            var blue = Adjustments(); blue.look = LookRecipe(name: "t", group: "t", base: .ST, shiftAB: -5)
            print(String(format: "R-B  look shift A5 %.1f | B5 %.1f",
                         rb(await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: amber, maxPixel: 600, draft: false)),
                         rb(await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: blue, maxPixel: 600, draft: false))))
            // Contact sheet: all built-in looks (grid-style fast path after the first decode).
            let cell = 300, cols = 5, looks = LookRecipe.builtIn
            let rows = (looks.count + cols - 1) / cols
            let ctx = CGContext(data: nil, width: cell * cols, height: cell * 2 / 3 * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let t0 = Date()
            for (i, l) in looks.enumerated() {
                var a = Adjustments(); a.look = l
                guard let img = await Develop.renderScaled(raw: raw, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 600,
                                                           draft: false, interactive: true)?.image else { continue }
                let r = CGRect(x: (i % cols) * cell, y: (rows - 1 - i / cols) * cell * 2 / 3, width: cell, height: cell * 2 / 3).insetBy(dx: 2, dy: 2)
                ctx.draw(img, in: r)
            }
            print("10 looks rendered in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            // Grid conditions: every tile at once, cold cache, other photo.
            let other = raw.deletingLastPathComponent().appendingPathComponent("DSC03895.ARW")
            let g0 = Date()
            await withTaskGroup(of: Void.self) { g in
                for l in LookRecipe.builtIn {
                    g.addTask {
                        var a = Adjustments(); a.look = l
                        _ = await Develop.renderScaled(raw: other, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 640,
                                                       draft: true, interactive: true)
                    }
                }
            }
            print("grid: \(LookRecipe.builtIn.count) tiles concurrently in \(Int(Date().timeIntervalSince(g0) * 1000)) ms")
            let sample = """
            Jonpoon.jpg
            Singapore
            VV2 (Vivid 2) | Contrast +1, Highlights +1, Shadows +2, Fade 1, Saturation 0, Sharpness 4, Sharpness Range 4, Clarity 8, WB AWB A1 G1

            Kodak-ish Summer
            Creative Look: FL
            Contrast: -2
            Highlights: -3
            Shadows: +2
            Fade: 3
            Saturation: -1
            Sharpness: 2
            Clarity: 1
            White Balance: 5600K, A2 M1
            DRO: Lv2

            Name: Moody Mono
            Creative Look: BW, Contrast +4, Saturation +3, Shadows -2, WB Daylight B1
            """
            for r in RecipeParser.parse(sample, group: "Test") { print("parsed: \(r.name) → \(r.settingsLine)") }
            // Your library looks (incl. Picture Profiles): decode + render sheet with per-look mean brightness.
            let mine = MyLooksStore.load()
            print("my looks decoded: \(mine.count)")
            let mc = 6, mrows = (mine.count + mc - 1) / mc, mw = 260, mh = 174
            let sheet = CGContext(data: nil, width: mw * mc, height: mh * mrows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let landscape = raw.deletingLastPathComponent().appendingPathComponent("DSC03778.ARW")
            for (i, l) in mine.enumerated() {
                var a = Adjustments(); a.look = l
                let t = Date()
                guard let img = await Develop.render(raw: landscape, jpeg: nil, useRaw: true, adjustments: a, maxPixel: 520, draft: false) else {
                    print("  FAILED \(l.name)"); continue
                }
                let w = 32, h = 32; var px = [UInt8](repeating: 0, count: w * h * 4)
                let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                var r = 0.0, g = 0.0, b = 0.0
                for k in 0..<(w * h) { r += Double(px[k * 4]); g += Double(px[k * 4 + 1]); b += Double(px[k * 4 + 2]) }
                let n = Double(w * h)
                print(String(format: "  %-28@ %@ mean RGB %3.0f %3.0f %3.0f  %4d ms", l.name as NSString, l.isProfile ? "PP" : "CL",
                             r / n, g / n, b / n, Int(Date().timeIntervalSince(t) * 1000)))
                sheet.draw(img, in: CGRect(x: (i % mc) * mw, y: (mrows - 1 - i / mc) * mh, width: mw, height: mh).insetBy(dx: 2, dy: 2))
            }
            save(sheet.makeImage()!, out.appendingPathComponent("mylooks.jpg"))
            save(ctx.makeImage()!, out.appendingPathComponent("looks.jpg"))
            exit(0)
        }
    }

    /// Hand-tuned looks vs the camera's own JPEGs, then learned LUTs (fit on half, scored on the other half).
    @discardableResult
    static func lookCompare(_ folders: [URL], out: URL?, save shouldSave: Bool,
                            progress: (@MainActor @Sendable (String) -> Void)? = nil) async -> [String] {
        let log = RunLog(file: (out ?? LookCalibration.dir).appendingPathComponent("lookcompare.log"), progress: progress)
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        // Measure the hand-tuned looks, not previously learned LUTs.
        LookCalibration.bypass = true
        defer { LookCalibration.bypass = false }

        var shots: [LCShot] = []
        for f in folders {
            for item in FolderScanner.scan(f) {
                guard let j = item.jpeg, let r = item.raw, let look = LookCalibration.cameraLook(j) else { continue }
                shots.append(LCShot(look: look, raw: r, jpg: j, test: false))
            }
        }
        // Per look: even index → train (≤40), odd → test (≤20).
        var jobs: [LCShot] = []
        var counts: [CreativeLook: Int] = [:]
        let onlyArg = CommandLine.arguments.firstIndex(of: "--only").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CreativeLook(rawValue: CommandLine.arguments[$0 + 1]) : nil }
        for look in CreativeLook.allCases where onlyArg == nil || onlyArg == look {
            let s = shots.filter { $0.look == look }.sorted { $0.jpg.lastPathComponent < $1.jpg.lastPathComponent }
            counts[look] = s.count
            guard s.count >= 3 else { continue }
            // Every 4th shot is held out for testing (≤40); the rest train (≤120).
            // Spread evenly over all the shots, so one shoot doesn't dominate.
            func pick(_ a: [LCShot], _ n: Int) -> [LCShot] { a.count <= n ? a : (0..<n).map { a[$0 * a.count / n] } }
            jobs += pick(s.enumerated().filter { $0.offset % 4 != 1 }.map(\.element), 120)
            jobs += pick(s.enumerated().filter { $0.offset % 4 == 1 }.map { var x = $0.element; x.test = true; return x }, 40)
        }
        log("Found \(shots.count) RAW+JPEG pairs with a known look: " +
            CreativeLook.allCases.compactMap { l in counts[l].flatMap { $0 > 0 ? "\(l.rawValue) \($0)" : nil } }.joined(separator: ", "))
        log("Rendering \(jobs.count) shots with \(workers) parallel workers (Core Image on the GPU)…")

        // Phase 1: render every shot in parallel.
        let t0 = Date()
        var data: [LCShotData] = []
        await withTaskGroup(of: LCShotData?.self) { group in
            var next = 0, done = 0
            func add() {
                guard next < jobs.count else { return }
                let s = jobs[next]; next += 1
                group.addTask { await processShot(s) }
            }
            for _ in 0..<min(workers, jobs.count) { add() }
            while let r = await group.next() {
                done += 1
                if let r {
                    data.append(r)
                    let rate = Double(done) / max(0.001, Date().timeIntervalSince(t0))
                    let eta = Double(jobs.count - done) / max(0.001, rate)
                    log(String(format: "%d/%d  %@ %@ %@  %.1fs  (%.1f shots/s, ~%ds left)", done, jobs.count,
                               r.shot.look.rawValue, r.shot.test ? "test " : "train", r.shot.raw.lastPathComponent,
                               r.seconds, rate, Int(eta)))
                } else {
                    log("\(done)/\(jobs.count)  skipped (could not decode)")
                }
                add()
            }
        }
        log(String(format: "Rendered %d shots in %.0fs", data.count, Date().timeIntervalSince(t0)))

        // Phase 2: fit + score each look in parallel.
        let looks = CreativeLook.allCases.filter { l in data.contains { $0.shot.look == l } }
        var results: [CreativeLook: LCLookResult] = [:]
        await withTaskGroup(of: LCLookResult?.self) { group in
            for look in looks {
                let mine = data.filter { $0.shot.look == look }
                group.addTask { await Blocking.run { fitAndScore(look, mine) } }
            }
            while let r = await group.next() {
                guard let r else { continue }
                results[r.look] = r
                log(String(format: "%@: ΔE hand-tuned %.2f → learned %.2f (%d train, %d test)",
                           r.look.rawValue, r.eHand, r.eLearn, r.train, r.test))
            }
        }

        var report = ["look  shots  train/test |  ΔE hand-tuned → learned  | camera vs hand-tuned: ΔL  Δcontrast Δchroma Δwarmth"]
        var sheetRows: [[CGImage]] = []
        for look in looks {
            guard let r = results[look] else { continue }
            report.append(String(format: "%-4@ %5d  %3d/%-3d     |  %5.2f → %5.2f            |  %+5.1f  %+5.1f  %+5.1f  %+5.1f",
                                 look.rawValue as NSString, counts[look] ?? 0, r.train, r.test, r.eHand, r.eLearn,
                                 r.d.L, r.d.contrast, r.d.chroma, r.d.warmth))
            if let s = r.sample { sheetRows.append([s.cam, s.hand, s.learned].compactMap { image($0, s.w, s.h) }) }
            if let out {
                // Always keep this run's LUTs next to the report, so a dry run can be installed later.
                try? r.lut.write(to: out.appendingPathComponent("\(look.rawValue).lut"))
            }
            let existing = LookCalibration.meta(look)
            if shouldSave, let e = existing, r.train < e.trainShots {
                log("Kept the existing \(look.rawValue) (learned from \(e.trainShots) shots; this folder has \(r.train))")
            } else if shouldSave && r.eLearn < r.eHand {
                do {
                    try LookCalibration.save(look, lut: r.lut, meta: .init(look: look.rawValue, trainShots: r.train, testShots: r.test,
                                                                       deltaEHandTuned: r.eHand, deltaELearned: r.eLearn, created: Date()))
                    log("Saved learned \(look.rawValue)")
                } catch { log("Could not save \(look.rawValue): \(error.localizedDescription)") }
            }
        }
        for line in report { log(line) }
        // Sheet: per look, camera JPEG | hand-tuned | learned.
        let cw = 240, ch = 180
        if let out, !sheetRows.isEmpty, let ctx = CGContext(data: nil, width: cw * 3, height: ch * sheetRows.count, bitsPerComponent: 8, bytesPerRow: 0,
                                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cw * 3, height: ch * sheetRows.count))
            for (r, row) in sheetRows.enumerated() { for (c, img) in row.enumerated() {
                let box = CGRect(x: c * cw, y: (sheetRows.count - 1 - r) * ch, width: cw, height: ch).insetBy(dx: 2, dy: 2)
                let sc = min(box.width / CGFloat(img.width), box.height / CGFloat(img.height))
                ctx.draw(img, in: CGRect(x: box.midX - CGFloat(img.width) * sc / 2, y: box.midY - CGFloat(img.height) * sc / 2,
                                         width: CGFloat(img.width) * sc, height: CGFloat(img.height) * sc))
            } }
            save(ctx.makeImage()!, out.appendingPathComponent("lookcompare.jpg"))
            log("Wrote \(out.appendingPathComponent("lookcompare.jpg").path)")
        }
        log(String(format: "Done in %.0fs", Date().timeIntervalSince(t0)))
        return report
    }

    /// Sony-rendered reference images (`NAME-<LOOK>.tif/jpg` beside `NAME.ARW`), grouped by RAW.
    nonisolated static func sonyReferences(in folders: [URL]) -> [(raw: URL, refs: [CreativeLook: URL])] {
        var out: [URL: [CreativeLook: URL]] = [:]
        let rawExts: Set<String> = ["arw", "srf", "sr2", "dng"]
        for f in folders {
            guard let e = FileManager.default.enumerator(at: f, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where ["tif", "tiff", "jpg", "jpeg", "png"].contains(u.pathExtension.lowercased()) {
                let name = u.deletingPathExtension().lastPathComponent
                guard let dash = name.lastIndex(of: "-") else { continue }
                let base = String(name[..<dash]), code = String(name[name.index(after: dash)...]).uppercased()
                guard let look = CreativeLook(rawValue: code) else { continue }
                let dir = u.deletingLastPathComponent()
                guard let raw = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .first(where: { $0.deletingPathExtension().lastPathComponent == base && rawExts.contains($0.pathExtension.lowercased()) })
                else { continue }
                out[raw, default: [:]][look] = u
            }
        }
        return out.map { ($0.key, $0.value) }.sorted { $0.raw.path < $1.raw.path }
    }

    /// Hand-tuned looks vs Sony's own renders of the same RAW; learned LUTs are fit on the left half
    /// of the frame and scored on the right half.
    static func refCompare(_ folders: [URL], out: URL) async -> [String] {
        let log = RunLog(file: out.appendingPathComponent("refcompare.log"), progress: nil)
        LookCalibration.bypass = true
        defer { LookCalibration.bypass = false }
        let W = 400
        var report = ["look  | ΔE hand-tuned  (right half)  learned-on-left | hand vs Sony: ΔL  Δcontrast Δchroma Δwarmth"]
        var rows: [[CGImage]] = []
        for (raw, refs) in sonyReferences(in: folders) {
            log("\(raw.lastPathComponent): references for \(refs.keys.map(\.rawValue).sorted().joined(separator: ", "))")
            func px(_ img: CGImage?, _ w: Int, _ h: Int) -> [SIMD3<Float>]? { img.map { LookCalibration.pixels($0, w: w, h: h) } }
            guard let first = refs.values.first, let src = CGImageSourceCreateWithURL(first as CFURL, nil),
                  let t = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { continue }
            let w = t.width >= t.height ? W : W * t.width / t.height, h = t.width >= t.height ? W * t.height / t.width : W
            guard let base = px(await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: 1200, draft: false), w, h) else { continue }
            let right = (0..<(w * h)).filter { $0 % w >= w / 2 }
            for look in CreativeLook.allCases {
                guard let ru = refs[look], let rs = CGImageSourceCreateWithURL(ru as CFURL, nil),
                      let rt = CGImageSourceCreateThumbnailAtIndex(rs, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { continue }
                let ref = LookCalibration.pixels(rt, w: w, h: h)
                var adj = Adjustments(); adj.look = LookRecipe.presets.first { $0.base == look }
                guard let hand = px(await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: adj, maxPixel: 1200, draft: false), w, h) else { continue }
                // Training pairs from the left half, skipping edges.
                var train: [(SIMD3<Float>, SIMD3<Float>)] = [], all: [(SIMD3<Float>, SIMD3<Float>)] = []
                for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                    let i = y * w + x
                    let dx: SIMD3<Float> = base[i + 1] - base[i - 1], dy: SIMD3<Float> = base[i + w] - base[i - w]
                    let g: Float = max(abs(dx.x), abs(dx.y), abs(dx.z)) + max(abs(dy.x), abs(dy.y), abs(dy.z))
                    guard g < 0.12 else { continue }
                    all.append((base[i], ref[i]))
                    if x < w / 2 { train.append((base[i], ref[i])) }
                } }
                let half = LookCalibration.fit(train), full = LookCalibration.fit(all)
                let sub = { (a: [SIMD3<Float>]) in right.map { a[$0] } }
                let eHand = LookCalibration.deltaE(sub(hand), sub(ref))
                let eLearn = LookCalibration.deltaE(sub(LookCalibration.applyCPU(base, half)), sub(ref))
                let sh = LookCalibration.stats(hand), sr = LookCalibration.stats(ref)
                let line = String(format: "%-4@  |  %5.2f   →   %5.2f              | %+6.1f  %+6.1f  %+6.1f  %+6.1f", look.rawValue as NSString,
                                  eHand, eLearn, sh.L - sr.L, sh.contrast - sr.contrast, sh.chroma - sr.chroma, sh.warmth - sr.warmth)
                report.append(line); log(line)
                try? full.write(to: out.appendingPathComponent("\(look.rawValue)-sony.lut"))
                rows.append([ref, hand, LookCalibration.applyCPU(base, full)].compactMap { image($0, w, h) })
            }
        }
        let cw = 300, ch = 200
        if !rows.isEmpty, let ctx = CGContext(data: nil, width: cw * 3, height: ch * rows.count, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cw * 3, height: ch * rows.count))
            for (r, row) in rows.enumerated() { for (c, img) in row.enumerated() {
                let box = CGRect(x: c * cw, y: (rows.count - 1 - r) * ch, width: cw, height: ch).insetBy(dx: 2, dy: 2)
                let sc = min(box.width / CGFloat(img.width), box.height / CGFloat(img.height))
                ctx.draw(img, in: CGRect(x: box.midX - CGFloat(img.width) * sc / 2, y: box.midY - CGFloat(img.height) * sc / 2,
                                         width: CGFloat(img.width) * sc, height: CGFloat(img.height) * sc))
            } }
            save(ctx.makeImage()!, out.appendingPathComponent("refcompare.jpg"))
        }
        return report
    }

    static func handCheck(fitted: [String: [Double]], folders: [URL]) async {
        LookCalibration.bypass = true
        var byLook: [CreativeLook: [(URL, URL)]] = [:]
        for f in folders { for item in FolderScanner.scan(f) {
            guard let j = item.jpeg, let r = item.raw, let l = LookCalibration.cameraLook(j), fitted[l.rawValue] != nil else { continue }
            byLook[l, default: []].append((r, j))
        } }
        print("look shots | ΔE built-in → Sony-fitted | ΔL built-in → fitted | worst shot built-in → fitted")
        for look in CreativeLook.allCases {
            guard let v = fitted[look.rawValue], let shots = byLook[look] else { continue }
            let pick = shots.sorted { $0.1.lastPathComponent < $1.1.lastPathComponent }
            let step = max(1, pick.count / 15)
            let sample = stride(from: 0, to: pick.count, by: step).map { pick[$0] }.prefix(15)
            let fit = LookFit.base(v, mono: look.base.mono)
            var eOld = 0.0, eNew = 0.0, lOld = 0.0, lNew = 0.0, worstOld = 0.0, worstNew = 0.0, n = 0.0
            for (raw, jpg) in sample {
                guard let p = processShotPixels(raw: raw, jpg: jpg), let baseCG = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: 640, draft: true) else { continue }
                let src = CIImage(cgImage: baseCG)
                let old = LookFit.render(src, look, look.base, w: p.w, h: p.h)
                let new = LookFit.render(src, look, fit, w: p.w, h: p.h)
                let a = LookCalibration.deltaE(old, p.px), b = LookCalibration.deltaE(new, p.px)
                let sc = LookCalibration.stats(p.px)
                eOld += a; eNew += b; worstOld = max(worstOld, a); worstNew = max(worstNew, b)
                lOld += LookCalibration.stats(old).L - sc.L; lNew += LookCalibration.stats(new).L - sc.L; n += 1
            }
            guard n > 0 else { continue }
            print(String(format: "%-4@ %3d  |  %5.2f → %5.2f   |  %+5.1f → %+5.1f  |  %5.2f → %5.2f", look.rawValue as NSString, Int(n),
                         eOld / n, eNew / n, lOld / n, lNew / n, worstOld, worstNew))
        }
    }

    static func camFit(sony: [String: [Double]], out: URL, folders: [URL]) async {
        LookCalibration.bypass = true
        var byLook: [CreativeLook: [(URL, URL)]] = [:]
        for f in folders { for item in FolderScanner.scan(f) {
            guard let j = item.jpeg, let r = item.raw, let l = LookCalibration.cameraLook(j), l != .ST else { continue }
            byLook[l, default: []].append((r, j))
        } }
        func spread<T>(_ a: [T], _ n: Int) -> [T] {
            guard a.count > n else { return a }
            return (0..<n).map { a[$0 * a.count / n] }
        }
        func scene(_ shot: (URL, URL)) async -> LookFit.Scene? {
            guard let cam = LookFit.load(shot.1, maxPixel: 360),
                  let base = await Develop.render(raw: shot.0, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: 640, draft: true) else { return nil }
            // Base at the camera JPEG's size so pixels line up.
            let ctx = CGContext(data: nil, width: cam.width, height: cam.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: cam.width, height: cam.height))
            return ctx.makeImage().map { LookFit.Scene(st: $0, target: cam) }
        }
        var result: [String: [Double]] = [:]
        print("look train/test | held-out ΔE: built-in  Sony-fitted  camera-fitted")
        for look in CreativeLook.allCases {
            guard let shots = byLook[look]?.sorted(by: { $0.1.lastPathComponent < $1.1.lastPathComponent }), shots.count >= 4 else { continue }
            let trainShots = spread(shots.enumerated().filter { $0.offset % 2 == 0 }.map(\.element), 12)
            let testShots = spread(shots.enumerated().filter { $0.offset % 2 == 1 }.map(\.element), 15)
            var train: [LookFit.Scene] = [], test: [LookFit.Scene] = []
            for s in trainShots { if let x = await scene(s) { train.append(x) } }
            for s in testShots { if let x = await scene(s) { test.append(x) } }
            let start = sony[look.rawValue] ?? LookFit.startVector(look)
            let cam = LookFit.descend(start, look, train)   // CLI only; blocking is fine
            result[look.rawValue] = cam
            let eBuilt = LookFit.error(LookFit.startVector(look), look, test)
            let eSony = sony[look.rawValue].map { LookFit.error($0, look, test) } ?? .nan
            let eCam = LookFit.error(cam, look, test)
            print(String(format: "%-4@ %2d/%-2d | %6.2f  %6.2f  %6.2f   ", look.rawValue as NSString, train.count, test.count, eBuilt, eSony, eCam)
                  + zip(LookFit.names, cam.map { String(format: "%.3f", $0) }).map { "\($0)=\($1)" }.joined(separator: " "))
        }
        try? JSONEncoder().encode(result).write(to: out)
        print("wrote \(out.path)")
    }

    /// The look parameters Apixa shipped before fitting them to real Sony output (for before/after).
    static func previousBase(_ l: CreativeLook) -> LookBase {
        switch l {
        case .PT: LookBase(contrast: -0.12, saturation: -0.05, warmth: 0.04)
        case .NT: LookBase(contrast: -0.2, saturation: -0.35)
        case .VV: LookBase(contrast: 0.14, saturation: 0.2, vibrance: 0.08)
        case .VV2: LookBase(exposure: 0.12, contrast: 0.08, saturation: 0.22, vibrance: 0.25, highlightRolloff: 0.15)
        case .FL: LookBase(contrast: 0.15, saturation: -0.28, fade: 0.02,
                           shadowTint: (-0.035, 0.015, 0.055), highlightTint: (0.03, 0.015, -0.025), highlightRolloff: 0.08)
        case .IN: LookBase(contrast: -0.1, saturation: -0.2, fade: 0.09, warmth: 0.03, highlightRolloff: 0.1)
        case .SH: LookBase(exposure: 0.3, contrast: -0.3, saturation: -0.15, fade: 0.03, highlightTint: (0.01, 0, 0.012))
        case .BW: LookBase(contrast: 0.15, mono: true)
        case .SE: LookBase(contrast: 0.08, mono: true, sepia: 0.85)
        default: l.base
        }
    }

    /// For each Sony reference scene and look: Sony's render, Apixa before, Apixa now (JPEGs) + ΔE, as index.json.
    static func refExport(_ folders: [URL], out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        struct Row: Codable { var look: String; var title: String; var source: String; var sony: String; var before: String; var now: String; var eBefore: Double; var eNow: Double }
        struct SceneOut: Codable { var name: String; var camera: String; var rows: [Row] }
        var scenes: [SceneOut] = []
        let side = 640
        func jpeg(_ cg: CGImage, _ name: String) -> String {
            let u = out.appendingPathComponent(name)
            if let d = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary); CGImageDestinationFinalize(d)
            }
            return name
        }
        for (raw, refs) in sonyReferences(in: folders) {
            let stem = raw.deletingPathExtension().lastPathComponent
            let model = (CGImageSourceCreateWithURL(raw as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })?["{TIFF}"]
                .flatMap { ($0 as? [String: Any])?["Model"] as? String } ?? "Sony"
            guard let baseCG = await Develop.render(raw: raw, jpeg: nil, useRaw: true, adjustments: Adjustments(), maxPixel: side, draft: false) else { continue }
            let src = CIImage(cgImage: baseCG)
            var rows: [Row] = []
            for look in CreativeLook.allCases {
                guard let ru = refs[look], let ref = LookFit.load(ru, maxPixel: side) else { continue }
                func render(_ b: LookBase?) -> CGImage? {
                    let o = LookEngine.apply(src, LookRecipe(name: "x", group: "x", base: look), isRaw: false, baseOverride: b)
                    return RAWDecoder.context.createCGImage(o, from: src.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
                guard let before = render(previousBase(look)), let now = render(nil) else { continue }
                let W = 240, H = W * ref.height / max(1, ref.width)
                let rp = LookCalibration.pixels(ref, w: W, h: H)
                let eB = LookCalibration.deltaE(LookCalibration.pixels(before, w: W, h: H), rp)
                let eN = LookCalibration.deltaE(LookCalibration.pixels(now, w: W, h: H), rp)
                let source = [.IN, .SH, .BW].contains(look) ? "Sony renders (these samples)" : look == .ST ? "unchanged" : "your A6700 JPEGs"
                rows.append(Row(look: look.rawValue, title: look.title, source: source,
                                sony: jpeg(ref, "\(stem)-\(look.rawValue)-sony.jpg"),
                                before: jpeg(before, "\(stem)-\(look.rawValue)-before.jpg"),
                                now: jpeg(now, "\(stem)-\(look.rawValue)-now.jpg"), eBefore: eB, eNow: eN))
                print(String(format: "%@ %@ %.2f → %.2f", stem, look.rawValue, eB, eN))
            }
            scenes.append(SceneOut(name: stem, camera: model, rows: rows))
        }
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try? enc.encode(scenes).write(to: out.appendingPathComponent("index.json"))
    }

    nonisolated static func processShotPixels(raw: URL, jpg: URL) -> LCPixels? {
        let W = compareSide
        guard let src = CGImageSourceCreateWithURL(jpg as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return nil }
        let w = img.width >= img.height ? W : W * img.width / img.height
        let h = img.width >= img.height ? W * img.height / img.width : W
        return LCPixels(px: LookCalibration.pixels(img, w: w, h: h), w: w, h: h)
    }

    /// Every shot in time order with its stack, stars and score parts, as contact-sheet pages + a text table.
    static func auditDump(_ folder: URL, out: URL) {
        Task { @MainActor in
            let store = LibraryStore()
            store.load(folder)
            while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(2))   // let the final restack land
            func d(_ a: PhotoAsset, _ b: PhotoAsset) -> Float {
                guard let fa = a.featurePrint, let fb = b.featurePrint else { return .nan }
                var x: Float = 0; try? fa.computeDistance(&x, to: fb); return x
            }
            print("assets=\(store.assets.count) inStacks=\(store.stacks.reduce(0) { $0 + $1.members.count })")
            let stacks = store.stacks.sorted { ($0.members.first?.captureDate ?? .distantPast) < ($1.members.first?.captureDate ?? .distantPast) }
            var cells: [(PhotoAsset, Int, String)] = []
            var prev: PhotoAsset?
            for (si, s) in stacks.enumerated() {
                for a in s.members {
                    let gap = prev.map { a.captureDate.timeIntervalSince($0.captureDate) } ?? 0
                    let dp = prev.map { d(a, $0) } ?? 0
                    let label = String(format: "%@ s%d %d★%@ sh%.2f ex%.2f f%@ ae%@ g%.0f d%.2f", String(a.baseName.suffix(4)), si, a.stars, a.isBest ? "B" : "",
                                       a.sharpnessScore, a.exposureScore, a.faceQuality.map { String(format: "%.2f", $0) } ?? "-",
                                       a.aesthetic.map { String(format: "%.2f", $0) } ?? "-", gap, dp)
                    print(label + String(format: " rawSharp=%.0f faceSharp=%.0f mean=%.2f score=%.2f", a.sharpness, a.faceSharpness ?? -1, a.meanLuma, a.score))
                    cells.append((a, si, label)); prev = a
                }
            }
            let cw = 300, ch = 230, cols = 6, per = 30
            let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.3, 0.3), (0.3, 0.7, 0.9), (0.4, 0.8, 0.4), (0.9, 0.7, 0.2), (0.7, 0.4, 0.9)]
            for page in 0..<((cells.count + per - 1) / per) {
                let slice = Array(cells[(page * per)..<min(cells.count, (page + 1) * per)])
                let rows = (slice.count + cols - 1) / cols
                guard let ctx = CGContext(data: nil, width: cw * cols, height: ch * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.setFillColor(gray: 0.1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cw * cols, height: ch * rows))
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                for (i, (a, si, label)) in slice.enumerated() {
                    let cell = CGRect(x: (i % cols) * cw, y: (rows - 1 - i / cols) * ch, width: cw, height: ch)
                    let c = palette[si % palette.count]
                    ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1); ctx.fill(CGRect(x: cell.minX, y: cell.maxY - 6, width: cell.width - 2, height: 6))
                    if let t = a.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let r = CGRect(x: cell.minX + 3, y: cell.minY + 34, width: cell.width - 6, height: cell.height - 44)
                        let sc = min(r.width / CGFloat(t.width), r.height / CGFloat(t.height))
                        ctx.draw(t, in: CGRect(x: r.midX - CGFloat(t.width) * sc / 2, y: r.midY - CGFloat(t.height) * sc / 2, width: CGFloat(t.width) * sc, height: CGFloat(t.height) * sc))
                    }
                    let parts = label.split(separator: " ")
                    let l1 = parts.prefix(4).joined(separator: " "), l2 = parts.dropFirst(4).joined(separator: " ")
                    let attr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: a.isBest ? .bold : .regular), .foregroundColor: a.isBest ? NSColor.yellow : NSColor.white]
                    (l1 as NSString).draw(at: CGPoint(x: cell.minX + 4, y: cell.minY + 17), withAttributes: attr)
                    (l2 as NSString).draw(at: CGPoint(x: cell.minX + 4, y: cell.minY + 2), withAttributes: attr)
                }
                NSGraphicsContext.current = nil
                save(ctx.makeImage()!, out.appendingPathComponent("audit-\(page).jpg"))
            }
            exit(0)
        }
    }

    /// Compare size (long side) for look matching.
    nonisolated static let compareSide = 192

    /// One shot: the camera JPEG and Apixa's renders, as pixels (all heavy work off the main actor).
    nonisolated static func processShot(_ s: LCShot) async -> LCShotData? {
        let t = Date()
        let W = compareSide
        let cam: LCPixels? = await Blocking.run {
            guard let src = CGImageSourceCreateWithURL(s.jpg as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return nil }
            let w = img.width >= img.height ? W : W * img.width / img.height
            let h = img.width >= img.height ? W * img.height / img.width : W
            return LCPixels(px: LookCalibration.pixels(img, w: w, h: h), w: w, h: h)
        }
        guard let cam else { return nil }
        func render(_ adj: Adjustments) async -> [SIMD3<Float>]? {
            guard let img = await Develop.render(raw: s.raw, jpeg: nil, useRaw: true, adjustments: adj, maxPixel: 640, draft: true) else { return nil }
            let box = ImageBox(image: img)
            return await Blocking.run { box.image.map { LookCalibration.pixels($0, w: cam.w, h: cam.h) } }
        }
        let cacheURL = LookCalibration.pixelCacheURL(s.raw, side: W)
        var base = await Blocking.run { cacheURL.flatMap { LookCalibration.loadPixels($0, count: cam.px.count) } }
        if base == nil {
            base = await render(Adjustments())
            if let base, let cacheURL { await Blocking.run { LookCalibration.savePixels(base, to: cacheURL) } }
        }
        guard let base else { return nil }
        var d = LCShotData(shot: s, cam: cam.px, base: base, w: cam.w, h: cam.h)
        if s.test {
            var adj = Adjustments(); adj.look = LookRecipe.presets.first { $0.base == s.look }
            guard let hand = await render(adj) else { return nil }
            d.hand = hand
        } else {
            // Training pairs, skipping edges where tiny misalignment dominates.
            let w = cam.w, h = cam.h
            d.pairs = await Blocking.run {
                var pairs: [(SIMD3<Float>, SIMD3<Float>)] = []
                pairs.reserveCapacity(w * h)
                for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                    let i = y * w + x
                    let dx: SIMD3<Float> = base[i + 1] - base[i - 1]
                    let dy: SIMD3<Float> = base[i + w] - base[i - w]
                    let g: Float = max(abs(dx.x), abs(dx.y), abs(dx.z)) + max(abs(dy.x), abs(dy.y), abs(dy.z))
                    if g < 0.12 { pairs.append((base[i], cam.px[i])) }
                } }
                return pairs
            }
            d.base = []   // not needed any more
            d.cam = []
        }
        d.seconds = Date().timeIntervalSince(t)
        return d
    }

    nonisolated static func fitAndScore(_ look: CreativeLook, _ shots: [LCShotData]) -> LCLookResult? {
        let train = shots.filter { !$0.shot.test }, test = shots.filter { $0.shot.test }
        guard !train.isEmpty, !test.isEmpty else { return nil }
        let lut = LookCalibration.fit(train.flatMap(\.pairs))
        var eHand = 0.0, eLearn = 0.0
        var d = LookCalibration.Stats()
        var sample: LCLookResult.Sample?
        for s in test.sorted(by: { $0.shot.jpg.lastPathComponent < $1.shot.jpg.lastPathComponent }) {
            let learned = LookCalibration.applyCPU(s.base, lut)
            eHand += LookCalibration.deltaE(s.hand, s.cam); eLearn += LookCalibration.deltaE(learned, s.cam)
            let sc = LookCalibration.stats(s.cam), sh = LookCalibration.stats(s.hand)
            d.L += sh.L - sc.L; d.contrast += sh.contrast - sc.contrast; d.chroma += sh.chroma - sc.chroma; d.warmth += sh.warmth - sc.warmth
            if sample == nil { sample = .init(cam: s.cam, hand: s.hand, learned: learned, w: s.w, h: s.h) }
        }
        let n = Double(test.count)
        d.L /= n; d.contrast /= n; d.chroma /= n; d.warmth /= n
        return LCLookResult(look: look, lut: lut, eHand: eHand / n, eLearn: eLearn / n, train: train.count, test: test.count, d: d, sample: sample)
    }

    static func image(_ px: [SIMD3<Float>], _ w: Int, _ h: Int) -> CGImage? {
        var b = [UInt8](repeating: 255, count: w * h * 4)
        for i in px.indices { b[i * 4] = UInt8(min(255, max(0, px[i].x * 255))); b[i * 4 + 1] = UInt8(min(255, max(0, px[i].y * 255))); b[i * 4 + 2] = UInt8(min(255, max(0, px[i].z * 255))) }
        return CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
}

struct LCShot: Sendable { let look: CreativeLook; let raw: URL; let jpg: URL; var test: Bool }
struct LCPixels: Sendable { let px: [SIMD3<Float>]; let w: Int; let h: Int }
struct LCShotData: Sendable {
    let shot: LCShot
    var cam: [SIMD3<Float>]
    var base: [SIMD3<Float>]
    var hand: [SIMD3<Float>] = []
    var pairs: [(SIMD3<Float>, SIMD3<Float>)] = []
    var w: Int, h: Int
    var seconds = 0.0
    init(shot: LCShot, cam: [SIMD3<Float>], base: [SIMD3<Float>], w: Int, h: Int) {
        self.shot = shot; self.cam = cam; self.base = base; self.w = w; self.h = h
    }
}
struct LCLookResult: Sendable {
    struct Sample: Sendable { let cam, hand, learned: [SIMD3<Float>]; let w, h: Int }
    let look: CreativeLook
    let lut: Data
    let eHand, eLearn: Double
    let train, test: Int
    let d: LookCalibration.Stats
    let sample: Sample?
}

/// Timestamped progress log: stderr (unbuffered, so it shows live), a log file, and an optional UI callback.
final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private let file: FileHandle?
    private let progress: (@MainActor @Sendable (String) -> Void)?

    init(file url: URL, progress: (@MainActor @Sendable (String) -> Void)?) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        self.progress = progress
    }

    func callAsFunction(_ s: String) {
        let t = Int(Date().timeIntervalSince(start))
        let line = String(format: "[%02d:%02d] ", t / 60, t % 60) + s + "\n"
        let d = Data(line.utf8)
        lock.withLock {
            FileHandle.standardError.write(d)
            file?.write(d)
        }
        if let progress { Task { @MainActor in progress(s) } }
    }

    deinit { try? file?.close() }
}
