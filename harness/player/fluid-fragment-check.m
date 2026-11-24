#import <Metal/Metal.h>
#import <simd/simd.h>
#import "../harness-fail.h"
#import "current.inc"
#import "reference.inc"

typedef struct {
    simd_float4 visible;
    simd_float2 aspect;
    float time, warp, progress, flows, grain;
} Uniforms;

static id<MTLRenderPipelineState> pipeline(id<MTLDevice> gpu, NSString *shader) {
    NSError *error = nil;
    id<MTLLibrary> lib = [gpu newLibraryWithSource:shader options:nil error:&error];
    if (!lib) HARNESS_FAIL(@"shader: %@", error);
    MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
    p.vertexFunction = [lib newFunctionWithName:@"fluidVertex"];
    p.fragmentFunction = [lib newFunctionWithName:@"fluidFragment"];
    p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> result = [gpu newRenderPipelineStateWithDescriptor:p error:&error];
    if (!result) HARNESS_FAIL(@"pipeline: %@", error);
    return result;
}

static id<MTLTexture> cover(id<MTLDevice> gpu, unsigned seed) {
    uint32_t pixels[19][23];
    for (unsigned i = 0; i < 19; i++) for (unsigned j = 0; j < 23; j++) {
        seed = 1664525u * seed + 1013904223u;
        pixels[i][j] = seed | 0xff000000;
    }
    id<MTLTexture> texture = [gpu newTextureWithDescriptor:
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:23 height:19 mipmapped:NO]];
    [texture replaceRegion:MTLRegionMake2D(0, 0, 23, 19) mipmapLevel:0 withBytes:pixels bytesPerRow:sizeof(pixels[0])];
    return texture;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
    HARNESS_CHECK(gpu);
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    id<MTLTexture> from = cover(gpu, 1), to = cover(gpu, 98765);
    const NSUInteger width = 88, height = 124;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [gpu newTextureWithDescriptor:td];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
    id<MTLSamplerState> sampler = [gpu newSamplerStateWithDescriptor:sd];
    NSData *(^draw)(id<MTLRenderPipelineState>, Uniforms) = ^NSData *(id<MTLRenderPipelineState> p, Uniforms u) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:p];
        // Deliberately keep the covers distinct even at settlement to catch a read of slot zero.
        [encoder setFragmentTexture:from atIndex:0];
        [encoder setFragmentTexture:to atIndex:1];
        [encoder setFragmentSamplerState:sampler atIndex:0];
        [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        HARNESS_CHECK(cmd.status == MTLCommandBufferStatusCompleted);
        NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
        [target getBytes:pixels.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        return pixels;
    };
    id<MTLRenderPipelineState> original = pipeline(gpu, referenceShader), current = pipeline(gpu, kShader);
    // Derive the oracle from the pinned shader, not the branch under test. Keep its warp and
    // grain, replacing the whole transition with the single unbent destination sample.
    NSRange blend = [referenceShader rangeOfString:@"    float wave ="];
    NSRange grain = [referenceShader rangeOfString:@"    uint2 ip ="];
    HARNESS_CHECK(blend.location != NSNotFound && grain.location > blend.location && grain.location != NSNotFound);
    NSString *destinationShader = [referenceShader stringByReplacingCharactersInRange:
        NSMakeRange(blend.location, grain.location - blend.location)
        // Round the sample to float before the shared grain pass, as at the branch merge.
        // Otherwise a standalone kernel is free to reassociate the cubic sum with the grain.
        withString:@"    volatile float3 c = smoothRead(to, s, r * ZOOM + 0.5).rgb;\n"];
    id<MTLRenderPipelineState> destination = pipeline(gpu, destinationShader);
    // Instrument the actual uniform branch, separately from the byte-for-byte image comparison.
    NSString *probe = [kShader stringByReplacingOccurrencesOfString:@"fragment float4 fluidFragment"
        withString:@"#define smoothRead(...) (++reads, smoothRead(__VA_ARGS__))\nfragment float4 fluidFragment"];
    probe = [probe stringByReplacingOccurrencesOfString:@"float2 p = (in.uv" withString:@"uint reads = 0; float2 p = (in.uv"];
    probe = [probe stringByReplacingOccurrencesOfString:@"return float4(c +" withString:@"return float4(reads / 255.0); return float4(c +"];
    id<MTLRenderPipelineState> budget = pipeline(gpu, probe);
    for (NSNumber *progress in @[@0, @0.43, @1]) for (NSNumber *flow in @[@0, @1]) {
        Uniforms u = {{0.13, 0.28, 0.72, 0.40}, {0.78, 1}, 16.25, 1.18, progress.floatValue, flow.floatValue, 5};
        NSData *before = draw(original, u), *after = draw(current, u);
        BOOL settled = u.progress == 1;
        unsigned maxDelta = 0;
        for (NSUInteger i = 0; i < before.length; i++) {
            unsigned d = abs(((const uint8_t *)before.bytes)[i] - ((const uint8_t *)after.bytes)[i]);
            maxDelta = MAX(maxDelta, d);
        }
        if (maxDelta > (settled ? 1 : 0))
            HARNESS_FAIL(@"progress %@ flow %@: old shader max channel delta %u", progress, flow, maxDelta);
        NSData *counts = draw(budget, u);
        unsigned expected = u.progress == 1 ? 1 : 2;
        for (NSUInteger i = 0; i < counts.length; i += 4) {
            unsigned actual = ((const uint8_t *)counts.bytes)[i];
            if (actual != expected) HARNESS_FAIL(@"progress %@: %u cubic reads, expected %u", progress, actual, expected);
        }
        if (settled && ![after isEqual:draw(destination, u)])
            HARNESS_FAIL(@"progress 1 flow %@: differs from destination-only reference", flow);
        printf("PASS progress %.2f flow %.0f: %lu pixels including bleed, old max delta %u%s, %u cubic read(s)\n",
               u.progress, u.flows, (unsigned long)(width * height), maxDelta,
               settled ? ", destination exact" : "", expected);
    }
    return 0;
} }
