import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// HDR display: highlights above SDR white shown with real brightness on screens that can (XDR, HDR monitors).
///
/// The developed image is split into the SDR picture (clipped at white in Display P3, exactly what the SDR
/// render shows) and a per-pixel brightness gain (≥ 1, only in the highlights). Edits and looks run on the
/// SDR picture; the gain goes back on at the end. Below white the two renders are identical.
enum HDR {
    /// Highest value the RAW decoder produces with HDR on (≈ 1 stop above white) plus margin.
    static let contentHeadroom: Float = 2

    private static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    /// Display P3 luminance weights (linear).
    private static let lum = CIVector(x: 0.2290, y: 0.6917, z: 0.0793, w: 0)

    /// Does any screen show more than SDR white right now (or could it, e.g. XDR at lower brightness)?
    @MainActor static var screenSupportsHDR: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 }
    }

    /// (SDR picture, the HDR original). The SDR picture is the input clipped at white per Display P3 channel,
    /// exactly what an SDR render shows.
    static func split(_ hdr: CIImage) -> (CIImage, CIImage) {
        let p3 = hdr.matchedFromWorkingSpace(to: linearP3) ?? hdr
        let clip = CIFilter.colorClamp()
        clip.inputImage = p3
        clip.minComponents = CIVector(x: -1000, y: -1000, z: -1000, w: 0)   // keep wide-gamut (negative) values
        clip.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let sdrP3 = clip.outputImage ?? p3
        let sdr = sdrP3.matchedToWorkingSpace(from: linearP3) ?? sdrP3
        return (sdr.cropped(to: hdr.extent), hdr)
    }

    /// Gain-map style restore: edited × Y(hdr) / Y(sdr), capped at the headroom. 1 below white, so edits and
    /// looks are untouched there; above white the look's colour is kept and brightened.
    /// (Core Image's Divide blend clamps to 1, hence a kernel: Kernels/ApixaKernels.ci.metal, built by build.sh.)
    private static let restoreKernel: CIColorKernel? = {
        guard let data = Kernels.library else { return nil }
        return try? CIColorKernel(functionName: "apixaRestoreHDR", fromMetalLibraryData: data)
    }()

    /// Put the highlights' brightness back on the edited SDR picture.
    static func restore(_ edited: CIImage, hdr: CIImage, sdr: CIImage) -> CIImage {
        guard let k = restoreKernel,
              let out = k.apply(extent: edited.extent, arguments: [edited, hdr, sdr, contentHeadroom]) else {
            Kernels.warnMissing()
            return edited
        }
        return out
    }

    /// Half-float, extended linear Display P3, tagged with its headroom so Core Animation shows it as HDR.
    static func makeImage(_ img: CIImage) -> CGImage? {
        guard let cg = RAWDecoder.context.createCGImage(img, from: img.extent.integralInward, format: .RGBAh, colorSpace: linearP3)
        else { return nil }
        return CGImageCreateCopyWithContentHeadroom(contentHeadroom, cg) ?? cg
    }

    static func isHDR(_ cg: CGImage?) -> Bool { (cg?.contentHeadroom ?? 0) > 1 }
}

/// Apixa's compiled Core Image kernels (ApixaKernels.metallib): in the app's Resources, or next to the
/// executable for command-line runs from .build.
enum Kernels {
    static let library: Data? = {
        let name = "ApixaKernels.metallib"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)]
        return candidates.compactMap { $0 }.lazy.compactMap { try? Data(contentsOf: $0) }.first
    }()

    nonisolated(unsafe) private static var warned = false
    static func warnMissing() {
        guard !warned else { return }
        warned = true
        FileHandle.standardError.write("Apixa: ApixaKernels.metallib not found or invalid; HDR highlights are shown as SDR. Build with ./build.sh.\n".data(using: .utf8)!)
    }
}
