import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Apixa's own storage for an opened folder. Nothing here is ever written into the photo folder:
///
///   ~/Library/Application Support/Apixa/Libraries/<hash of folder path>/
///       folder.txt      the folder path (for humans)
///       analysis.plist  cached analysis, reused while a file's size + modification date are unchanged
///       state.json      marks, ratings, locations and edits
struct LibraryDB: Sendable {
    let folder: URL
    let dir: URL

    init(folder: URL) {
        self.folder = folder
        let hash = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Apixa/Libraries/\(hash)", isDirectory: true)
    }

    private var analysisURL: URL { dir.appendingPathComponent("analysis.plist") }
    private var stateURL: URL { dir.appendingPathComponent("state.json") }

    /// Stable key for a shot: path relative to the opened folder + base name (case-insensitive).
    func key(folder shotFolder: URL, baseName: String) -> String {
        let root = folder.standardizedFileURL.path
        var rel = shotFolder.standardizedFileURL.path
        if rel.hasPrefix(root) { rel = String(rel.dropFirst(root.count)) }
        return (rel + "/" + baseName).lowercased()
    }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? folder.path.write(to: dir.appendingPathComponent("folder.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: State

    func loadState() -> [String: UserState] {
        guard let data = try? Data(contentsOf: stateURL),
              let file = try? JSONDecoder().decode(StateFile.self, from: data) else { return [:] }
        return file.shots
    }

    func saveState(_ shots: [String: UserState]) {
        ensureDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(StateFile(version: 1, shots: shots.filter { !$0.value.isDefault })) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: Analysis cache

    func loadAnalysis() -> [String: CachedAnalysis] {
        guard let data = try? Data(contentsOf: analysisURL),
              let file = try? PropertyListDecoder().decode(AnalysisFile.self, from: data),
              file.version == AnalysisFile.currentVersion else { return [:] }
        return file.entries
    }

    func saveAnalysis(_ entries: [String: CachedAnalysis]) {
        ensureDir()
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let data = try? enc.encode(AnalysisFile(version: AnalysisFile.currentVersion, entries: entries)) {
            try? data.write(to: analysisURL, options: .atomic)
        }
    }

    /// Size + modification date of each file of a shot. A changed file invalidates the cached analysis.
    static func signature(_ urls: [URL]) -> [String: FileSignature] {
        var out: [String: FileSignature] = [:]
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            out[u.lastPathComponent] = FileSignature(size: Int64(v.fileSize ?? 0),
                                                     mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }
}

private struct StateFile: Codable {
    var version: Int
    var shots: [String: UserState]
}

private struct AnalysisFile: Codable {
    static let currentVersion = 1
    var version: Int
    var entries: [String: CachedAnalysis]
}

struct FileSignature: Codable, Hashable, Sendable {
    var size: Int64
    var mtime: Double
}

/// Serializable form of `AnalysisResult` (thumbnail as JPEG, feature print via NSSecureCoding).
struct CachedAnalysis: Codable, @unchecked Sendable {
    var signature: [String: FileSignature]
    var date: Date?
    var source: MetricsSource
    var sensorClip: Bool
    var sharpness: Double
    var meanLuma: Double
    var highClip: Double
    var shadowClip: Double
    var faceQuality: Double?
    var aesthetic: Double?
    var faces: [FaceRegion]
    var info: ShotInfo?
    var gps: GeoPoint?
    var thumbJPEG: Data?
    var featurePrint: Data?
    var facePrints: [Data]? = nil   // per face; empty Data = no print
    var faceSharpness: Double? = nil

    init(_ r: AnalysisResult, signature: [String: FileSignature]) {
        self.signature = signature
        date = r.date; source = r.source; sensorClip = r.sensorClip
        sharpness = r.sharpness; meanLuma = r.meanLuma; highClip = r.highClip; shadowClip = r.shadowClip
        faceQuality = r.faceQuality; aesthetic = r.aesthetic; faces = r.faces; info = r.info; gps = r.gps
        faceSharpness = r.faceSharpness
        thumbJPEG = r.thumb.flatMap(Self.jpeg)
        featurePrint = r.featurePrint.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    var result: AnalysisResult {
        var r = AnalysisResult()
        r.date = date; r.source = source; r.sensorClip = sensorClip
        r.sharpness = sharpness; r.meanLuma = meanLuma; r.highClip = highClip; r.shadowClip = shadowClip
        r.faceQuality = faceQuality; r.aesthetic = aesthetic; r.faces = faces; r.info = info; r.gps = gps
        r.faceSharpness = faceSharpness
        if let d = thumbJPEG, let src = CGImageSourceCreateWithData(d as CFData, nil) {
            r.thumb = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if let d = featurePrint {
            r.featurePrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d)
        }
        return r
    }

    private static func jpeg(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(d) ? data as Data : nil
    }
}
