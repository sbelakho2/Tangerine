# Tangerine Graphics & GPU Development Guide

> **Edition**: 2026 · **Modules**: `std::gpu`, `std::linalg`, `std::float_control`, `std::gfx_*`

## Overview

Tangerine provides a multi-backend GPU abstraction (`std::gpu`) that covers Vulkan, Metal, DirectX 12, OpenGL 4.6, and WebGPU. Combined with the linear algebra library (`std::linalg`), deterministic floating-point control (`std::float_control`), and the existing graphics stack (`std::gfx_*`), Tangerine delivers a complete graphics programming environment.

## Architecture

```
┌─────────────────────────────────┐
│         Application Code        │
├─────────────────────────────────┤
│  std::linalg    std::gfx_scene  │
│  std::gfx_2d    std::gfx_text   │
├─────────────────────────────────┤
│          std::gpu               │
│  (Unified abstraction layer)    │
├──────┬──────┬──────┬──────┬─────┤
│Vulkan│Metal │ DX12 │ GL46 │WebGPU│
└──────┴──────┴──────┴──────┴─────┘
```

## Getting Started

### Project Setup

```toml
# Tangerine.toml
[package]
name = "my_renderer"
version = "0.1.0"
edition = "2026"

[dependencies]
std_gpu = { path = "std/gpu" }
std_linalg = { path = "std/linalg" }

[features]
gpu_validation = true  # Enable GPU debug layers
```

### Minimal Triangle

```tangerine
use std::gpu::{
  GpuInstance, Backend, GpuDevice, GpuQueue,
  Surface, Swapchain, PresentMode,
  ShaderModule, ShaderSource,
  RenderPipeline, RenderPipelineDesc,
  CommandEncoder, RenderPassEncoder,
  TextureFormat, VertexFormat, PrimitiveTopology,
}
use std::linalg::{Vec2, Vec3}

struct Vertex
  position: Vec2
  color: Vec3
end

def main() -> Result[Unit, Error]
  ## 1. Create instance & device
  let instance = GpuInstance.new(Backend.Auto)?
  let adapter = instance.request_adapter(None).await?
  let (device, queue) = adapter.request_device(None).await?

  ## 2. Create surface & swapchain
  let window = create_window(800, 600, "Triangle")?
  let surface = instance.create_surface(&window)?
  let swapchain = device.create_swapchain(&surface, 800, 600,
    TextureFormat.Bgra8Unorm, PresentMode.Fifo)?

  ## 3. Compile shaders
  let shader = device.create_shader_module(ShaderSource.TgShader(SHADER_SRC))?

  ## 4. Create pipeline
  let pipeline = device.create_render_pipeline(RenderPipelineDesc {
    vertex_shader: &shader,
    vertex_entry: "vs_main",
    fragment_shader: Some(&shader),
    fragment_entry: Some("fs_main"),
    vertex_buffers: &[VertexBufferLayout {
      stride: size_of::<Vertex>(),
      attributes: &[
        VertexAttribute { format: VertexFormat.Float32x2, offset: 0, location: 0 },
        VertexAttribute { format: VertexFormat.Float32x3, offset: 8, location: 1 },
      ],
    }],
    primitive: PrimitiveTopology.TriangleList,
    color_targets: &[TextureFormat.Bgra8Unorm],
    ..Default.default()
  })?

  ## 5. Create vertex buffer
  let vertices = [
    Vertex { position: Vec2.new(0.0, 0.5), color: Vec3.new(1.0, 0.0, 0.0) },
    Vertex { position: Vec2.new(-0.5, -0.5), color: Vec3.new(0.0, 1.0, 0.0) },
    Vertex { position: Vec2.new(0.5, -0.5), color: Vec3.new(0.0, 0.0, 1.0) },
  ]
  let vbuf = device.create_buffer_init(&vertices, BufferUsage.Vertex)?

  ## 6. Render loop
  loop
    let frame = swapchain.acquire_next_image()?
    let mut encoder = device.create_command_encoder()?

    {
      let mut pass = encoder.begin_render_pass(&RenderPassDesc {
        color_attachments: &[ColorAttachment {
          view: &frame.view,
          load: LoadOp.Clear(Color { r: 0.1, g: 0.1, b: 0.1, a: 1.0 }),
          store: StoreOp.Store,
        }],
        depth_attachment: None,
      })
      pass.set_pipeline(&pipeline)
      pass.set_vertex_buffer(0, &vbuf)
      pass.draw(0..3, 0..1)
    }

    queue.submit(&[encoder.finish()?])
    swapchain.present(frame)?

    if window.should_close() then break end
  end

  Ok(())
end

const SHADER_SRC: &str = """
  struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) color: vec3<f32>,
  }
  struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec3<f32>,
  }
  @vertex
  fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.position = vec4(in.position, 0.0, 1.0);
    out.color = in.color;
    return out;
  }
  @fragment
  fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return vec4(in.color, 1.0);
  }
"""
```

## GPU Backends

| Backend | Platform | Auto-Selected When |
|---------|----------|-------------------|
| Vulkan | Linux, Windows, Android | Linux default |
| Metal | macOS, iOS | macOS/iOS default |
| DirectX 12 | Windows | Windows default |
| OpenGL 4.6 | Fallback | When no modern API available |
| WebGPU | Browser (WASM) | WASM target |

```tangerine
## Force a specific backend
let instance = GpuInstance.new(Backend.Vulkan)?

## Auto-detect the best backend for the current platform
let instance = GpuInstance.new(Backend.Auto)?
```

## Linear Algebra

### Vectors

```tangerine
use std::linalg::{Vec2, Vec3, Vec4, DVec3, IVec2}

let a = Vec3.new(1.0, 2.0, 3.0)
let b = Vec3.new(4.0, 5.0, 6.0)

let sum = a + b                  ## (5, 7, 9)
let dot = a.dot(b)               ## 32.0
let cross = a.cross(b)           ## (-3, 6, -3)
let normalized = a.normalize()   ## unit vector
let length = a.length()          ## 3.741...
let lerped = a.lerp(b, 0.5)     ## midpoint

## SIMD-accelerated Vec4
let v4 = Vec4.new(1.0, 2.0, 3.0, 4.0)
let w4 = Vec4.new(5.0, 6.0, 7.0, 8.0)
let dot4 = v4.dot(w4)  ## Uses f32x4 SIMD internally
```

### Matrices

```tangerine
use std::linalg::{Mat4, Vec3}

## Projection matrices
let perspective = Mat4.perspective(
  fov_y_radians: 45.0_f32.to_radians(),
  aspect: 16.0 / 9.0,
  near: 0.1,
  far: 100.0,
)

## For Vulkan NDC (Y-down, Z 0..1)
let perspective_vk = Mat4.perspective_vulkan(
  fov_y_radians: 45.0_f32.to_radians(),
  aspect: 16.0 / 9.0,
  near: 0.1,
  far: 100.0,
)

let ortho = Mat4.orthographic(-10.0, 10.0, -10.0, 10.0, 0.1, 100.0)

## View matrix
let view = Mat4.look_at(
  eye: Vec3.new(0.0, 5.0, 10.0),
  target: Vec3.ZERO,
  up: Vec3.Y,
)

## Model matrix
let model = Mat4.IDENTITY
  .translate(Vec3.new(2.0, 0.0, 0.0))
  .rotate_y(45.0_f32.to_radians())
  .scale_uniform(2.0)

## MVP matrix
let mvp = perspective * view * model
```

### Quaternions

```tangerine
use std::linalg::{Quat, Vec3}

let rotation = Quat.from_axis_angle(Vec3.Y, 90.0_f32.to_radians())
let rotated_point = rotation.rotate_vec3(Vec3.new(1.0, 0.0, 0.0))

## Smooth interpolation
let a = Quat.from_euler(0.0, 0.0, 0.0)
let b = Quat.from_euler(0.0, 90.0_f32.to_radians(), 0.0)
let mid = a.slerp(b, 0.5)  ## Halfway rotation

## Convert to matrix for shader upload
let rot_matrix = rotation.to_mat4()
```

### Transforms

```tangerine
use std::linalg::Transform

let mut transform = Transform.IDENTITY
transform.position = Vec3.new(5.0, 0.0, -3.0)
transform.rotation = Quat.from_axis_angle(Vec3.Y, 45.0_f32.to_radians())
transform.scale = Vec3.new(2.0, 2.0, 2.0)

let matrix = transform.to_mat4()
let inverse = transform.inverse()
```

## Shader Compilation

### SPIR-V Cross-Compilation

```tangerine
use std::gpu::spirv

## Compile GLSL to SPIR-V
let spirv_bytes = spirv::compile_glsl(glsl_source, ShaderStage.Vertex)?

## Transpile SPIR-V to target shading language
let msl_source = spirv::to_msl(&spirv_bytes)?     ## For Metal
let hlsl_source = spirv::to_hlsl(&spirv_bytes)?    ## For DirectX
let glsl_source = spirv::to_glsl(&spirv_bytes)?    ## For OpenGL

## Validate SPIR-V
let is_valid = spirv::validate(&spirv_bytes)?

## Reflect shader interface
let info = spirv::reflect(&spirv_bytes)?
for binding in info.bindings do
  println("Set {}, Binding {}: {:?}", binding.set, binding.binding, binding.ty)
end
```

## Compute Shaders

```tangerine
use std::gpu::{ComputePipeline, ComputePipelineDesc}

let compute_shader = device.create_shader_module(
  ShaderSource.Wgsl("""
    @group(0) @binding(0)
    var<storage, read> input: array<f32>;
    @group(0) @binding(1)
    var<storage, read_write> output: array<f32>;

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3<u32>) {
      output[id.x] = input[id.x] * 2.0;
    }
  """)
)?

let pipeline = device.create_compute_pipeline(ComputePipelineDesc {
  shader: &compute_shader,
  entry_point: "main",
  layout: &layout,
})?

let mut encoder = device.create_command_encoder()?
{
  let mut pass = encoder.begin_compute_pass()
  pass.set_pipeline(&pipeline)
  pass.set_bind_group(0, &bind_group)
  pass.dispatch(data.len() as u32 / 64, 1, 1)
}
queue.submit(&[encoder.finish()?])
```

## Deterministic Floating Point

For multiplayer games and physics simulations that need reproducible results:

```tangerine
use std::float_control::{
  DeterministicConfig, deterministic_scope,
  RoundingMode, set_rounding_mode,
}

## Enable full cross-platform determinism
@[deterministic_float]
def physics_step(state: &mut PhysicsWorld)
  for body in state.bodies.iter_mut() do
    body.velocity += body.acceleration * DT
    body.position += body.velocity * DT
  end
end

## Or use runtime scope
deterministic_scope(DeterministicConfig.FULL, ||
  simulate_physics()
)
```

## Memory-Mapped Assets

For loading large assets (textures, meshes) with zero-copy:

```tangerine
use std::mmap::{Mmap, MmapBuilder}

## Memory-map a large texture file
let mmap = MmapBuilder.new()
  .read_only()
  .sequential()
  .build_from_path("assets/terrain.dds")?

## Pass directly to GPU upload
let texture = device.create_texture_from_data(
  &mmap[..],
  TextureFormat.Bc7RgbaUnorm,
  2048, 2048,
)?
```

## Advanced Features

### Descriptor Indexing (Bindless)

```tangerine
let features = DeviceFeatures {
  descriptor_indexing: true,
  ..Default.default()
}
let (device, queue) = adapter.request_device(Some(features)).await?

## Create a large descriptor array
let layout = device.create_bind_group_layout(&[
  BindGroupLayoutEntry {
    binding: 0,
    ty: BindingType.SampledTexture,
    count: Some(1024),  ## Bindless array
  },
])
```

### Multi-GPU

```tangerine
let instance = GpuInstance.new(Backend.Auto)?
let adapters = instance.enumerate_adapters()

for adapter in adapters.iter() do
  let info = adapter.info()
  println("{}: {:?}, {} MB VRAM",
    info.name, info.device_type, info.dedicated_video_memory / (1024 * 1024))
end

## Select discrete GPU
let discrete = adapters.iter()
  .find(|a| a.info().device_type == DeviceType.DiscreteGpu)
  .unwrap()
```

## Performance Tips

1. **Batch draw calls** — minimize pipeline and bind group changes
2. **Use staging buffers** — double-buffer uploads to avoid stalls
3. **Prefer SPIR-V** — pre-compiled shaders load faster
4. **Use memory-mapped I/O** for large asset files
5. **Enable deterministic float only where needed** — it can inhibit optimizations
6. **Profile with GPU timestamps** — measure actual GPU time, not CPU time
7. **Use `Vec4`/`Mat4`** — SIMD-accelerated on x86_64 and AArch64

## See Also

- [std/gpu.tg](../std/gpu.tg) — Full GPU API reference
- [std/linalg.tg](../std/linalg.tg) — Linear algebra reference
- [std/float_control.tg](../std/float_control.tg) — Deterministic FP reference
- [std/mmap.tg](../std/mmap.tg) — Memory-mapped I/O reference
- [std/simd.tg](../std/simd.tg) — SIMD intrinsics reference
- [examples/gpu_triangle.tg](../examples/gpu_triangle.tg) — Triangle example
- [docs/current/gfx_ui_conformance.md](gfx_ui_conformance.md) — Conformance testing
