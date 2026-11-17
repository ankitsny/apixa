import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes location / rating / label / people into the ORIGINAL files, metadata only.
///
/// - JPEG: patched in place by `JPEGPatcher`, which keeps every original byte (image data, maker notes,
///   previews) and only appends/replaces the metadata it changes. Verified, then swapped in atomically.
/// - RAW (ARW, CR3, NEF…), HEIC, TIFF, PNG: the standard `NAME.xmp` sidecar that Lightroom, Capture One
///   and Photos read — macOS can't safely rewrite these formats without touching other data.
enum MetadataWriter {
    enum GPS: Sendable { case keep, set(GeoPoint), remove }

    struct Patch: Sendable {
        var gps: GPS = .keep
        var rating: Int?? = .none        // .none = keep, .some(nil) = remove, .some(n) = set
        var label: String?? = .none
        var people: [String]? = nil      // nil = keep

        var isEmpty: Bool {
            if case .keep = gps, case .none = rating, case .none = label, people == nil { return true }
            return false
        }
    }

    /// What a file held before a patch, so the patch can be undone.
    struct Previous: Sendable, Codable, Equatable {
        var gps: GeoPoint?
        var rating: Int?
        var label: String?
    }

    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }

    /// JPEGs are patched in place (byte-preserving); everything else gets a sidecar.
    static func usesSidecar(_ url: URL) -> Bool { !["jpg", "jpeg"].contains(url.pathExtension.lowercased()) }

    /// Current GPS / rating / label of a file (for undo).
    static func read(_ url: URL) -> Previous {
        let target = usesSidecar(url) ? Sidecar.url(for: url) : url
        var p = Previous()
        if usesSidecar(url) {
            guard let d = try? Data(contentsOf: target), let m = CGImageMetadataCreateFromXMPData(d as CFData) else {
                return p
            }
            p.rating = (CGImageMetadataCopyStringValueWithPath(m, nil, "xmp:Rating" as CFString) as String?).flatMap { Int($0) }
            p.label = CGImageMetadataCopyStringValueWithPath(m, nil, "xmp:Label" as CFString) as String?
            p.gps = gpsFromXMP(m)
            return p
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return p }
        p.gps = Analyzer.metadata(url).gps
        if let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            p.rating = (CGImageMetadataCopyStringValueWithPath(m, nil, "xmp:Rating" as CFString) as String?).flatMap { Int($0) }
            p.label = CGImageMetadataCopyStringValueWithPath(m, nil, "xmp:Label" as CFString) as String?
        }
        return p
    }

    static func write(_ patch: Patch, to url: URL, sidecarBackupDir: URL) throws {
        if usesSidecar(url) {
            try writeSidecar(patch, raw: url, backupDir: sidecarBackupDir)
        } else {
            try JPEGPatcher.patch(url, patch)
        }
    }

    // MARK: Sidecar (RAW)

    private static func writeSidecar(_ patch: Patch, raw: URL, backupDir: URL) throws {
        let dest = Sidecar.url(for: raw)
        let fm = FileManager.default
        let meta: CGMutableImageMetadata
        if fm.fileExists(atPath: dest.path) {
            let data = try Data(contentsOf: dest)
            guard let parsed = CGImageMetadataCreateFromXMPData(data as CFData),
                  let m = CGImageMetadataCreateMutableCopy(parsed) else { throw CocoaError(.fileReadCorruptFile) }
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let backup = backupDir.appendingPathComponent(dest.lastPathComponent)
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: dest, to: backup) }
            meta = m
        } else {
            meta = CGImageMetadataCreateMutable()
        }
        apply(patch, to: meta)
        guard let xmp = CGImageMetadataCreateXMPData(meta, nil) as Data? else { throw CocoaError(.fileWriteUnknown) }
        try xmp.write(to: dest, options: .atomic)
    }

    // MARK: Shared

    private static let gpsKeys = ["GPSLatitude", "GPSLatitudeRef", "GPSLongitude", "GPSLongitudeRef",
                                  "GPSAltitude", "GPSAltitudeRef", "GPSVersionID"]

    static func apply(_ patch: Patch, to meta: CGMutableImageMetadata) {
        switch patch.gps {
        case .keep: break
        case .set(let g):
            // XMP exif schema: "DDD,MM.mmmmmK" with the hemisphere in the value (what Lightroom expects).
            for k in gpsKeys { CGImageMetadataRemoveTagWithPath(meta, nil, "exif:\(k)" as CFString) }
            func dm(_ v: Double, _ pos: String, _ neg: String) -> String {
                let a = abs(v), d = Int(a)
                return String(format: "%d,%.6f%@", d, (a - Double(d)) * 60, v >= 0 ? pos : neg)
            }
            CGImageMetadataSetValueWithPath(meta, nil, "exif:GPSVersionID" as CFString, "2.3.0.0" as CFString)
            CGImageMetadataSetValueWithPath(meta, nil, "exif:GPSLatitude" as CFString, dm(g.latitude, "N", "S") as CFString)
            CGImageMetadataSetValueWithPath(meta, nil, "exif:GPSLongitude" as CFString, dm(g.longitude, "E", "W") as CFString)
            if let alt = g.altitude {
                CGImageMetadataSetValueWithPath(meta, nil, "exif:GPSAltitude" as CFString, "\(Int((abs(alt) * 100).rounded()))/100" as CFString)
                CGImageMetadataSetValueWithPath(meta, nil, "exif:GPSAltitudeRef" as CFString, (alt >= 0 ? "0" : "1") as CFString)
            }
        case .remove:
            for k in gpsKeys { CGImageMetadataRemoveTagWithPath(meta, nil, "exif:\(k)" as CFString) }
        }
        if case .some(let r) = patch.rating {
            if let r { CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, r as CFNumber) }
            else { CGImageMetadataRemoveTagWithPath(meta, nil, "xmp:Rating" as CFString) }
        }
        if case .some(let l) = patch.label {
            if let l { CGImageMetadataSetValueWithPath(meta, nil, "xmp:Label" as CFString, l as CFString) }
            else { CGImageMetadataRemoveTagWithPath(meta, nil, "xmp:Label" as CFString) }
        }
        if let people = patch.people, !people.isEmpty {
            var subjects = Set(people)
            if let t = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString),
               let arr = CGImageMetadataTagCopyValue(t) as? [CGImageMetadataTag] {
                for x in arr { if let s = CGImageMetadataTagCopyValue(x) as? String { subjects.insert(s) } }
            }
            let ns = "http://purl.org/dc/elements/1.1/" as CFString
            let tags = subjects.sorted().compactMap { CGImageMetadataTagCreate(ns, "dc" as CFString, "subject" as CFString, .string, $0 as CFString) }
            if let bag = CGImageMetadataTagCreate(ns, "dc" as CFString, "subject" as CFString, .arrayUnordered, tags as CFArray) {
                CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, bag)
            }
        }
    }

    /// Parses exif:GPSLatitude "13,20.454N" style values from XMP.
    static func gpsFromXMP(_ m: CGImageMetadata) -> GeoPoint? {
        func coord(_ path: String) -> Double? {
            guard let s = CGImageMetadataCopyStringValueWithPath(m, nil, path as CFString) as String?, let last = s.last else { return nil }
            if last.isNumber {
                // Plain decimal (some writers) with a separate Ref tag.
                guard let v = Double(s) else { return nil }
                let ref = CGImageMetadataCopyStringValueWithPath(m, nil, (path + "Ref") as CFString) as String?
                return (ref == "S" || ref == "W") ? -abs(v) : v
            }
            let sign: Double = (last == "S" || last == "W") ? -1 : 1
            let parts = s.dropLast().split(separator: ",").compactMap { Double($0) }
            guard !parts.isEmpty else { return nil }
            let v = parts[0] + (parts.count > 1 ? parts[1] / 60 : 0) + (parts.count > 2 ? parts[2] / 3600 : 0)
            return sign * v
        }
        guard let lat = coord("exif:GPSLatitude"), let lon = coord("exif:GPSLongitude") else { return nil }
        return GeoPoint(latitude: lat, longitude: lon)
    }
}
