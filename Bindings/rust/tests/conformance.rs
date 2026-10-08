//! The WGSL kernel against the cases every edition of the kernel has to pass:
//! `Conformance/kernel-cases.json`. The Swift package runs the same file against Metal.

use rawinput::gpu::Developer;
use rawinput::{DevelopParams, Mosaic};
use serde::Deserialize;

#[derive(Deserialize)]
struct Document {
    tolerance: f32,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    name: String,
    half_size: bool,
    raw_width: u32,
    raw_height: u32,
    mosaic: Vec<u16>,
    params: Params,
    every_pixel: Option<[f32; 3]>,
    pixels: Option<Vec<PixelCheck>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Params {
    black: [f32; 4],
    white_balance: [f32; 4],
    matrix: [[f32; 4]; 3],
    pattern: [u32; 4],
    origin: [u32; 2],
    size: [u32; 2],
    white: f32,
}

#[derive(Deserialize)]
struct PixelCheck {
    x: usize,
    y: usize,
    rgb: [f32; 3],
}

/// Reads a developed texture back as rows of linear RGB, row 0 at the top.
fn read_back(device: &wgpu::Device, queue: &wgpu::Queue, texture: &wgpu::Texture) -> Vec<Vec<[f32; 3]>> {
    let (width, height) = (texture.width(), texture.height());
    // Copy rows are padded to a multiple of 256 bytes. A pixel is 8.
    let padded = (width * 8).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    let buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: (padded * height) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&Default::default());
    encoder.copy_texture_to_buffer(
        texture.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &buffer,
            layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded), rows_per_image: Some(height) },
        },
        texture.size(),
    );
    queue.submit([encoder.finish()]);
    buffer.slice(..).map_async(wgpu::MapMode::Read, |result| result.unwrap());
    device.poll(wgpu::PollType::wait_indefinitely()).unwrap();

    let data = buffer.slice(..).get_mapped_range().unwrap();
    (0..height as usize)
        .map(|y| {
            (0..width as usize)
                .map(|x| {
                    let at = y * padded as usize + x * 8;
                    let channel = |c: usize| {
                        half::f16::from_le_bytes([data[at + c * 2], data[at + c * 2 + 1]]).to_f32()
                    };
                    [channel(0), channel(1), channel(2)]
                })
                .collect()
        })
        .collect()
}

fn distance(a: [f32; 3], b: [f32; 3]) -> f32 {
    a.iter().zip(b).map(|(x, y)| (x - y).powi(2)).sum::<f32>().sqrt()
}

#[test]
fn wgsl_kernel_passes_the_shared_cases() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../Conformance/kernel-cases.json");
    let document: Document = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();

    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&Default::default())).expect("a GPU adapter");
    let (device, queue) = pollster::block_on(adapter.request_device(&Default::default())).unwrap();
    let developer = Developer::new(&device);

    assert!(!document.cases.is_empty());
    for case in &document.cases {
        let p = &case.params;
        let params = DevelopParams {
            black: p.black,
            white_balance: p.white_balance,
            matrix_row0: p.matrix[0],
            matrix_row1: p.matrix[1],
            matrix_row2: p.matrix[2],
            pattern: p.pattern,
            origin: p.origin,
            size: p.size,
            white: p.white,
            reserved: [0; 3],
        };
        let mosaic = Mosaic {
            samples: &case.mosaic,
            raw_width: case.raw_width,
            raw_height: case.raw_height,
            row_stride: case.raw_width as usize,
        };
        let texture = developer.develop(&device, &queue, &mosaic, &params, case.half_size);
        let developed = read_back(&device, &queue, &texture);

        let divisor = if case.half_size { 2 } else { 1 };
        assert_eq!(developed.len() as u32, p.size[1] / divisor, "{}: height", case.name);
        assert_eq!(developed[0].len() as u32, p.size[0] / divisor, "{}: width", case.name);

        if let Some(expected) = case.every_pixel {
            for (y, row) in developed.iter().enumerate() {
                for (x, &pixel) in row.iter().enumerate() {
                    assert!(
                        distance(pixel, expected) < document.tolerance,
                        "{}: pixel ({x}, {y}) is {pixel:?}, expected {expected:?}",
                        case.name
                    );
                }
            }
        }
        for check in case.pixels.iter().flatten() {
            let pixel = developed[check.y][check.x];
            assert!(
                distance(pixel, check.rgb) < document.tolerance,
                "{}: pixel ({}, {}) is {pixel:?}, expected {:?}",
                case.name, check.x, check.y, check.rgb
            );
        }
    }
    println!("{} cases passed on {}", document.cases.len(), adapter.get_info().name);
}

/// End to end: the core decodes a file and the WGSL kernel develops it.
#[test]
fn develops_a_real_file_through_wgpu() {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Examples/RawInputDemo/Samples/files/samsung-nx300.srw");
    if !path.exists() {
        eprintln!("skipped: the sample files have not been fetched");
        return;
    }
    let mut file = rawinput::RawFile::open(&path).unwrap();
    file.unpack().unwrap();
    let (mosaic, params) = (file.mosaic().unwrap(), file.develop_params().unwrap());

    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&Default::default())).expect("a GPU adapter");
    let (device, queue) = pollster::block_on(adapter.request_device(&Default::default())).unwrap();
    // Half size keeps the read-back small.
    let texture = Developer::new(&device).develop(&device, &queue, &mosaic, &params, true);
    assert_eq!((texture.width(), texture.height()), (params.size[0] / 2, params.size[1] / 2));

    let developed = read_back(&device, &queue, &texture);
    let centre = developed[developed.len() / 2][developed[0].len() / 2];
    assert!(centre.iter().all(|v| v.is_finite() && *v >= 0.0), "{centre:?}");
    assert!(centre.iter().any(|v| *v > 0.001), "the picture is black");
}
