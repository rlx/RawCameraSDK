//! The development kernel under wgpu: a Bayer mosaic in, scene-linear RGB out.
//!
//! Same kernel as the Metal one in the Swift package. Both are checked against
//! `Conformance/kernel-cases.json`.

use crate::{DevelopParams, Mosaic};

/// The shader source, for callers building their own pipeline.
pub const KERNEL_WGSL: &str = include_str!("../../../Shaders/develop.wgsl");

// Plain data with no padding: 128 bytes at 4-byte alignment.
unsafe impl bytemuck::Zeroable for DevelopParams {}
unsafe impl bytemuck::Pod for DevelopParams {}

/// A compiled kernel. Build once per device and reuse.
pub struct Developer {
    full: wgpu::ComputePipeline,
    half: wgpu::ComputePipeline,
}

impl Developer {
    pub fn new(device: &wgpu::Device) -> Self {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("rawinput develop"),
            source: wgpu::ShaderSource::Wgsl(KERNEL_WGSL.into()),
        });
        let pipeline = |entry: &'static str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: None,
                module: &module,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        Self { full: pipeline("develop_full"), half: pipeline("develop_half") }
    }

    /// Develops a mosaic into a new `Rgba16Float` texture of linear sRGB values, top row first.
    /// The picture is not rotated. Apply `Info::flip`.
    /// `half_size` gives one pixel per 2x2 mosaic cell, with no interpolation.
    pub fn develop(
        &self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        mosaic: &Mosaic<'_>,
        params: &DevelopParams,
        half_size: bool,
    ) -> wgpu::Texture {
        let divisor = if half_size { 2 } else { 1 };
        let size = wgpu::Extent3d {
            width: (params.size[0] / divisor).max(1),
            height: (params.size[1] / divisor).max(1),
            depth_or_array_layers: 1,
        };

        let source = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("mosaic"),
            size: wgpu::Extent3d { width: mosaic.raw_width, height: mosaic.raw_height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::R16Uint,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            source.as_image_copy(),
            bytemuck::cast_slice(mosaic.samples),
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some((mosaic.row_stride * 2) as u32),
                rows_per_image: Some(mosaic.raw_height),
            },
            wgpu::Extent3d { width: mosaic.raw_width, height: mosaic.raw_height, depth_or_array_layers: 1 },
        );

        let output = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("developed"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba16Float,
            usage: wgpu::TextureUsages::STORAGE_BINDING
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });

        let uniforms = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("develop params"),
            size: std::mem::size_of::<DevelopParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&uniforms, 0, bytemuck::bytes_of(params));

        let pipeline = if half_size { &self.half } else { &self.full };
        let bindings = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &pipeline.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&source.create_view(&Default::default())),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&output.create_view(&Default::default())),
                },
                wgpu::BindGroupEntry { binding: 2, resource: uniforms.as_entire_binding() },
            ],
        });

        let mut encoder = device.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_compute_pass(&Default::default());
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &bindings, &[]);
            // Workgroups are 8x8. The shader discards invocations past the texture's edge.
            pass.dispatch_workgroups(size.width.div_ceil(8), size.height.div_ceil(8), 1);
        }
        queue.submit([encoder.finish()]);
        output
    }
}
