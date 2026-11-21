// Out-of-line members of krkrsdl3::iTVPRenderBackend for test binaries that
// do not link TVPCompositor.cpp (it pulls in the whole texture registry).
// DrawQuads is the class's key function, so its vtable is emitted here.
// Keep in sync with iTVPRenderBackend::DrawQuads in core/render/TVPCompositor.cpp.
#include "TVPCompositor.h"
#include <cstddef>
#include <cstdint>

namespace krkrsdl3 {

void iTVPRenderBackend::DrawQuads(void* texture, const float* vertices, int quadCount,
                                  const uint16_t* indices, int indexCount)
{
    if (!vertices || quadCount <= 0)
        return;
    const float opacity = GetBlendOpacity();
    const float* modulation = GetBlendModulation();
    const uint16_t defaultIdx[6] = {0, 1, 2, 2, 3, 0};
    const uint16_t* idx = indices && indexCount > 0 ? indices : defaultIdx;
    const int nIdx = indices && indexCount > 0 ? indexCount : 6;
    for (int q = 0; q < quadCount; ++q)
        DrawMesh(vertices + (size_t)q * 16, 4, idx, nIdx, texture, opacity, modulation);
}

} // namespace krkrsdl3
