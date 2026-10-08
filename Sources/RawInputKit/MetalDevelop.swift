import CoreImage
import Metal
import RawShim

/// Develops a Bayer mosaic into scene-linear RGB on the GPU.
///
/// Per output pixel: subtract black, normalize to white, white balance, clip, demosaic
/// (Hamilton-Adams), then a 3x3 matrix from camera RGB to linear sRGB.
///
/// Coordinates: the mosaic texture holds the whole raw plane, masked borders included. The
/// kernel works in picture coordinates, with (0, 0) at the top-left of the visible area,
/// and adds `origin` when it reads the texture. Mosaic positions, the color pattern and
/// black levels are indexed in picture coordinates: `(row & 1) * 2 + (column & 1)`.
///
/// Thread-safe: the Metal objects held are immutable after `init`.
final class MetalDevelop: @unchecked Sendable {
    /// `nil` when the device has no usable GPU.
    static let shared: MetalDevelop? = MetalDevelop()

    /// Mirrors `Params` in the shader, field for field. Metal reads this struct's bytes as
    /// that one, and a test pins the offsets. Change both declarations together.
    struct Parameters {
        /// Black level at each mosaic position, in raw sample values.
        var black: SIMD4<Float>
        /// Multipliers for red, green and blue, scaled so the smallest is 1. Fourth lane unused.
        var whiteBalance: SIMD4<Float>
        /// Rows of the camera-to-sRGB matrix. Fourth lane unused.
        var matrixRow0: SIMD4<Float>
        var matrixRow1: SIMD4<Float>
        var matrixRow2: SIMD4<Float>
        /// Color at each mosaic position: 0 red, 1 green, 2 blue.
        var pattern: SIMD4<UInt32>
        /// Picture offset inside the raw plane.
        var origin: SIMD2<UInt32>
        var size: SIMD2<UInt32>
        /// Saturation level, in raw sample values.
        var white: Float
        var padding: UInt32 = 0
    }

    /// 2D texture limit on every supported device.
    private static let maximumTextureSide = 16_384

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fullSize: MTLComputePipelineState
    private let halfSize: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        do {
            // Compiled from source because `swift build` does not run the Metal compiler.
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let full = library.makeFunction(name: "develop_full"),
                  let half = library.makeFunction(name: "develop_half")
            else { return nil }
            self.fullSize = try device.makeComputePipelineState(function: full)
            self.halfSize = try device.makeComputePipelineState(function: half)
        } catch {
            // Only reachable if the shader source is broken. Release builds use the CPU path.
            assertionFailure("RawInputKit shader failed to compile: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    /// Develops a mosaic. Blocks until the GPU has finished.
    ///
    /// - Parameters:
    ///   - mosaic: `rawWidth` x `rawHeight` 16-bit samples, rows `rowBytes` apart. Only read
    ///     during the call.
    ///   - halfSize: produce one pixel per 2x2 mosaic cell, with no interpolation.
    /// - Returns: a new texture in extended linear sRGB, unrotated, top row first, and an
    ///   image backed by it.
    func develop(
        mosaic: UnsafeRawPointer, rowBytes: Int, rawWidth: Int, rawHeight: Int,
        parameters: Parameters, halfSize: Bool
    ) throws -> (image: CIImage, texture: MTLTexture) {
        guard rawWidth <= Self.maximumTextureSide, rawHeight <= Self.maximumTextureSide else {
            throw RawError.renderFailed(reason: "raw plane \(rawWidth)x\(rawHeight) exceeds the texture size limit")
        }
        let divisor = halfSize ? 2 : 1
        let width = Int(parameters.size.x) / divisor, height = Int(parameters.size.y) / divisor
        guard width > 0, height > 0 else { throw RawError.renderFailed(reason: "empty picture area") }

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: rawWidth, height: rawHeight, mipmapped: false)
        sourceDescriptor.usage = .shaderRead
        // CPU-writable for the upload below. A Mac with a discrete GPU has no shared textures.
        #if os(macOS)
        sourceDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        sourceDescriptor.storageMode = .shared
        #endif

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        // A render target too, so a caller given this texture by `makeTexture` can draw into it.
        outputDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outputDescriptor.storageMode = .private  // never read back on the CPU

        guard let source = device.makeTexture(descriptor: sourceDescriptor),
              let output = device.makeTexture(descriptor: outputDescriptor),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw RawError.renderFailed(reason: "could not allocate GPU resources") }

        source.replace(
            region: MTLRegionMake2D(0, 0, rawWidth, rawHeight), mipmapLevel: 0,
            withBytes: mosaic, bytesPerRow: rowBytes)

        let pipeline = halfSize ? self.halfSize : fullSize
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        withUnsafeBytes(of: parameters) { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        // The grid can overshoot the texture by up to one group. The kernel discards the excess.
        let group = MTLSize(
            width: pipeline.threadExecutionWidth,
            height: pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + group.width - 1) / group.width,
                height: (height + group.height - 1) / group.height, depth: 1),
            threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            throw RawError.renderFailed(reason: commands.error?.localizedDescription ?? "GPU command failed")
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let image = CIImage(mtlTexture: output, options: [.colorSpace: colorSpace])
        else { throw RawError.renderFailed(reason: "could not wrap the developed texture") }
        // Texture row 0 is the top of the picture and Core Image's origin is bottom-left.
        return (image.oriented(.downMirrored), output)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Mirrors MetalDevelop.Parameters in Swift, field for field.
    struct Params {
        float4 black;        // per mosaic position: (row & 1) * 2 + (col & 1)
        float4 wb;           // per color
        float4 m0, m1, m2;   // rows: white-balanced camera RGB -> linear sRGB
        uint4 pattern;       // 0 R, 1 G, 2 B
        uint2 origin;        // picture offset inside the raw plane
        uint2 size;
        float white;
        uint padding;
    };

    typedef texture2d<ushort, access::read> Mosaic;

    // Index of a picture coordinate within the 2x2 mosaic cell.
    static inline uint position(int2 p) { return uint(p.y & 1) * 2 + uint(p.x & 1); }

    // One sensor sample: black subtracted, scaled so sensor white is 1, white-balanced.
    //
    // Coordinates outside the picture are mirrored about the edge pixel, which keeps the
    // sample's color.
    //
    // The clip to 1 comes after white balance. Clipping earlier turns blown highlights magenta.
    static inline float value(Mosaic mosaic, constant Params &params, int2 p) {
        int2 last = int2(params.size) - 1;
        p = abs(p);
        p = last - abs(last - p);
        uint pos = position(p);
        float black = params.black[pos];
        float v = (float(mosaic.read(uint2(p) + params.origin).r) - black) / (params.white - black);
        return min(max(v, 0.0f) * params.wb[params.pattern[pos]], 1.0f);
    }

    // Green at any pixel. At a red or blue site it is interpolated along the direction with
    // the smaller gradient, corrected by the curvature of the color sampled here.
    static inline float green(Mosaic mosaic, constant Params &params, int2 p) {
        float c = value(mosaic, params, p);
        if (params.pattern[position(p)] == 1) return c;
        float l = value(mosaic, params, p + int2(-1, 0)), r = value(mosaic, params, p + int2(1, 0));
        float u = value(mosaic, params, p + int2(0, -1)), d = value(mosaic, params, p + int2(0, 1));
        float l2 = value(mosaic, params, p + int2(-2, 0)), r2 = value(mosaic, params, p + int2(2, 0));
        float u2 = value(mosaic, params, p + int2(0, -2)), d2 = value(mosaic, params, p + int2(0, 2));
        float gradH = abs(l - r) + abs(2 * c - l2 - r2);
        float gradV = abs(u - d) + abs(2 * c - u2 - d2);
        float h = (l + r) * 0.5f + (2 * c - l2 - r2) * 0.25f;
        float v = (u + d) * 0.5f + (2 * c - u2 - d2) * 0.25f;
        float g = gradH < gradV ? h : (gradV < gradH ? v : (h + v) * 0.5f);
        return max(g, 0.0f);
    }

    // Red or blue minus green, at a red or blue site.
    static inline float chroma(Mosaic mosaic, constant Params &params, int2 p) {
        return value(mosaic, params, p) - green(mosaic, params, p);
    }

    static inline float4 to_output(constant Params &params, float3 camera) {
        float4 c = float4(camera, 0);
        return float4(dot(params.m0, c), dot(params.m1, c), dot(params.m2, c), 1);
    }

    kernel void develop_full(Mosaic mosaic [[texture(0)]],
                             texture2d<float, access::write> output [[texture(1)]],
                             constant Params &params [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        int2 p = int2(gid);
        uint color = params.pattern[position(p)];
        float g = green(mosaic, params, p);
        float3 camera = float3(0, g, 0);

        if (color == 1) {
            // Red and blue lie on opposite axes. `2 - color` swaps red (0) and blue (2).
            float horizontal = (chroma(mosaic, params, p + int2(-1, 0)) + chroma(mosaic, params, p + int2(1, 0))) * 0.5f;
            float vertical = (chroma(mosaic, params, p + int2(0, -1)) + chroma(mosaic, params, p + int2(0, 1))) * 0.5f;
            uint horizontalColor = params.pattern[position(p + int2(1, 0))];
            camera[horizontalColor] = g + horizontal;
            camera[2 - horizontalColor] = g + vertical;
        } else {
            // A red site has blue on its four diagonals, and the reverse.
            float diagonal = (chroma(mosaic, params, p + int2(-1, -1)) + chroma(mosaic, params, p + int2(1, -1)) +
                              chroma(mosaic, params, p + int2(-1, 1)) + chroma(mosaic, params, p + int2(1, 1))) * 0.25f;
            camera[color] = value(mosaic, params, p);
            camera[2 - color] = g + diagonal;
        }
        output.write(to_output(params, max(camera, 0.0f)), gid);
    }

    // One output pixel per 2x2 cell: its red, its blue, and the mean of its two greens.
    kernel void develop_half(Mosaic mosaic [[texture(0)]],
                             texture2d<float, access::write> output [[texture(1)]],
                             constant Params &params [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float3 sum = float3(0), count = float3(0);
        for (int i = 0; i < 4; i++) {
            int2 p = int2(gid) * 2 + int2(i & 1, i >> 1);
            uint color = params.pattern[position(p)];
            sum[color] += value(mosaic, params, p);
            count[color] += 1;
        }
        output.write(to_output(params, sum / max(count, 1.0f)), gid);
    }
    """
}

extension MetalDevelop.Parameters {
    /// Copies the core's parameter block, field for field.
    init(_ core: rik_develop_params) {
        self.init(
            black: SIMD4(core.black.0, core.black.1, core.black.2, core.black.3),
            whiteBalance: SIMD4(core.white_balance.0, core.white_balance.1, core.white_balance.2, core.white_balance.3),
            matrixRow0: SIMD4(core.matrix_row0.0, core.matrix_row0.1, core.matrix_row0.2, core.matrix_row0.3),
            matrixRow1: SIMD4(core.matrix_row1.0, core.matrix_row1.1, core.matrix_row1.2, core.matrix_row1.3),
            matrixRow2: SIMD4(core.matrix_row2.0, core.matrix_row2.1, core.matrix_row2.2, core.matrix_row2.3),
            pattern: SIMD4(core.pattern.0, core.pattern.1, core.pattern.2, core.pattern.3),
            origin: SIMD2(core.origin.0, core.origin.1),
            size: SIMD2(core.size.0, core.size.1),
            white: core.white)
    }
}
