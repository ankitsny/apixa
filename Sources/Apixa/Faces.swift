import Foundation
import Vision
import ImageIO

/// Face tagging v1: you name faces; Apixa suggests names for look-alike faces.
///
/// Apple doesn't ship a public face-recognition model, so "look-alike" uses Vision's image feature print
/// on a tight face crop. It's good at "same person, same day, similar light" and weaker across very
/// different conditions — so suggestions are always shown for confirmation, never applied silently.
enum FaceIndex {
    /// Distance under which a face is suggested as the same person (calibrated on real shots).
    static let matchThreshold: Float = 0.58   // calibrated on 252 real faces: no wrong matches ≤0.58, errors from 0.61

    /// Feature prints for each face of a shot, from a 1600px decode.
    static func prints(url: URL, isRaw: Bool, faces: [FaceRegion]) -> [Data?] {
        guard !faces.isEmpty, let img = Analyzer.loadImage(url, maxPixel: 1600, isRaw: isRaw) else { return [] }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        return faces.map { f in
            let r = f.rect
            let side = max(r.width * W, r.height * H) * 1.2
            let rect = CGRect(x: r.midX * W - side / 2, y: (1 - r.midY) * H - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            guard rect.width >= 24, let crop = img.cropping(to: rect) else { return nil }
            let req = VNGenerateImageFeaturePrintRequest()
            req.revision = VNGenerateImageFeaturePrintRequestRevision2
            try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
            return req.results?.first.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
        }
    }

    static func unarchive(_ d: Data?) -> VNFeaturePrintObservation? {
        d.flatMap { $0.isEmpty ? nil : $0 }.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0) }
    }

    static func distance(_ a: VNFeaturePrintObservation?, _ b: VNFeaturePrintObservation?) -> Float {
        guard let a, let b else { return .infinity }
        var d: Float = 0
        return (try? a.computeDistance(&d, to: b)) != nil ? d : .infinity
    }
}

struct FaceRef: Hashable {
    let assetID: UUID
    let index: Int
}

extension LibraryStore {
    /// Everyone you've named, most-tagged first.
    var people: [(name: String, count: Int)] {
        var c: [String: Int] = [:]
        for a in assets { for n in a.faceNames.values { c[n, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func nameFace(_ a: PhotoAsset, _ face: FaceRegion, _ name: String?) {
        let n = name?.trimmingCharacters(in: .whitespaces)
        change([a], name: n?.isEmpty == false ? "Name \(n!)" : "Remove Name") { $0.faceNames[face.key] = (n?.isEmpty == false) ? n : nil }
    }

    /// Best existing name for a face, if a named face is close enough.
    func suggestion(for a: PhotoAsset, faceIndex i: Int) -> (name: String, distance: Float)? {
        guard a.facePrints.indices.contains(i), let fp = a.facePrints[i] else { return nil }
        var best: (String, Float)?
        for b in assets where !b.faceNames.isEmpty {
            for (j, f) in b.faces.enumerated() {
                guard let n = b.faceNames[f.key], b.facePrints.indices.contains(j) else { continue }
                if b === a && j == i { continue }
                let d = FaceIndex.distance(fp, b.facePrints[j])
                if d < (best?.1 ?? .infinity) { best = (n, d) }
            }
        }
        guard let best, best.1 <= FaceIndex.matchThreshold else { return nil }
        return (best.0, best.1)
    }

    /// Unnamed faces that look like the given face.
    func similarUnnamedFaces(to a: PhotoAsset, faceIndex i: Int) -> [FaceRef] {
        guard a.facePrints.indices.contains(i), let fp = a.facePrints[i] else { return [] }
        var out: [FaceRef] = []
        for b in assets {
            for (j, f) in b.faces.enumerated() where b.faceNames[f.key] == nil && !(b === a && j == i) {
                guard b.facePrints.indices.contains(j) else { continue }
                if FaceIndex.distance(fp, b.facePrints[j]) <= FaceIndex.matchThreshold { out.append(FaceRef(assetID: b.id, index: j)) }
            }
        }
        return out
    }

    func nameFaces(_ refs: [FaceRef], _ name: String) {
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var perAsset: [UUID: [Int]] = [:]
        for r in refs { perAsset[r.assetID, default: []].append(r.index) }
        let targets = perAsset.keys.compactMap { byID[$0] }
        change(targets, name: "Name \(refs.count) Faces \(name)") { a in
            for i in perAsset[a.id] ?? [] where a.faces.indices.contains(i) { a.faceNames[a.faces[i].key] = name }
        }
    }

    /// Search across file names, people and places.
    func matches(_ a: PhotoAsset, _ q: String) -> Bool {
        a.baseName.localizedCaseInsensitiveContains(q)
            || a.faceNames.values.contains { $0.localizedCaseInsensitiveContains(q) }
            || (a.effectiveLocation?.placeName?.localizedCaseInsensitiveContains(q) ?? false)
    }
}
