// Core Image kernels for Apixa, compiled by build.sh into ApixaKernels.metallib.
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

// HDR gain-map restore: edited × Y(hdr) / Y(sdr), clamped to [1, cap].
// 1 wherever the photo is at or below white, so edits and looks are untouched there.
float4 apixaRestoreHDR(sample_t edited, sample_t hdr, sample_t sdr, float cap) {
    const float3 w = float3(0.2126, 0.7152, 0.0722);
    float yh = dot(max(hdr.rgb, float3(0.0)), w);
    float ys = dot(max(sdr.rgb, float3(0.0)), w);
    float g = clamp(yh / max(ys, 0.0001), 1.0, cap);
    return float4(edited.rgb * g, edited.a);
}

}
}
