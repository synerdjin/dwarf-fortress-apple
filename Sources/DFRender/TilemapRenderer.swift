import DFSim
import Foundation
import Metal

public enum RenderError: Error, CustomStringConvertible {
  case noDevice
  case shaderCompilationFailed(String)
  case pipelineCreationFailed(String)
  case textureCreationFailed(String)
  case bufferCreationFailed
  case encodingFailed(String)

  public var description: String {
    switch self {
    case .noDevice:
      """
      no Metal device available. This machine has no GPU accessible to the \
      process — on a remote session, try running with a local window server.
      """
    case .shaderCompilationFailed(let detail): "shader compilation failed: \(detail)"
    case .pipelineCreationFailed(let detail): "pipeline creation failed: \(detail)"
    case .textureCreationFailed(let what): "could not create texture: \(what)"
    case .bufferCreationFailed: "could not create buffer"
    case .encodingFailed(let detail): "could not encode image: \(detail)"
    }
  }
}

/// Shader source, compiled at runtime.
///
/// **Runtime compilation is the primary path even though the offline Metal
/// compiler is available.** A build that needs the offline compiler breaks the
/// moment the repository is cloned onto a machine with only Command Line Tools,
/// and the constitution forbids verification depending on Xcode. Compilation
/// costs a few milliseconds once at startup.
///
/// Determinism (DR-003) constrains what this may do: nearest sampling only, no
/// blending, and positions derived from integers. Adding filtering or alpha
/// blending here would make captures implementation-defined.
private let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct Instance {
      ushort glyph;
      uchar  depth;
      uchar  reserved;
      uchar4 foreground;
      uchar4 background;
  };

  struct Uniforms {
      uint  columns;
      uint  rows;
      uint  glyphCount;
      uint  layerOffset;
  };

  struct VertexOut {
      float4 position [[position]];
      float2 atlasUV;
      float4 foreground;
      float4 background;
  };

  vertex VertexOut tile_vertex(uint vertexID [[vertex_id]],
                               uint instanceID [[instance_id]],
                               constant Instance *instances [[buffer(0)]],
                               constant Uniforms &uniforms [[buffer(1)]])
  {
      // Two triangles as a strip: (0,0) (1,0) (0,1) (1,1).
      float2 corner = float2(float(vertexID & 1u), float((vertexID >> 1) & 1u));

      uint column = instanceID % uniforms.columns;
      uint row    = instanceID / uniforms.columns;

      // Integer tile coordinates converted exactly -- values are far below
      // 2^24, so no two runs can disagree about a vertex position.
      float2 tile = float2(float(column), float(row)) + corner;
      float2 grid = float2(float(uniforms.columns), float(uniforms.rows));
      float2 ndc  = (tile / grid) * 2.0 - 1.0;
      ndc.y = -ndc.y;   // top-left origin, matching the ASCII dump

      Instance inst = instances[uniforms.layerOffset + instanceID];

      VertexOut out;
      out.position = float4(ndc, 0.0, 1.0);
      out.atlasUV = float2((float(inst.glyph) + corner.x) / float(uniforms.glyphCount),
                           corner.y);
      out.foreground = float4(inst.foreground) / 255.0;
      out.background = float4(inst.background) / 255.0;
      return out;
  }

  fragment float4 tile_fragment(VertexOut in [[stage_in]],
                                texture2d<float> atlas [[texture(0)]])
  {
      constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
      float coverage = atlas.sample(nearest, in.atlasUV).r;
      // mix, not blend: the pass writes opaque colour, so draw order cannot
      // change the result.
      return float4(mix(in.background.rgb, in.foreground.rgb, coverage), 1.0);
  }
  """

/// Per-draw constants. Layout must match `Uniforms` in the shader.
private struct Uniforms {
  var columns: UInt32
  var rows: UInt32
  var glyphCount: UInt32
  var layerOffset: UInt32
}

/// Draws a `FrameSnapshot` as an instanced grid of glyph quads.
///
/// One instanced draw per layer, deepest first. There is no vertex buffer and
/// no index buffer: the vertex shader builds each quad from `vertex_id`, so the
/// only per-frame upload is the instance array itself — which, on unified
/// memory, the simulation can write directly into the buffer the GPU reads.
public final class TilemapRenderer {
  public let device: MTLDevice
  public let atlas: GlyphAtlas
  private let pipeline: MTLRenderPipelineState
  private let commandQueue: MTLCommandQueue

  /// One instance buffer per frame that may be in flight.
  ///
  /// A single shared buffer was safe only because every caller was `capture`,
  /// which does `waitUntilCompleted` before returning -- the GPU was always
  /// done reading before the CPU overwrote it. A display-link loop does not
  /// wait, so with one buffer the CPU would rewrite next frame's instances into
  /// memory the GPU is still sampling for the current one. The visible symptom
  /// is a torn or flickering frame under load rather than a crash, which is
  /// exactly the kind of defect an agent cannot see.
  ///
  /// The buffers rotate per `draw`. The contract that makes that sufficient is
  /// on the caller: **at most `maxFramesInFlight` command buffers may be
  /// outstanding at once.** `DisplayLoop` holds a semaphore of exactly this
  /// value; `capture` satisfies it trivially by waiting.
  private var instanceBuffers: [MTLBuffer?]
  private var instanceCapacities: [Int]
  private var frameSlot = 0

  /// How many frames may be in flight before a caller must wait.
  public static let maxFramesInFlight = 3

  public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

  public init(device: MTLDevice? = nil) throws {
    instanceBuffers = Array(repeating: nil, count: TilemapRenderer.maxFramesInFlight)
    instanceCapacities = Array(repeating: 0, count: TilemapRenderer.maxFramesInFlight)
    guard let device = device ?? MTLCreateSystemDefaultDevice() else {
      throw RenderError.noDevice
    }
    self.device = device

    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: shaderSource, options: nil)
    } catch {
      throw RenderError.shaderCompilationFailed("\(error)")
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "tile_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "tile_fragment")
    descriptor.colorAttachments[0].pixelFormat = TilemapRenderer.pixelFormat
    // Blending stays off: it is order-dependent, and DR-003 needs captures to
    // be reproducible regardless of draw scheduling.
    descriptor.colorAttachments[0].isBlendingEnabled = false

    do {
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      throw RenderError.pipelineCreationFailed("\(error)")
    }

    guard let queue = device.makeCommandQueue() else {
      throw RenderError.pipelineCreationFailed("command queue")
    }
    commandQueue = queue
    atlas = try GlyphAtlas(device: device)
  }

  /// A command buffer on the renderer's own queue.
  ///
  /// `capture` makes its own because it also reads pixels back. A display loop
  /// needs one it can `present` a drawable with, and sharing the queue is what
  /// keeps frame ordering well defined.
  public func makeCommandBuffer() -> MTLCommandBuffer? {
    commandQueue.makeCommandBuffer()
  }

  /// Encodes the snapshot into `target`.
  public func draw(
    _ snapshot: FrameSnapshot,
    into target: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) throws {
    guard !snapshot.isEmpty else { return }
    // Rotate before uploading, so this frame writes to a buffer no in-flight
    // command buffer is still reading. See `instanceBuffers`.
    frameSlot = (frameSlot + 1) % TilemapRenderer.maxFramesInFlight
    uploadInstances(snapshot.instances, into: frameSlot)

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw RenderError.encodingFailed("render command encoder")
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(atlas.texture, index: 0)

    let perLayer = snapshot.camera.tileCount
    // Deepest first so the focused layer overwrites what is beneath it.
    for layer in 0..<snapshot.layerCount {
      var uniforms = Uniforms(
        columns: UInt32(snapshot.camera.size.x),
        rows: UInt32(snapshot.camera.size.y),
        glyphCount: UInt32(atlas.glyphCount),
        layerOffset: UInt32(layer * perLayer)
      )
      encoder.setVertexBuffer(instanceBuffers[frameSlot], offset: 0, index: 0)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.drawPrimitives(
        type: .triangleStrip,
        vertexStart: 0,
        vertexCount: 4,
        instanceCount: perLayer
      )
    }
    encoder.endEncoding()
  }

  /// Renders offscreen and returns the pixels, bottom-padded rows removed.
  ///
  /// Shares the pass above rather than having its own path: a separate capture
  /// renderer could drift from what players see, and SC-002 would then be
  /// checking the wrong thing.
  public func capture(
    _ snapshot: FrameSnapshot,
    pixelsPerTile: Int = 8
  ) throws -> CapturedImage {
    let width = Int(snapshot.camera.size.x) * pixelsPerTile
    let height = Int(snapshot.camera.size.y) * pixelsPerTile
    guard width > 0, height > 0 else {
      throw RenderError.textureCreationFailed("zero-sized capture")
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: TilemapRenderer.pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else {
      throw RenderError.textureCreationFailed("capture target")
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      throw RenderError.encodingFailed("command buffer")
    }
    try draw(snapshot, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error {
      throw RenderError.encodingFailed("\(error)")
    }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
      target.getBytes(
        raw.baseAddress!,
        bytesPerRow: width * 4,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0
      )
    }
    return CapturedImage(
      width: width,
      height: height,
      bgra: pixels,
      tick: snapshot.tick,
      stateHash: snapshot.stateHash,
      camera: snapshot.camera,
      deviceName: device.name
    )
  }

  /// Copies the instance array into the shared buffer the GPU reads.
  ///
  /// **This function is deliberately non-throwing. Do not add `throws`.** See
  /// KI-001 in `docs/known-issues.md`: Swift 6.3.3 miscompiles this function in
  /// release builds, leaving `MTLBuffer.contents()` in `x21` — the arm64
  /// `swifterror` register — on a path that never throws. The caller in
  /// `dfsim shot` then reads a non-null `x21` as "a throw happened", hands the
  /// Metal-mapped pointer to `swift_getErrorValue`, and traps in
  /// `_swift_getClass` on a page that is not a Swift error box.
  ///
  /// Removing `throws` removes the error-return convention from the frame the
  /// optimizer is corrupting, and is the only change measured to survive the
  /// worst known arrangement (15/15 release captures trapped with `throws`,
  /// 0/15 without it, everything else held identical). The hoisted
  /// `destination` below is the second, independent mitigation — re-deriving
  /// the pointer inside the closure also reproduced the trap.
  ///
  /// A buffer allocation failure is unrecoverable and has no caller that could
  /// act on it, so it is a precondition rather than a thrown error.
  private func uploadInstances(_ instances: [TileInstance], into slot: Int) {
    let byteCount = instances.count * MemoryLayout<TileInstance>.stride
    guard byteCount > 0 else { return }

    if instanceCapacities[slot] < byteCount || instanceBuffers[slot] == nil {
      // `.storageModeShared` is the unified-memory payoff: the CPU writes and
      // the GPU reads the same pages, with no staging copy or upload step.
      guard
        let buffer = device.makeBuffer(length: max(byteCount, 4096), options: .storageModeShared)
      else {
        preconditionFailure("MTLDevice.makeBuffer returned nil for \(byteCount) bytes")
      }
      instanceBuffers[slot] = buffer
      instanceCapacities[slot] = buffer.length
    }

    guard let buffer = instanceBuffers[slot] else {
      preconditionFailure("instance buffer missing after allocation")
    }
    let destination = buffer.contents()
    instances.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      destination.copyMemory(from: UnsafeRawPointer(base), byteCount: byteCount)
    }
  }
}
