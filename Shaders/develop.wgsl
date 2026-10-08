// Develops a Bayer mosaic into scene-linear RGB. WGSL edition, for wgpu and WebGPU.
// Same algorithm as the Metal edition in Sources/RawInputKit/MetalDevelop.swift. Both are
// checked against Conformance/kernel-cases.json.
//
// Per output pixel: subtract black, normalize to white, white balance, clip, demosaic,
// then a 3x3 matrix from camera RGB to linear sRGB.
//
// The mosaic texture holds the whole raw plane. The kernel works in picture coordinates,
// (0, 0) at the top-left of the visible area, and adds `origin` when it reads the texture.

// `rik_develop_params` from RawShim.h, byte for byte (128 bytes).
struct Params {
    black: vec4f,     // per mosaic position: (row & 1) * 2 + (column & 1)
    wb: vec4f,        // per color; the smallest multiplier is 1
    m0: vec4f,        // rows of the matrix: white-balanced camera RGB -> linear sRGB
    m1: vec4f,
    m2: vec4f,
    pattern: vec4u,   // color at each mosaic position: 0 R, 1 G, 2 B
    origin: vec2u,    // picture offset inside the raw plane
    size: vec2u,      // picture size
    white: f32,
    reserved0: u32,
    reserved1: u32,
    reserved2: u32,
}

@group(0) @binding(0) var mosaic: texture_2d<u32>;
@group(0) @binding(1) var output: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var<uniform> params: Params;

// Index of a picture coordinate within the 2x2 mosaic cell.
fn position(p: vec2i) -> u32 {
    return u32(p.y & 1) * 2u + u32(p.x & 1);
}

// One sensor sample: black subtracted, scaled so sensor white is 1, white-balanced.
// Coordinates outside the picture are mirrored about the edge pixel, which keeps the color.
// The clip to 1 must follow white balance, or blown highlights turn magenta.
fn value(at: vec2i) -> f32 {
    let last = vec2i(params.size) - 1;
    var p = abs(at);
    p = last - abs(last - p);
    let pos = position(p);
    let black = params.black[pos];
    let raw = f32(textureLoad(mosaic, vec2u(p) + params.origin, 0).r);
    let v = (raw - black) / (params.white - black);
    return min(max(v, 0.0) * params.wb[params.pattern[pos]], 1.0);
}

// Green at any pixel. At a red or blue site it is interpolated along the direction of least
// change (Hamilton-Adams), corrected by the curvature of the color sampled there.
fn green(p: vec2i) -> f32 {
    let c = value(p);
    if (params.pattern[position(p)] == 1u) {
        return c;
    }
    let l = value(p + vec2i(-1, 0));
    let r = value(p + vec2i(1, 0));
    let u = value(p + vec2i(0, -1));
    let d = value(p + vec2i(0, 1));
    let l2 = value(p + vec2i(-2, 0));
    let r2 = value(p + vec2i(2, 0));
    let u2 = value(p + vec2i(0, -2));
    let d2 = value(p + vec2i(0, 2));
    let grad_h = abs(l - r) + abs(2.0 * c - l2 - r2);
    let grad_v = abs(u - d) + abs(2.0 * c - u2 - d2);
    let h = (l + r) * 0.5 + (2.0 * c - l2 - r2) * 0.25;
    let v = (u + d) * 0.5 + (2.0 * c - u2 - d2) * 0.25;
    var g = (h + v) * 0.5;
    if (grad_h < grad_v) {
        g = h;
    } else if (grad_v < grad_h) {
        g = v;
    }
    return max(g, 0.0);
}

// Red or blue minus green, at a red or blue site. Color differences vary slowly, so they
// are safe to average.
fn chroma(p: vec2i) -> f32 {
    return value(p) - green(p);
}

fn to_output(camera: vec3f) -> vec4f {
    let c = vec4f(camera, 0.0);
    return vec4f(dot(params.m0, c), dot(params.m1, c), dot(params.m2, c), 1.0);
}

@compute @workgroup_size(8, 8)
fn develop_full(@builtin(global_invocation_id) id: vec3u) {
    let extent = textureDimensions(output);
    if (id.x >= extent.x || id.y >= extent.y) {
        return;
    }
    let p = vec2i(id.xy);
    let color = params.pattern[position(p)];
    let g = green(p);
    var camera = vec3f(0.0, g, 0.0);

    if (color == 1u) {
        // One of red/blue is left and right, the other above and below.
        // `2 - color` swaps red (0) and blue (2).
        let horizontal = (chroma(p + vec2i(-1, 0)) + chroma(p + vec2i(1, 0))) * 0.5;
        let vertical = (chroma(p + vec2i(0, -1)) + chroma(p + vec2i(0, 1))) * 0.5;
        let horizontal_color = params.pattern[position(p + vec2i(1, 0))];
        camera[horizontal_color] = g + horizontal;
        camera[2u - horizontal_color] = g + vertical;
    } else {
        // A red site has blue on its four diagonals, and the reverse.
        let diagonal = (chroma(p + vec2i(-1, -1)) + chroma(p + vec2i(1, -1)) +
                        chroma(p + vec2i(-1, 1)) + chroma(p + vec2i(1, 1))) * 0.25;
        camera[color] = value(p);
        camera[2u - color] = g + diagonal;
    }
    textureStore(output, id.xy, to_output(max(camera, vec3f(0.0))));
}

// One output pixel per 2x2 cell: its red, its blue, and the mean of its two greens.
@compute @workgroup_size(8, 8)
fn develop_half(@builtin(global_invocation_id) id: vec3u) {
    let extent = textureDimensions(output);
    if (id.x >= extent.x || id.y >= extent.y) {
        return;
    }
    var sum = vec3f(0.0);
    var count = vec3f(0.0);
    for (var i = 0; i < 4; i++) {
        let p = vec2i(id.xy) * 2 + vec2i(i & 1, i >> 1);
        let color = params.pattern[position(p)];
        sum[color] += value(p);
        count[color] += 1.0;
    }
    textureStore(output, id.xy, to_output(sum / max(count, vec3f(1.0))));
}
