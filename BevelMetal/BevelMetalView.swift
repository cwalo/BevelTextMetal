import MetalKit
import MetalPerformanceShaders
import UIKit

/// Generates a signed-distance-field texture for a string of text. The CG
/// pipeline rasterizes the glyphs into a premultiplied RGBA cell (the format
/// CT renders into reliably), the alpha channel becomes a binary mask, and
/// 8SSEDT produces a smooth signed distance field which is uploaded as a
/// single-channel half-float texture for the shader to consume.
enum SDFGenerator {

    /// Reconstructs `font` at a new point size while preserving its identity.
    /// `UIFont(descriptor:size:)` is the right call for custom-named fonts but
    /// silently drops the weight (and monospaced-ness) of the system font
    /// family — for those we route through the matching system-font API with
    /// the weight pulled out of the descriptor.
    static func resized(_ font: UIFont, to newSize: CGFloat) -> UIFont {
        let family = font.familyName
        guard family.hasPrefix(".") else {
            return UIFont(descriptor: font.fontDescriptor, size: newSize)
        }

        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let raw = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        let weight = UIFont.Weight(rawValue: CGFloat(raw))

        if family.contains("Monospaced") {
            return UIFont.monospacedSystemFont(ofSize: newSize, weight: weight)
        }
        return UIFont.systemFont(ofSize: newSize, weight: weight)
    }

    static func generate(text: String,
                         font: UIFont,
                         kern: CGFloat,
                         pixelSize: CGSize,
                         cpuBlurPasses: Int,
                         device: MTLDevice) -> MTLTexture?
    {
        let w = max(1, Int(pixelSize.width))
        let h = max(1, Int(pixelSize.height))
        let pixelCount = w * h

        // --- CT-friendly RGBA bitmap; we read the alpha channel for the mask ---
        let bytesPerRow = w * 4
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 4)
        raw.initialize(repeating: 0, count: pixelCount * 4)
        defer { raw.deinitialize(count: pixelCount * 4); raw.deallocate() }

        guard let ctx = CGContext(data: raw,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))

        // Auto-fit the font so it spans ~85% of the texture's narrow side.
        // Kern is measured at the input size and scaled by the fit factor so
        // the visual spacing stays consistent regardless of auto-fit.
        let margin: CGFloat = 0.85
        let probeAttr = NSAttributedString(string: text,
                                           attributes: [.font: font, .kern: kern])
        let probeLine = CTLineCreateWithAttributedString(probeAttr)
        let probeB    = CTLineGetBoundsWithOptions(probeLine, .useGlyphPathBounds)
        let fitScale  = min((CGFloat(w) * margin) / max(probeB.width,  1),
                            (CGFloat(h) * margin) / max(probeB.height, 1))
        let drawFont  = resized(font, to: font.pointSize * fitScale)
        let drawKern  = kern * fitScale

        let attrStr = NSAttributedString(string: text,
                                         attributes: [.font: drawFont, .kern: drawKern])
        let line    = CTLineCreateWithAttributedString(attrStr)
        let bounds  = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(
            x: (CGFloat(w) - bounds.width)  / 2 - bounds.origin.x,
            y: (CGFloat(h) - bounds.height) / 2 - bounds.origin.y
        )
        CTLineDraw(line, ctx)

        // Binary mask from alpha channel — used by the EDT to fill in distances
        // far from the boundary. Sub-pixel boundary accuracy is recovered below.
        var inside = [Bool](repeating: false, count: pixelCount)
        for i in 0..<pixelCount {
            inside[i] = raw[i * 4 + 3] > 127
        }

        // 8SSEDT — pixel-quantized signed distance field.
        var signedPx = SDF8SSEDT.compute(inside: inside, w: w, h: h)

        // Sub-pixel refinement at the AA boundary. CT rendered the glyph with
        // anti-aliased edges; the alpha gradient there gives a sub-pixel
        // accurate distance to the true boundary as `(α - 0.5) / |∇α|`. This
        // replaces the EDT's pixel-quantized boundary with a smooth one.
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let alpha = Float(raw[i * 4 + 3]) * (1.0 / 255.0)
                guard alpha > 0.02 && alpha < 0.98 else { continue }
                let aL = Float(raw[(i - 1)     * 4 + 3]) * (1.0 / 255.0)
                let aR = Float(raw[(i + 1)     * 4 + 3]) * (1.0 / 255.0)
                let aU = Float(raw[(i - w)     * 4 + 3]) * (1.0 / 255.0)
                let aD = Float(raw[(i + w)     * 4 + 3]) * (1.0 / 255.0)
                let gx = (aR - aL) * 0.5
                let gy = (aD - aU) * 0.5
                let gMag = sqrt(gx * gx + gy * gy)
                guard gMag > 0.05 else { continue }
                signedPx[i] = (alpha - 0.5) / gMag
            }
        }

        // 8SSEDT propagates discrete `(dx, dy)` offsets, so iso-distance lines
        // away from the boundary are polygonal and show up as visible spokes
        // when the shader smoothsteps across them. Cascading the 5-tap
        // separable Gaussian smooths them (σ ≈ √passes of single-pass) while
        // preserving the AA-refined sdf=0 boundary, which is already a smooth
        // sub-pixel quantity that just gets propagated outward. Caller can
        // request 0 passes when GPU blur will run on the uploaded texture.
        for _ in 0..<cpuBlurPasses {
            signedPx = gaussianBlurSeparable5(signedPx, w: w, h: h)
        }

        // Normalize to ±1 across half the texture's longer side.
        let pxRange = Float(max(w, h)) * 0.5
        var sdfHalf = [UInt16](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let v = signedPx[i] / pxRange
            sdfHalf[i] = floatToHalf(v)
        }

        // Upload as r16Float — universally filterable on iOS GPUs. Includes
        // .shaderWrite so MPS Gaussian blur can target it as a destination.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0,
                    withBytes: sdfHalf,
                    bytesPerRow: w * MemoryLayout<UInt16>.stride)
        return tex
    }

    /// Separable 5-tap Gaussian (1-4-6-4-1 / 16) applied horizontally then
    /// vertically. ~3-pixel effective radius — enough to dissolve the polygon
    /// iso-lines of an integer-offset distance transform.
    private static func gaussianBlurSeparable5(_ src: [Float], w: Int, h: Int) -> [Float] {
        let invK: Float = 1.0 / 16.0
        var horiz = src
        for y in 0..<h {
            let row = y * w
            for x in 2..<(w - 2) {
                horiz[row + x] = (
                    src[row + x - 2]
                    + 4 * src[row + x - 1]
                    + 6 * src[row + x]
                    + 4 * src[row + x + 1]
                    + src[row + x + 2]
                ) * invK
            }
        }
        var out = horiz
        for y in 2..<(h - 2) {
            for x in 0..<w {
                out[y * w + x] = (
                    horiz[(y - 2) * w + x]
                    + 4 * horiz[(y - 1) * w + x]
                    + 6 * horiz[ y      * w + x]
                    + 4 * horiz[(y + 1) * w + x]
                    + horiz[(y + 2) * w + x]
                ) * invK
            }
        }
        return out
    }

    /// IEEE 754 binary32 → binary16, with rounding toward zero. Adequate for
    /// a normalized SDF clamped to ±1.
    private static func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp32 = Int((bits >> 23) & 0xFF) - 127
        let mant23 = bits & 0x7FFFFF
        if exp32 < -14 { return sign }                    // underflow → zero
        if exp32 > 15  { return sign | 0x7BFF }           // saturate to max half
        let exp16 = UInt16((exp32 + 15) & 0x1F) << 10
        let mant10 = UInt16(mant23 >> 13)
        return sign | exp16 | mant10
    }
}

private struct ShaderUniforms {
    var lightDir:    SIMD2<Float>   // 8 bytes
    var borderWidth: Float          // 4 bytes
    var _pad0:       Float = 0      // 4 bytes — float3 below needs 16B alignment
    var borderShadow: SIMD3<Float>  // stride 16 in Swift, matches MSL float3
    var borderLit:    SIMD3<Float>
    var faceFill:     SIMD3<Float>
}

enum BevelBlurMode {
    case none
    case cpu(passes: Int)        // CPU separable 5-tap Gaussian, σ ≈ √passes
    case metal(sigma: Float)     // MPSImageGaussianBlur on the GPU
}

/// Three-step preset for the beveled outer contour. Values are in normalized
/// SDF units — same space the shader does its smoothsteps in.
enum BevelWidth {
    case thin
    case medium
    case heavy

    var value: Float {
        switch self {
        case .thin:   return 0.0030
        case .medium: return 0.0050
        case .heavy:  return 0.0120
        }
    }
}

private let kDefaultBlurSigma: Float = 5.0

class BevelMetalView: MTKView {

    var text: String = "$2,000" { didSet { needsRebuild = true } }
    var labelFont: UIFont = .systemFont(ofSize: 260, weight: .heavy) {
        didSet { needsRebuild = true }
    }
    /// Per-character extra spacing in the label font's points.
    var kern: CGFloat = 0 { didSet { needsRebuild = true } }
    var bevelWidth: BevelWidth = .medium
    var lightDir = SIMD2<Float>(-0.7071, -0.7071)  // upper-left in screen-space
    var borderShadowColor = SIMD3<Float>(0.32, 0.32, 0.36)  // bevel's dark side
    var borderLitColor    = SIMD3<Float>(1.00, 1.00, 1.00)  // bevel's lit side
    var faceColor         = SIMD3<Float>(0.84, 0.84, 0.86)  // flat glyph interior
    var blurMode: BevelBlurMode = .metal(sigma: kDefaultBlurSigma) { didSet { needsRebuild = true } }

    private var commandQueue : MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var sdfTexture   : MTLTexture?
    private var lastBuiltSize: CGSize = .zero
    private var needsRebuild = false
    private let lightPanner  = LightPanner(frame: .zero)
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let buildQueue   = DispatchQueue(label: "BevelMetalView.SDF",
                                             qos: .userInitiated)
    /// Monotonically incremented per rebuild request. The completion handler
    /// only commits its result if this hasn't been bumped since it started,
    /// so quick parameter changes don't apply stale textures.
    private var buildGeneration: Int = 0
    /// The drawable size of the rebuild that's currently running, if any.
    /// Prevents `draw(in:)` from re-queueing a fresh build every frame while
    /// the texture is still being computed in the background.
    private var inFlightSize: CGSize?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        setup()
    }
    required init(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        guard let device else { return }
        clearColor = MTLClearColorMake(0.04, 0.04, 0.06, 1)
        colorPixelFormat = .bgra8Unorm
        delegate = self

        commandQueue = device.makeCommandQueue()

        // Light-panner subview: drag the circle inside the box to move the
        // light source. Box's center is "no light direction"; corner positions
        // correspond to the strongest diagonal lighting.
        addSubview(lightPanner)
        lightPanner.onPositionChanged = { [weak self] pos in
            let len = simd_length(pos)
            // A perfectly centered knob is "no direction" — just keep the
            // previous lightDir so the rendering doesn't flatten.
            if len > 0.05 {
                self?.lightDir = pos / len
            }
        }

        // Loading indicator shown while the SDF rebuild runs on the build
        // queue. The previous texture keeps rendering during the rebuild, so
        // this is a subtle "working" cue rather than a full-screen block.
        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        addSubview(activityIndicator)

        let lib = device.makeDefaultLibrary()!
        let pDesc = MTLRenderPipelineDescriptor()
        pDesc.vertexFunction   = lib.makeFunction(name: "fullscreenVertex")!
        pDesc.fragmentFunction = lib.makeFunction(name: "bevelFragment")!
        pDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        pDesc.colorAttachments[0].isBlendingEnabled = true
        pDesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        pDesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        pDesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        pDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try! device.makeRenderPipelineState(descriptor: pDesc)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGFloat = 120
        let margin: CGFloat = 20
        let yMargin = margin + safeAreaInsets.bottom
        lightPanner.frame = CGRect(
            x: bounds.maxX - size - margin,
            y: bounds.maxY - size - yMargin,
            width: size, height: size)

        activityIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func rebuildSDF(forDrawableSize size: CGSize) {
        guard let device, size.width > 0, size.height > 0 else { return }

        // A build is already running for this size, and no parameter has
        // changed — nothing to do until it completes.
        if inFlightSize == size, !needsRebuild { return }

        // We already have a fresh texture for this size.
        if size == lastBuiltSize, sdfTexture != nil, !needsRebuild { return }

        // Cap the SDF resolution so the EDT runs in a reasonable time. 4096
        // across the longer side gives sub-pixel sharpness when downsampled
        // to a Pro Max drawable; below that, the σ=5 MPS blur is large enough
        // relative to the glyph that the bevel turns blobby.
        let maxDim: CGFloat = 4096
        let aspect = size.width / size.height
        let pxSize: CGSize = aspect >= 1
            ? CGSize(width: maxDim, height: maxDim / aspect)
            : CGSize(width: maxDim * aspect, height: maxDim)

        // Snapshot every parameter the build depends on — they can change on
        // the main thread while we're working.
        let snapshotText = text
        let snapshotFont = labelFont
        let snapshotKern = kern
        let snapshotMode = blurMode
        let cpuPasses: Int = {
            if case let .cpu(passes) = snapshotMode { return passes }
            return 0
        }()

        needsRebuild = false
        inFlightSize = size
        buildGeneration += 1
        let myGen = buildGeneration
        activityIndicator.startAnimating()

        buildQueue.async { [weak self] in
            guard let self else { return }
            guard let raw = SDFGenerator.generate(text: snapshotText,
                                                  font: snapshotFont,
                                                  kern: snapshotKern,
                                                  pixelSize: pxSize,
                                                  cpuBlurPasses: cpuPasses,
                                                  device: device)
            else {
                DispatchQueue.main.async {
                    self.inFlightSize = nil
                    self.activityIndicator.stopAnimating()
                }
                return
            }

            let final: MTLTexture
            if case let .metal(sigma) = snapshotMode {
                final = self.applyMetalBlur(to: raw, sigma: sigma, device: device)
            } else {
                final = raw
            }

            DispatchQueue.main.async {
                // The most-recent generation always wins; older completions
                // just clear their in-flight marker.
                if myGen == self.buildGeneration {
                    self.sdfTexture    = final
                    self.lastBuiltSize = size
                    self.inFlightSize  = nil
                    self.activityIndicator.stopAnimating()
                }
            }
        }
    }

    /// Encodes an MPSImageGaussianBlur on the source SDF, writing to a fresh
    /// destination texture. Returns the destination, or `source` on failure.
    /// Synchronous so the texture is ready before `draw(in:)` samples it.
    private func applyMetalBlur(to source: MTLTexture,
                                sigma: Float,
                                device: MTLDevice) -> MTLTexture
    {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width, height: source.height,
            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let dst = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer()
        else { return source }

        let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: cmdBuf,
                    sourceTexture: source,
                    destinationTexture: dst)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return dst
    }
}

extension BevelMetalView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildSDF(forDrawableSize: size)
    }

    func draw(in view: MTKView) {
        if sdfTexture == nil || needsRebuild {
            var size = view.drawableSize
            if size.width <= 0 {
                size = CGSize(width:  bounds.width  * contentScaleFactor,
                              height: bounds.height * contentScaleFactor)
            }
            rebuildSDF(forDrawableSize: size)
        }

        // The first build is asynchronous — until it completes we have no SDF
        // to sample. Skip rendering this frame; MTKView will call us again at
        // the next vsync and the texture will be ready by then.
        guard let drawable = view.currentDrawable,
              let rpd      = view.currentRenderPassDescriptor,
              let sdf      = sdfTexture,
              let cmdBuf   = commandQueue.makeCommandBuffer(),
              let enc      = cmdBuf.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        var uniforms = ShaderUniforms(
            lightDir:     simd_normalize(lightDir),
            borderWidth:  bevelWidth.value,
            borderShadow: borderShadowColor,
            borderLit:    borderLitColor,
            faceFill:     faceColor)

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(sdf, index: 0)
        enc.setFragmentBytes(&uniforms,
                             length: MemoryLayout<ShaderUniforms>.stride,
                             index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
