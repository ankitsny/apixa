import Foundation
import ImageIO

/// In-place JPEG metadata patching that preserves every original byte it doesn't need to change.
///
/// ImageIO's lossless copy rebuilds EXIF and drops maker notes (lens/focus data), so instead:
/// - GPS: a new GPS IFD and a copy of IFD0 (with the GPSInfo pointer added/removed) are APPENDED to the
///   EXIF TIFF block and the header is re-pointed at the new IFD0. Nothing moves, so every existing offset
///   (maker notes, thumbnail, sub-IFDs) stays valid. A block Apixa appended earlier is reused, not stacked.
/// - Rating / label / people: only the XMP APP1 segment is replaced.
/// - Image data, MPF previews and all other segments are copied verbatim.
enum JPEGPatcher {
    enum PatchError: Error { case notJPEG, malformed, tooLarge }

    static func patch(_ url: URL, _ p: MetadataWriter.Patch) throws {
        let data = try Data(contentsOf: url)
        let out = try patched(data, p)
        // Sanity check before touching the original: must decode, and image data must be identical.
        guard let src = CGImageSourceCreateWithData(out as CFData, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceCopyPropertiesAtIndex(src, 0, nil) != nil,
              try scanData(out) == scanData(data) else { throw PatchError.malformed }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).apixa-tmp.\(url.pathExtension)")
        try out.write(to: tmp, options: .atomic)
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        if let created { try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
    }

    // MARK: Segments

    private struct Segment { let marker: UInt8; let range: Range<Int> }   // range covers FF xx + length + payload

    private static let exifID = Data("Exif\0\0".utf8)
    private static let xmpID = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

    private static func segments(_ d: Data) throws -> (segs: [Segment], sos: Int) {
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { throw PatchError.notJPEG }
        var i = 2, segs: [Segment] = []
        while i + 4 <= d.count {
            guard d[i] == 0xFF else { throw PatchError.malformed }
            let m = d[i + 1]
            if m == 0xDA { return (segs, i) }
            let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard len >= 2, i + 2 + len <= d.count else { throw PatchError.malformed }
            segs.append(Segment(marker: m, range: i..<(i + 2 + len)))
            i += 2 + len
        }
        throw PatchError.malformed
    }

    /// Everything from start-of-scan to the end (image data + MPF previews) — must be untouched.
    private static func scanData(_ d: Data) throws -> Data {
        let s = try segments(d)
        return d.subdata(in: s.sos..<d.count)
    }

    private static func payload(_ d: Data, _ s: Segment) -> Data { d.subdata(in: (s.range.lowerBound + 4)..<s.range.upperBound) }

    private static func segment(_ marker: UInt8, _ payload: Data) throws -> Data {
        guard payload.count + 2 <= 0xFFFF else { throw PatchError.tooLarge }
        var s = Data([0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)])
        s.append(payload)
        return s
    }

    static func patched(_ d: Data, _ p: MetadataWriter.Patch) throws -> Data {
        let (segs, sos) = try segments(d)
        let exifSeg = segs.first { $0.marker == 0xE1 && payload(d, $0).starts(with: exifID) }
        let xmpSeg = segs.first { $0.marker == 0xE1 && payload(d, $0).starts(with: xmpID) }

        var newExif: Data?
        switch p.gps {
        case .keep: break
        case .set, .remove:
            let tiff = exifSeg.map { payload(d, $0).dropFirst(exifID.count) }.map { Data($0) } ?? minimalTIFF()
            let point: GeoPoint? = { if case .set(let g) = p.gps { return g } else { return nil } }()
            newExif = try segment(0xE1, exifID + (try TIFF.settingGPS(tiff, point)))
        }

        var newXMP: Data?
        let touchesXMP: Bool = {
            if case .some = p.rating { return true }
            if case .some = p.label { return true }
            if p.people != nil { return true }
            if case .keep = p.gps { return false }
            return xmpSeg != nil   // keep any GPS already in XMP consistent
        }()
        if touchesXMP {
            let existing = xmpSeg.map { payload(d, $0).dropFirst(xmpID.count) }.map { Data($0) }
            let meta: CGMutableImageMetadata = existing
                .flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
                .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            MetadataWriter.apply(p, to: meta)
            guard let xmp = CGImageMetadataCreateXMPData(meta, nil) as Data? else { throw PatchError.malformed }
            newXMP = try segment(0xE1, xmpID + xmp)
        }

        // Reassemble: replace in place, or insert after the leading APP0/APP1 block.
        var out = Data([0xFF, 0xD8])
        var insertedExif = newExif == nil || exifSeg != nil
        var insertedXMP = newXMP == nil || xmpSeg != nil
        for (i, s) in segs.enumerated() {
            if let e = exifSeg, s.range == e.range, let n = newExif { out.append(n); continue }
            if let x = xmpSeg, s.range == x.range, let n = newXMP { out.append(n); continue }
            out.append(d.subdata(in: s.range))
            let next = i + 1 < segs.count ? segs[i + 1].marker : 0
            let leading = s.marker == 0xE0 || s.marker == 0xE1
            if leading && !(next == 0xE0 || next == 0xE1) {
                if !insertedExif, let n = newExif { out.append(n); insertedExif = true }
                if !insertedXMP, let n = newXMP { out.append(n); insertedXMP = true }
            }
        }
        if !insertedExif || !insertedXMP {
            // No APP0/APP1 at all: put them right after SOI.
            var head = Data([0xFF, 0xD8])
            if !insertedExif, let n = newExif { head.append(n) }
            if !insertedXMP, let n = newXMP { head.append(n) }
            out = head + out.dropFirst(2)
        }
        out.append(d.subdata(in: sos..<d.count))
        return out
    }

    private static func minimalTIFF() -> Data {
        // "II", 42, IFD0 at 8, zero entries, next IFD 0.
        Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }
}

/// Minimal TIFF structure editing for the EXIF block.
enum TIFF {
    private struct Reader {
        let d: Data
        let le: Bool
        func u16(_ o: Int) -> Int { le ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ o: Int) -> Int {
            le ? Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
               : Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
        }
    }

    private struct Writer {
        var d = Data()
        let le: Bool
        mutating func u16(_ v: Int) { d.append(contentsOf: le ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] : [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        mutating func u32(_ v: Int) {
            let b = [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
            d.append(contentsOf: le ? b : b.reversed())
        }
    }

    private struct Entry { let tag: Int; let raw: Data }   // the 12 bytes, verbatim

    static let gpsInfoTag = 0x8825

    /// Returns the TIFF block with GPS set (or removed when `point` is nil). Appends only.
    static func settingGPS(_ input: Data, _ point: GeoPoint?) throws -> Data {
        var t = Data(input)
        guard t.count >= 8 else { throw JPEGPatcher.PatchError.malformed }
        let le = t[0] == 0x49
        guard le || t[0] == 0x4D else { throw JPEGPatcher.PatchError.malformed }
        let r = Reader(d: t, le: le)
        let ifd0 = r.u32(4)
        guard ifd0 + 2 <= t.count else { throw JPEGPatcher.PatchError.malformed }
        let n = r.u16(ifd0)
        let ifdEnd = ifd0 + 2 + n * 12 + 4
        guard ifdEnd <= t.count else { throw JPEGPatcher.PatchError.malformed }
        var entries: [Entry] = (0..<n).map { i in
            let o = ifd0 + 2 + i * 12
            return Entry(tag: r.u16(o), raw: t.subdata(in: o..<(o + 12)))
        }
        let nextIFD = r.u32(ifd0 + 2 + n * 12)
        let oldGPS = entries.first { $0.tag == gpsInfoTag }.map { Reader(d: $0.raw, le: le).u32(8) }

        // If the current IFD0 is a block Apixa appended earlier (it ends the TIFF, preceded by our GPS IFD),
        // drop that block instead of stacking another one.
        if ifd0 > 8 && ifdEnd == t.count {
            let cut = oldGPS.map { $0 < ifd0 && $0 > 8 ? $0 : ifd0 } ?? ifd0
            t = t.prefix(cut)
        }
        entries.removeAll { $0.tag == gpsInfoTag }

        var w = Writer(d: t, le: le)
        if w.d.count % 2 == 1 { w.d.append(0) }

        if let g = point {
            let gpsOff = w.d.count
            let lat = dms(abs(g.latitude)), lon = dms(abs(g.longitude))
            var tags: [(tag: Int, type: Int, count: Int, inline: [UInt8]?, data: [Int]?)] = [
                (0x0000, 1, 4, [2, 3, 0, 0], nil),
                (0x0001, 2, 2, [g.latitude >= 0 ? 0x4E : 0x53, 0, 0, 0], nil),
                (0x0002, 5, 3, nil, lat),
                (0x0003, 2, 2, [g.longitude >= 0 ? 0x45 : 0x57, 0, 0, 0], nil),
                (0x0004, 5, 3, nil, lon),
            ]
            if let alt = g.altitude {
                tags.append((0x0005, 1, 1, [alt >= 0 ? 0 : 1, 0, 0, 0], nil))
                tags.append((0x0006, 5, 1, nil, [Int((abs(alt) * 100).rounded()), 100]))
            }
            var dataOff = gpsOff + 2 + tags.count * 12 + 4
            var blob = Writer(le: le)
            w.u16(tags.count)
            for t in tags {
                w.u16(t.tag); w.u16(t.type); w.u32(t.count)
                if let inline = t.inline {
                    w.d.append(contentsOf: inline)
                } else if let vals = t.data {
                    w.u32(dataOff)
                    for v in vals { blob.u32(v) }
                    dataOff += vals.count * 4
                }
            }
            w.u32(0)
            w.d.append(blob.d)
            var e = Writer(le: le)
            e.u16(gpsInfoTag); e.u16(4); e.u32(1); e.u32(gpsOff)
            entries.append(Entry(tag: gpsInfoTag, raw: e.d))
        }

        if w.d.count % 2 == 1 { w.d.append(0) }
        let newIFD0 = w.d.count
        entries.sort { $0.tag < $1.tag }
        w.u16(entries.count)
        for e in entries { w.d.append(e.raw) }
        w.u32(nextIFD)
        // Re-point the header at the new IFD0.
        var h = Writer(le: le)
        h.u32(newIFD0)
        w.d.replaceSubrange(4..<8, with: h.d)
        return w.d
    }

    /// Degrees, minutes, seconds as three RATIONALs (seconds with 1/10000 precision).
    private static func dms(_ v: Double) -> [Int] {
        let deg = Int(v)
        let minF = (v - Double(deg)) * 60
        let min = Int(minF)
        let sec = Int(((minF - Double(min)) * 60 * 10000).rounded())
        return [deg, 1, min, 1, sec, 10000]
    }
}
