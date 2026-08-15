// Compositor.swift
// GPU compositing: one screen frame + one optional camera frame -> one output
// frame at config.outputResolution.
//
// TRAP (project notes item 8): every expensive object here — MTLDevice,
// CIContext, CVPixelBufferPool, and the CIFilter instances — is created once
// in `prepare` and reused. Allocating a CIContext per frame is a documented,
// severe performance cliff and would make 4K60 impossible.
//
// TRAP (project notes item 7): the display is 1.545:1 and the output presets
// are 1.778:1. `composite` scales the screen image by ONE uniform factor,
// never two, and then either letterboxes or center-crops. Nothing is ever
// stretched.
//
// Concurrency: CIContext/CIFilter are not Sendable, so all of them live behind
// `lock` and the class is `@unchecked Sendable`. `composite` is fully
// serialized, which matches the single-pipeline usage.

import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import Metal

public final class Compositor: Compositing, @unchecked Sendable {

    /// Everything allocated by `prepare` and reused for the life of a
    /// recording.
    private struct Prepared {
        let device: any MTLDevice
        let context: CIContext
        let pool: CVPixelBufferPool
        let outputSize: CGSize
        let outputColorSpace: CGColorSpace
        /// Antialiased alpha disc used to mask the camera into a circle.
        let maskGradient: CIFilter & CIRadialGradient
        /// Solid disc of the border color drawn *behind* the camera disc; the
        /// visible result is a ring, because the camera disc covers the middle.
        let borderGradient: CIFilter & CIRadialGradient
        let lanczos: CIFilter & CILanczosScaleTransform
        let background: CIImage
    }

    private let lock = NSLock()
    private var prepared: Prepared?

    public init() {}

    // MARK: - Compositing

    public func prepare(config: RecordingConfig) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HaloError.compositingFailed("No Metal device available")
        }

        let size = config.outputResolution.pixelSize

        // TRAP (project notes item 6, COLOR): blending and scaling happen in a
        // LINEAR extended-range space matched to the delivery gamut, and the
        // result is converted exactly once, at render time, into the tagged
        // output space. Compositing directly in a gamma-encoded space darkens
        // antialiased edges and shifts the bubble border color.
        let workingName: CFString
        let outputName: CFString
        switch config.colorSpace {
        case .displayP3:
            workingName = CGColorSpace.extendedLinearDisplayP3
            outputName = CGColorSpace.displayP3
        case .sRGB:
            workingName = CGColorSpace.extendedLinearSRGB
            outputName = CGColorSpace.sRGB
        }
        guard
            let working = CGColorSpace(name: workingName),
            let output = CGColorSpace(name: outputName)
        else {
            throw HaloError.compositingFailed("Could not create color spaces for \(config.colorSpace)")
        }

        let context = CIContext(
            mtlDevice: device,
            options: [
                .workingColorSpace: working,
                .outputColorSpace: output,
                // Intermediates are useless to us: every frame is a fresh
                // image graph, so caching them just burns VRAM at 4K.
                .cacheIntermediates: false,
                .name: "HaloCompositor",
            ]
        )

        let pool = try Self.makePool(size: size)

        let prepared = Prepared(
            device: device,
            context: context,
            pool: pool,
            outputSize: size,
            outputColorSpace: output,
            maskGradient: CIFilter.radialGradient(),
            borderGradient: CIFilter.radialGradient(),
            lanczos: CIFilter.lanczosScaleTransform(),
            background: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: CGRect(origin: .zero, size: size))
        )

        lock.lock()
        self.prepared = prepared
        lock.unlock()
    }

    public func composite(
        screenFrame: VideoFrame,
        cameraFrame: VideoFrame?,
        config: RecordingConfig
    ) throws -> VideoFrame {
        lock.lock()
        defer { lock.unlock() }

        guard let state = prepared else {
            throw HaloError.invalidState("Compositor.composite called before prepare()")
        }
        guard state.outputSize == config.outputResolution.pixelSize else {
            throw HaloError.invalidState(
                "Compositor prepared for \(state.outputSize) but asked to composite at "
                    + "\(config.outputResolution.pixelSize); call prepare() again after a resolution change"
            )
        }

        let outputRect = CGRect(origin: .zero, size: state.outputSize)

        // --- Screen layer -------------------------------------------------
        // Note on coordinates: CoreImage is y-up with the origin at the bottom
        // left, and a CIImage made from a CVPixelBuffer round-trips back into a
        // CVPixelBuffer with the same convention, so all geometry below is
        // computed y-up. That is why "top" corners use large y values.
        let fitted = fitScreen(
            CIImage(cvPixelBuffer: screenFrame.pixelBuffer),
            into: outputRect,
            policy: config.aspectPolicy
        )
        var image = fitted.image

        // Letterbox bars. Only paid for when the fit actually leaves gaps.
        if image.extent.width < outputRect.width - 0.5
            || image.extent.height < outputRect.height - 0.5
        {
            image = image.composited(over: state.background)
        }

        // --- Camera bubble ------------------------------------------------
        // The bubble is measured against the VISIBLE PICTURE, not the output
        // frame. Under `.letterbox` those differ: every Mac panel is narrower
        // than 16:9, so the fit leaves pillarbox bars, and anchoring the
        // bubble to the file's edge would float a third of it out on the black
        // bar. `contentRect` is the rect the scaled screen actually occupies,
        // which equals `outputRect` under `.crop`.
        if let cameraFrame,
            let bubble = makeBubble(
                camera: CIImage(cvPixelBuffer: cameraFrame.pixelBuffer),
                geometry: config.bubble,
                contentRect: fitted.contentRect,
                state: state
            )
        {
            image = bubble.composited(over: image)
        }

        image = image.cropped(to: outputRect)

        // --- Render -------------------------------------------------------
        let destination = try Self.dequeue(from: state.pool)
        Self.tagColor(destination, policy: config.colorSpace)
        state.context.render(
            image,
            to: destination,
            bounds: outputRect,
            colorSpace: state.outputColorSpace
        )

        // Timing is inherited verbatim from the screen frame: the screen
        // stream owns the master fixed cadence (project notes item 2), and its
        // PTS is already normalized to start-of-recording (item 3).
        return VideoFrame(
            pixelBuffer: destination,
            presentationTime: screenFrame.presentationTime,
            captureHostTime: screenFrame.captureHostTime
        )
    }

    // MARK: - Geometry

    /// Scale the screen image into `outputRect` with a SINGLE uniform factor,
    /// then center it. `.letterbox` fits the whole frame inside (bars remain);
    /// `.crop` fills the frame and lets the overflow fall outside the rect,
    /// where the final `cropped(to:)` discards it. Never stretched — that
    /// would need two different factors (project notes item 7).
    ///
    /// Returns both the transformed image and `contentRect`: the part of
    /// `outputRect` the picture actually covers. Under `.letterbox` that is
    /// smaller than `outputRect` on one axis (the bars); under `.crop` it is
    /// `outputRect` exactly. Bubble geometry is measured against it so the
    /// bubble never sits on a black bar.
    private func fitScreen(
        _ image: CIImage,
        into outputRect: CGRect,
        policy: AspectPolicy
    ) -> (image: CIImage, contentRect: CGRect) {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return (image, outputRect) }

        let sx = outputRect.width / source.width
        let sy = outputRect.height / source.height
        let scale: CGFloat
        switch policy {
        case .letterbox: scale = min(sx, sy)
        case .crop: scale = max(sx, sy)
        }

        let scaledWidth = source.width * scale
        let scaledHeight = source.height * scale
        let tx = (outputRect.width - scaledWidth) / 2 - source.minX * scale
        let ty = (outputRect.height - scaledHeight) / 2 - source.minY * scale

        var transform = CGAffineTransform(translationX: tx, y: ty)
        transform = transform.scaledBy(x: scale, y: scale)

        // Under `.crop` the scaled image overhangs the frame and the final
        // `cropped(to:)` discards the overflow, so the visible content rect is
        // the intersection, never the full scaled extent.
        let placed = CGRect(
            x: (outputRect.width - scaledWidth) / 2,
            y: (outputRect.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        let visible = placed.intersection(outputRect)
        return (
            image.transformed(by: transform, highQualityDownsample: scale < 1),
            visible.isNull ? outputRect : visible
        )
    }

    /// Circle-masked camera bubble, already positioned in output coordinates,
    /// or nil if the camera frame is degenerate.
    ///
    /// Order of operations matters: center-crop to a SQUARE first, then scale,
    /// then mask. Masking a non-square frame with a circle would crop off the
    /// sides of the subject's face instead of the sides of the frame.
    private func makeBubble(
        camera: CIImage,
        geometry: BubbleGeometry,
        contentRect: CGRect,
        state: Prepared
    ) -> CIImage? {
        let source = camera.extent
        guard source.width > 1, source.height > 1 else { return nil }
        guard contentRect.width > 1, contentRect.height > 1 else { return nil }

        // Bubble metrics are fractions of the SHORTER side of the VISIBLE
        // PICTURE, so a 1080p and a 4K recording look identical when scaled to
        // the same size, and a letterboxed recording keeps the bubble inside
        // the picture instead of half-on the black bar.
        let minSide = min(contentRect.width, contentRect.height)
        let diameter = max(8, geometry.diameterFraction * minSide)
        let margin = geometry.marginFraction * minSide
        let outerRadius = diameter / 2
        let borderWidth = max(0, geometry.borderWidthFraction * diameter)
        let innerRadius = max(2, outerRadius - borderWidth)

        let cx: CGFloat
        let cy: CGFloat
        switch geometry.corner {
        case .topLeft:
            cx = contentRect.minX + margin + outerRadius
            cy = contentRect.maxY - margin - outerRadius
        case .topRight:
            cx = contentRect.maxX - margin - outerRadius
            cy = contentRect.maxY - margin - outerRadius
        case .bottomLeft:
            cx = contentRect.minX + margin + outerRadius
            cy = contentRect.minY + margin + outerRadius
        case .bottomRight:
            cx = contentRect.maxX - margin - outerRadius
            cy = contentRect.minY + margin + outerRadius
        }
        let center = CGPoint(x: cx, y: cy)

        // 1. Center-crop to a square.
        let side = min(source.width, source.height)
        let square = CGRect(
            x: source.midX - side / 2,
            y: source.midY - side / 2,
            width: side,
            height: side
        )
        var bubble = camera.cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))

        // 2. Scale the square to the inner (camera) diameter. Webcam frames are
        // far larger than the bubble, so this is a heavy downscale — Lanczos
        // instead of the default affine sampling, otherwise the bubble aliases
        // and shimmers on any detailed background.
        let scale = (innerRadius * 2) / side
        if scale < 1 {
            state.lanczos.inputImage = bubble
            state.lanczos.scale = Float(scale)
            state.lanczos.aspectRatio = 1
            bubble = state.lanczos.outputImage ?? bubble.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
        } else {
            bubble = bubble.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        bubble = bubble.transformed(
            by: CGAffineTransform(
                translationX: center.x - innerRadius,
                y: center.y - innerRadius
            )
        )

        // 3. Circular alpha mask with a one-pixel antialiased falloff. A hard
        // mask would leave a visibly jagged bubble edge at any resolution.
        let maskRect = CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )
        state.maskGradient.center = center
        state.maskGradient.radius0 = Float(max(0, innerRadius - 0.75))
        state.maskGradient.radius1 = Float(innerRadius)
        state.maskGradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        // Same RGB with zero alpha, not "clear black": interpolating toward a
        // different RGB would darken the edge pixels.
        state.maskGradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        guard let mask = state.maskGradient.outputImage?.cropped(to: maskRect) else {
            return nil
        }
        // Source-in multiplies the camera by the mask's alpha, so the falloff
        // becomes a genuinely antialiased edge rather than a stencil.
        bubble = bubble.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: mask]
        )

        // 4. Border ring: a filled disc of the border color at the OUTER
        // radius, drawn behind the camera disc. Only the annulus the camera
        // does not cover is visible, so no explicit ring geometry is needed.
        guard borderWidth > 0.5, geometry.borderColor.alpha > 0 else { return bubble }
        let border = CIColor(cgColor: geometry.borderColor.cgColor)
        state.borderGradient.center = center
        state.borderGradient.radius0 = Float(max(0, outerRadius - 0.75))
        state.borderGradient.radius1 = Float(outerRadius)
        state.borderGradient.color0 = border
        state.borderGradient.color1 = CIColor(
            red: border.red,
            green: border.green,
            blue: border.blue,
            alpha: 0
        )
        let borderRect = CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        )
        guard let ring = state.borderGradient.outputImage?.cropped(to: borderRect) else {
            return bubble
        }
        return bubble.composited(over: ring)
    }

    // MARK: - Pixel buffer pool

    private static func makePool(size: CGSize) throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            // IOSurface backing is what keeps the buffer on the GPU all the way
            // through CoreImage -> VideoToolbox with no CPU copy.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw HaloError.compositingFailed(
                "CVPixelBufferPoolCreate failed for \(Int(size.width))x\(Int(size.height)) (status \(status))"
            )
        }
        return pool
    }

    private static func dequeue(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        // A hard allocation ceiling: without it, a stalled encoder would let the
        // pool grow without bound (33 MB per 4K BGRA frame adds up fast).
        let auxiliary: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 12
        ]
        var buffer: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxiliary as CFDictionary,
            &buffer
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            // Reclaim anything the downstream has already released, then retry
            // once before giving up on this frame.
            CVPixelBufferPoolFlush(pool, .excessBuffers)
            status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxiliary as CFDictionary,
                &buffer
            )
        }
        guard status == kCVReturnSuccess, let buffer else {
            throw HaloError.compositingFailed(
                "Could not dequeue an output pixel buffer (status \(status))"
            )
        }
        return buffer
    }

    /// Stamp the output buffer with explicit color tags.
    ///
    /// TRAP (project notes item 6): an untagged buffer makes AVAssetWriter
    /// guess, and the guess is usually Rec.709 — which renders a Display P3
    /// capture oversaturated on a wide-gamut display. Recorder writes matching
    /// tags on the track; these attachments make the buffers themselves agree.
    private static func tagColor(_ buffer: CVPixelBuffer, policy: ColorSpacePolicy) {
        let primaries: CFString
        let transfer: CFString
        switch policy {
        case .displayP3:
            primaries = kCVImageBufferColorPrimaries_P3_D65
            transfer = kCVImageBufferTransferFunction_sRGB
        case .sRGB:
            primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate)
    }
}
