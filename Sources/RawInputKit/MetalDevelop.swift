import CoreImage
import Metal
import RawShim

/// Develops a Bayer mosaic into scene-linear RGB on the GPU.
///
/// One compute kernel does, per output pixel:
///
///     raw sample ─▶ subtract black ─▶ normalise to white ─▶ white balance ─▶ clip
///                ─▶ demosaic (interpolate the two missing colours)
///                ─▶ 3x3 matrix: camera RGB ─▶ linear sRGB
///
/// **Coordinates.** The mosaic texture holds the whole raw plane, masked borders included.
/// The kernel works in *picture* coordinates, with (0, 0) at the top-left of the visible
/// area, and adds `origin` when it reads the texture. Mosaic positions, the colour pattern
/// and black levels are all indexed in picture coordinates: `(row & 1) * 2 + (column & 1)`.
///
/// **Demosaicing** is Hamilton-Adams: green is interpolated along whichever direction,
/// horizontal or vertical, has the smaller gradient; red and blue are then interpolated as
/// differences from green, which vary slowly across an image. It is a deliberately modest
/// algorithm: no patents in force, a few dozen texture reads per pixel, and good enough to
/// judge a picture. The better-known AMaZE and RCD are GPL and cannot be used here.
///
/// **Thread safety.** The Metal objects held are immutable after `init` and safe to use
/// from several threads, which is what `@unchecked Sendable` asserts.
final class MetalDevelop: @unchecked Sendable {
    /// `nil` when the device has no usable GPU; callers then use LibRaw's CPU development.
    static let shared: MetalDevelop? = MetalDevelop()

    /// Mirrors `Params` in the shader, field for field.
    ///
    /// The two declarations are a binary contract: Metal reads this struct's bytes as that
    /// one. SIMD types have the same size and alignment in Swift and in the shading
    /// language, and the fields are ordered so that neither side inserts padding before the
    /// last one. A test pins the offsets; change both declarations together or not at all.
    struct Parameters {
        /// Black level at each mosaic position, in raw sample values.
        var black: SIMD4<Float>
        /// Multiplier for red, green and blue (the fourth lane is unused), scaled so the
        /// smallest is 1.
        var whiteBalance: SIMD4<Float>
        /// Rows of the camera-to-sRGB matrix (the fourth lane is unused).
        var matrixRow0: SIMD4<Float>
        var matrixRow1: SIMD4<Float>
        var matrixRow2: SIMD4<Float>
        /// Colour at each mosaic position: 0 red, 1 green, 2 blue.
        var pattern: SIMD4<UInt32>
        /// Where the picture starts inside the raw plane.
        var origin: SIMD2<UInt32>
        /// Size of the picture.
        var size: SIMD2<UInt32>
        /// Saturation level, in raw sample values.
        var white: Float
        var padding: UInt32 = 0
    }

    /// GPU family limit for 2D textures on every device this package supports.
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
            // The shader is compiled from source at first use, about 20 ms, instead of
            // shipping as a .metal file. `swift build` and `swift test` do not run the Metal
            // compiler, so a precompiled library would only exist in Xcode builds.
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let full = library.makeFunction(name: "develop_full"),
                  let half = library.makeFunction(name: "develop_half")
            else { return nil }
            self.fullSize = try device.makeComputePipelineState(function: full)
            self.halfSize = try device.makeComputePipelineState(function: half)
        } catch {
            // Only reachable if the shader source below is broken, which is a programming
            // error; the CPU path keeps release builds working regardless.
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
    ///     during the call; the samples are copied into a texture.
    ///   - halfSize: produce one pixel per 2x2 mosaic cell instead of interpolating. Half
    ///     the width and height, a quarter of the memory, and no demosaic artefacts.
    /// - Returns: an image in extended linear sRGB, **not yet rotated**; the caller applies
    ///   the camera's orientation. It is backed by a texture this call allocated.
    func develop(
        mosaic: UnsafeRawPointer, rowBytes: Int, rawWidth: Int, rawHeight: Int,
        parameters: Parameters, halfSize: Bool
    ) throws -> CIImage {
        guard rawWidth <= Self.maximumTextureSide, rawHeight <= Self.maximumTextureSide else {
            throw RawError.renderFailed(reason: "raw plane \(rawWidth)x\(rawHeight) exceeds the texture size limit")
        }
        let divisor = halfSize ? 2 : 1
        let width = Int(parameters.size.x) / divisor, height = Int(parameters.size.y) / divisor
        guard width > 0, height > 0 else { throw RawError.renderFailed(reason: "empty picture area") }

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: rawWidth, height: rawHeight, mipmapped: false)
        sourceDescriptor.usage = .shaderRead
        sourceDescriptor.storageMode = .shared  // CPU-writable for the upload below

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
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
        // Whole threadgroups are dispatched, so the grid can overshoot the texture by up to
        // one group; the kernel discards threads that fall outside it.
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
        // A texture's first row is the top of the picture; Core Image puts its origin at the
        // bottom-left and would show it upside down. Flip it vertically.
        return image.oriented(.downMirrored)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Mirrors MetalDevelop.Parameters in Swift, field for field. Keep the two in step.
    struct Params {
        float4 black;        // per mosaic position: (row & 1) * 2 + (col & 1)
        float4 wb;           // per colour; the smallest multiplier is 1
        float4 m0, m1, m2;   // rows of the matrix: white-balanced camera RGB -> linear sRGB
        uint4 pattern;       // colour at each mosaic position: 0 R, 1 G, 2 B
        uint2 origin;        // picture offset inside the raw plane
        uint2 size;          // picture size
        float white;
        uint padding;
    };

    typedef texture2d<ushort, access::read> Mosaic;

    // Index of a picture coordinate within the 2x2 mosaic cell.
    static inline uint position(int2 p) { return uint(p.y & 1) * 2 + uint(p.x & 1); }

    // One sensor sample, ready to interpolate: black subtracted, scaled so that sensor
    // white is 1, and white-balanced.
    //
    // Coordinates outside the picture are mirrored about the edge pixel. Mirroring moves a
    // coordinate by an even distance, so the reflected sample has the same colour as the
    // one asked for and the interpolation needs no special cases at the border.
    //
    // The clip to 1 happens after white balance on purpose. A blown highlight saturates all
    // three channels at sensor white; white balance then scales red and blue past green,
    // and without the clip the highlight would turn magenta.
    static inline float value(Mosaic mosaic, constant Params &params, int2 p) {
        int2 last = int2(params.size) - 1;
        p = abs(p);
        p = last - abs(last - p);
        uint pos = position(p);
        float black = params.black[pos];
        float v = (float(mosaic.read(uint2(p) + params.origin).r) - black) / (params.white - black);
        return min(max(v, 0.0f) * params.wb[params.pattern[pos]], 1.0f);
    }

    // Green at any pixel. At a green site it is the sample itself. At a red or blue site it
    // is interpolated along the direction, horizontal or vertical, in which the image
    // changes least, so that edges are followed and not smeared across. The second term
    // of each estimate corrects it with the curvature of the colour that IS sampled here.
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

    // Red or blue minus green, at a red or blue site. Colour differences change far more
    // slowly across an image than the colours themselves, so averaging them is safe where
    // averaging raw red or blue would blur and fringe.
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
            // A green site has one of red/blue to its left and right and the other above
            // and below. `2 - colour` turns red (0) into blue (2) and back.
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
    /// Builds kernel parameters from the shim's description of an unpacked Bayer file.
    init(_ raw: rik_info) {
        // White balance arrives with green at 1. It is rescaled so the *smallest* multiplier
        // is 1: every channel then reaches or passes 1 when the sensor saturates, and the
        // kernel's clip leaves blown highlights neutral.
        let multipliers = SIMD3(raw.wb.0, raw.wb.1, raw.wb.2)
        let matrix = raw.rgb_cam
        self.init(
            black: SIMD4(raw.black.0, raw.black.1, raw.black.2, raw.black.3),
            whiteBalance: SIMD4(multipliers / multipliers.min(), 1),
            matrixRow0: SIMD4(matrix.0, matrix.1, matrix.2, 0),
            matrixRow1: SIMD4(matrix.3, matrix.4, matrix.5, 0),
            matrixRow2: SIMD4(matrix.6, matrix.7, matrix.8, 0),
            pattern: SIMD4(UInt32(raw.bayer.0), UInt32(raw.bayer.1), UInt32(raw.bayer.2), UInt32(raw.bayer.3)),
            origin: SIMD2(raw.left_margin, raw.top_margin),
            size: SIMD2(raw.width, raw.height),
            white: raw.white)
    }
}
