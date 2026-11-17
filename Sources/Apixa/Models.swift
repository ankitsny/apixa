import Foundation
import AppKit
import Observation
import Vision

let rawExtensions: Set<String> = [
    "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "dng",
    "orf", "rw2", "pef", "srw", "3fr", "iiq", "rwl", "x3f", "erf", "mrw"
]
let jpegExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff"]

enum Decision: String, Codable {
    case undecided, keep, reject
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case rate = "Rate"
    case adjust = "Adjust"
    case info = "Info"
    var id: String { rawValue }
}

enum ViewerBackground: String, CaseIterable, Identifiable {
    case auto = "Automatic", black = "Black", gray = "Gray", white = "White"
    var id: String { rawValue }
}

/// Space around the photo on the (static) background canvas when it's fitted to the window.
enum ViewerMargin: String, CaseIterable, Identifiable {
    case none = "None", small = "Small", large = "Large"
    var id: String { rawValue }
    var points: CGFloat { self == .none ? 0 : self == .small ? 28 : 72 }
}

enum CompareMode: String, CaseIterable, Identifiable {
    case off = "Off", sideBySide = "Side by Side", split = "Split"
    var id: String { rawValue }
}

enum TrashMode: String, CaseIterable, Identifiable {
    case both = "RAW + JPEG"
    case jpegOnly = "JPEG only"
    case rawOnly = "RAW only"
    var id: String { rawValue }
}

struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double? = nil
    var placeName: String? = nil
}

/// A detected face. `rect` is normalized with a bottom-left origin (Vision convention).
/// `personID`/`name` are reserved for face tagging & search (not built yet).
struct FaceRegion: Codable, Hashable, Sendable {
    var rect: CGRect
    var quality: Double?

    /// Stable identifier for naming (the rect is deterministic for a given analysis).
    var key: String { String(format: "%.3f,%.3f,%.3f,%.3f", rect.minX, rect.minY, rect.width, rect.height) }
}

/// Camera/exposure metadata shown in the Info tab.
struct ShotInfo: Codable, Hashable, Sendable {
    var camera: String?
    var lens: String?
    var focalLength: Double?
    var aperture: Double?
    var shutter: Double?
    var iso: Int?
    var width: Int?
    var height: Int?
}

/// One "shot": a JPEG and/or RAW file sharing the same base name in the same folder.
@Observable
final class PhotoAsset: Identifiable {
    let id = UUID()
    let baseName: String
    let folder: URL
    var jpegURL: URL?
    var rawURL: URL?
    var captureDate: Date

    var thumbnail: NSImage? = nil
    @ObservationIgnored var featurePrint: VNFeaturePrintObservation?

    // Measured metrics
    var sharpness: Double = 0        // Laplacian variance (best tiles)
    var meanLuma: Double = 0.5
    var highlightClip: Double = 0    // fraction of pixels blown out
    var shadowClip: Double = 0       // fraction of pixels crushed
    var faceQuality: Double? = nil   // 0...1, nil if no faces
    var faceSharpness: Double? = nil // sharpness measured on the largest face, nil if no faces
    var aesthetic: Double? = nil     // -1...1
    var metricsSource = MetricsSource.preview
    var sensorClip = false           // highlightClip measured on linear RAW data
    var faces: [FaceRegion] = []
    @ObservationIgnored var facePrints: [VNFeaturePrintObservation?] = []   // per face, for "who is this" suggestions
    var info: ShotInfo? = nil
    var embeddedLocation: GeoPoint? = nil   // GPS already in the file
    var analyzed = false

    // Derived (computed per stack)
    var sharpnessScore: Double = 0
    var score: Double = 0
    var stars: Int = 0
    var isBest = false
    var ratingDetail = RatingDetail()

    // User state — saved in Apixa's library, never written into the photo files.
    var decision: Decision = .undecided
    var userRating: Int? = nil              // 1...5; nil = use the automatic rating
    var location: GeoPoint? = nil           // user-assigned; overrides embeddedLocation
    var adjustments = Adjustments()
    var faceNames: [String: String] = [:]   // FaceRegion.key → person name
    /// Each file's metadata before Apixa first wrote to it (file name → values), so undo can restore it.
    var fileBaseline: [String: MetadataWriter.Previous] = [:]

    init(item: ScannedItem) {
        baseName = item.baseName
        folder = item.folder
        jpegURL = item.jpeg
        rawURL = item.raw
        captureDate = item.fileDate
    }

    var displayURL: URL { jpegURL ?? rawURL ?? folder }
    var isRawOnly: Bool { jpegURL == nil && rawURL != nil }
    var isPair: Bool { jpegURL != nil && rawURL != nil }
    var allURLs: [URL] { [jpegURL, rawURL].compactMap { $0 } }

    var displayStars: Int { userRating ?? stars }
    var effectiveLocation: GeoPoint? { location ?? embeddedLocation }

    var isBlurry: Bool { analyzed && Self.absoluteSharpness(sharpness) < 0.6 }

    static func absoluteSharpness(_ v: Double) -> Double {
        min(1, log10(1 + max(0, v)) / 3.0)
    }

    var exposureScore: Double { Self.exposureScore(mean: meanLuma, highClip: highlightClip, shadowClip: shadowClip) }

    static func exposureScore(mean: Double, highClip: Double, shadowClip: Double) -> Double {
        let meanPenalty = min(1, max(0, abs(mean - 0.45) - 0.1) / 0.3)
        let clipPenalty = min(1, highClip * 10 + max(0, shadowClip - 0.05) * 5)
        return max(0, 1 - 0.7 * meanPenalty - 0.5 * clipPenalty)
    }

    var exposureNote: String? {
        if highlightClip > 0.04 {
            return (sensorClip ? "Sensor clipped" : "Highlights clipped") + " (\(Int(highlightClip * 100))%)"
        }
        if shadowClip > 0.15 { return "Shadows crushed (\(Int(shadowClip * 100))%)" }
        if meanLuma < 0.2 { return "Underexposed" }
        if meanLuma > 0.75 { return "Overexposed" }
        return nil
    }

    func apply(_ r: AnalysisResult) {
        if let d = r.date { captureDate = d }
        if let t = r.thumb { thumbnail = NSImage(cgImage: t, size: NSSize(width: t.width, height: t.height)) }
        featurePrint = r.featurePrint
        sharpness = r.sharpness
        meanLuma = r.meanLuma
        highlightClip = r.highClip
        shadowClip = r.shadowClip
        faceQuality = r.faceQuality
        faceSharpness = r.faceSharpness
        aesthetic = r.aesthetic
        metricsSource = r.source
        sensorClip = r.sensorClip
        faces = r.faces
        info = r.info
        embeddedLocation = r.gps
        analyzed = true
    }

    /// The user-editable part, for undo and persistence.
    var userState: UserState {
        get { UserState(decision: decision, userRating: userRating, location: location, adjustments: adjustments,
                        faceNames: faceNames, fileBaseline: fileBaseline) }
        set {
            decision = newValue.decision
            userRating = newValue.userRating
            location = newValue.location
            adjustments = newValue.adjustments
            faceNames = newValue.faceNames
            fileBaseline = newValue.fileBaseline
        }
    }

    func name(of face: FaceRegion) -> String? { faceNames[face.key] }
}

struct UserState: Codable, Equatable {
    var decision: Decision = .undecided
    var userRating: Int? = nil
    var location: GeoPoint? = nil
    var adjustments = Adjustments()
    var faceNames: [String: String] = [:]
    var fileBaseline: [String: MetadataWriter.Previous] = [:]

    var isDefault: Bool { self == UserState() }

    init(decision: Decision = .undecided, userRating: Int? = nil, location: GeoPoint? = nil,
         adjustments: Adjustments = Adjustments(), faceNames: [String: String] = [:],
         fileBaseline: [String: MetadataWriter.Previous] = [:]) {
        self.decision = decision; self.userRating = userRating; self.location = location
        self.adjustments = adjustments; self.faceNames = faceNames; self.fileBaseline = fileBaseline
    }

    // Tolerant decoding: fields added later default instead of failing the whole library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decision = (try? c.decodeIfPresent(Decision.self, forKey: .decision)) ?? .undecided
        userRating = try? c.decodeIfPresent(Int.self, forKey: .userRating)
        location = try? c.decodeIfPresent(GeoPoint.self, forKey: .location)
        adjustments = (try? c.decodeIfPresent(Adjustments.self, forKey: .adjustments)) ?? Adjustments()
        faceNames = (try? c.decodeIfPresent([String: String].self, forKey: .faceNames)) ?? [:]
        fileBaseline = (try? c.decodeIfPresent([String: MetadataWriter.Previous].self, forKey: .fileBaseline)) ?? [:]
    }
}

struct PhotoStack: Identifiable {
    let members: [PhotoAsset]
    var id: UUID { members[0].id }
    var best: PhotoAsset? { members.first(where: { $0.isBest }) }
    var cover: PhotoAsset { best ?? members[0] }
    var start: Date { members[0].captureDate }
}

// MARK: - Edits

struct CurvePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

enum CurveChannel: String, CaseIterable, Identifiable, Codable {
    case master = "RGB", red = "Red", green = "Green", blue = "Blue"
    var id: String { rawValue }
}

struct Curves: Codable, Hashable, Sendable {
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    var master = Curves.identity
    var red = Curves.identity
    var green = Curves.identity
    var blue = Curves.identity

    subscript(_ c: CurveChannel) -> [CurvePoint] {
        get {
            switch c {
            case .master: master
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch c {
            case .master: master = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    var isIdentity: Bool { self == Curves() }
}

/// Non-destructive edit settings. All zero = untouched. RAW files apply exposure, white balance, contrast,
/// tone mapping, noise reduction and sharpening inside the RAW 9 decoder (relative to the camera's
/// as-shot defaults); JPEGs use equivalent Core Image filters. Everything else is shared.
struct Adjustments: Hashable, Sendable {
    var exposure = 0.0       // EV, -5...5
    var contrast = 0.0       // -1...1
    var highlights = 0.0     // -1 (recover) ... +1 (brighten)
    var shadows = 0.0        // -1 (deepen) ... +1 (lift)
    var whites = 0.0         // -1...1
    var blacks = 0.0         // -1...1
    var toneMapping = 0.0    // -1...1 local tone mapping (RAW only; relative to default)
    var temperature = 0.0    // Kelvin offset, -3000...3000
    var tint = 0.0           // -100...100
    var vibrance = 0.0       // -1...1
    var saturation = 0.0     // -1...1
    var noiseReduction = 0.0 // 0...1
    var strongNoise = 0.0    // 0...1 extra denoise pass after the decoder
    var colorNoise = 0.0     // 0...1 chroma-only smoothing
    var sharpening = 0.0     // 0...1
    var curves = Curves()
    var angle = 0.0          // straighten, degrees -45...45 (positive = clockwise)
    var crop: CropRect? = nil
    var look: LookRecipe? = nil   // Creative Look, applied after your edits
    /// Set while Auto is (or was) applied: what Auto set, and what it replaced.
    var auto: AutoEdit? = nil

    var isIdentity: Bool { var c = self; c.auto = nil; return c == Adjustments() }

    /// The tone and colour sliders Auto controls.
    var tone: ToneSet {
        get { ToneSet(exposure: exposure, contrast: contrast, highlights: highlights, shadows: shadows, whites: whites,
                      blacks: blacks, vibrance: vibrance, saturation: saturation, curves: curves) }
        set {
            exposure = newValue.exposure; contrast = newValue.contrast; highlights = newValue.highlights
            shadows = newValue.shadows; whites = newValue.whites; blacks = newValue.blacks
            vibrance = newValue.vibrance; saturation = newValue.saturation; curves = newValue.curves
        }
    }

    /// Auto is in effect only while those sliders still hold exactly what Auto set.
    var isAutoOn: Bool { auto?.applied == tone }
}

struct ToneSet: Codable, Hashable, Sendable {
    var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    var vibrance = 0.0, saturation = 0.0
    var curves = Curves()
}

struct AutoEdit: Codable, Hashable, Sendable {
    var applied: ToneSet
    var previous: ToneSet
}

/// Normalized crop (top-left origin) within the straightened image.
struct CropRect: Codable, Hashable, Sendable {
    var x = 0.0, y = 0.0, w = 1.0, h = 1.0
    static let full = CropRect()
}

extension Adjustments: Codable {
    // Every key optional, so libraries saved by older versions keep loading as fields are added.
    private enum K: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, toneMapping, temperature, tint,
             vibrance, saturation, noiseReduction, sharpening, curves, angle, crop, look, strongNoise, colorNoise, auto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func d(_ k: K) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? 0 }
        exposure = d(.exposure); contrast = d(.contrast); highlights = d(.highlights); shadows = d(.shadows)
        whites = d(.whites); blacks = d(.blacks); toneMapping = d(.toneMapping); temperature = d(.temperature)
        tint = d(.tint); vibrance = d(.vibrance); saturation = d(.saturation)
        noiseReduction = d(.noiseReduction); sharpening = d(.sharpening); angle = d(.angle)
        strongNoise = d(.strongNoise); colorNoise = d(.colorNoise)
        curves = (try? c.decodeIfPresent(Curves.self, forKey: .curves)) ?? Curves()
        crop = try? c.decodeIfPresent(CropRect.self, forKey: .crop)
        look = try? c.decodeIfPresent(LookRecipe.self, forKey: .look)
        auto = try? c.decodeIfPresent(AutoEdit.self, forKey: .auto)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        let pairs: [(K, Double)] = [(.exposure, exposure), (.contrast, contrast), (.highlights, highlights),
                                    (.shadows, shadows), (.whites, whites), (.blacks, blacks),
                                    (.toneMapping, toneMapping), (.temperature, temperature), (.tint, tint),
                                    (.vibrance, vibrance), (.saturation, saturation),
                                    (.noiseReduction, noiseReduction), (.sharpening, sharpening), (.angle, angle),
                                    (.strongNoise, strongNoise), (.colorNoise, colorNoise)]
        for (k, v) in pairs where v != 0 { try c.encode(v, forKey: k) }
        if !curves.isIdentity { try c.encode(curves, forKey: .curves) }
        if let crop { try c.encode(crop, forKey: .crop) }
        if let look { try c.encode(look, forKey: .look) }
        if let auto { try c.encode(auto, forKey: .auto) }
    }
}
