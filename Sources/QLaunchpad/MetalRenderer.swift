import AppKit
import Metal
import MetalKit
import QuartzCore
import QLaunchpadCore
import simd

// MARK: - GPU instance layout (three float4s, 48-byte stride)

/// One quad. Keeping every field at `float4` alignment makes the Swift and Metal
/// layouts identical and also lets individual sprites be addressed safely by a
/// byte offset in a frame-local buffer.
private struct SpriteInstance {
    /// xy = center (top-left view pts), zw = size (pts)
    var centerSize: SIMD4<Float>
    /// xy = atlas UV origin (top-left), zw = atlas UV size
    var uvRect: SIMD4<Float>
    /// x = kind (0 focus plate, 1 icon, 2 pressed icon, 3 text), y = alpha,
    /// z = 1 snap text origin + size to framebuffer pixels
    var kindAlpha: SIMD4<Float>

    static func focus(center: CGPoint, size: CGFloat, alpha: Float) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size), Float(size)),
            uvRect: SIMD4(0, 0, 1, 1),
            kindAlpha: SIMD4(0, alpha, 0, 0)
        )
    }

    static func icon(
        center: CGPoint,
        size: CGFloat,
        uv: SIMD4<Float>,
        alpha: Float,
        pressed: Bool
    ) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size), Float(size)),
            uvRect: uv,
            kindAlpha: SIMD4(pressed ? 2 : 1, alpha, 0, 0)
        )
    }

    static func label(
        center: CGPoint,
        size: CGSize,
        uv: SIMD4<Float>,
        alpha: Float,
        snapToPixels: Bool
    ) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size.width), Float(size.height)),
            uvRect: uv,
            kindAlpha: SIMD4(3, alpha, snapToPixels ? 1 : 0, 0)
        )
    }

}

private struct FrameUniforms {
    var viewport: SIMD2<Float>
    /// Framebuffer pixels. Text snap uses `drawable / viewport`.
    var drawable: SIMD2<Float>
    /// x: icon filter mode (1 = quality binomial, 0 = performance).
    var mode: SIMD2<Float> = .zero
}

private struct TextBatch {
    let sheet: Int
    let range: Range<Int>
}

private struct AppListSignature: Equatable, Sendable {
    let ids: [String]

    init(apps: [AppInfo]) {
        ids = apps.map(\.id)
    }

    init(items: [LaunchpadItem]) {
        ids = items.map(\.id)
    }

    func matches(_ apps: [AppInfo]) -> Bool {
        guard ids.count == apps.count else { return false }
        return zip(ids, apps).allSatisfy { $0 == $1.id }
    }

    func matches(_ items: [LaunchpadItem]) -> Bool {
        guard ids.count == items.count else { return false }
        return zip(ids, items).allSatisfy { $0 == $1.id }
    }
}

private struct TextAtlasSignature: Equatable, Sendable {
    let apps: AppListSignature
    let scale: CGFloat
    let options: TextAtlas.Options

    init(apps: [AppInfo], scale: CGFloat, options: TextAtlas.Options) {
        self.apps = AppListSignature(apps: apps)
        self.scale = scale
        self.options = options
    }

    func matches(_ displayedApps: [AppInfo], scale: CGFloat, options: TextAtlas.Options) -> Bool {
        self.scale == scale && self.options == options && apps.matches(displayedApps)
    }
}

/// Identity of the icon GPU cache window (catalog + visible list + page + quality).
private struct IconPrewarmSignature: Equatable, Sendable {
    let catalog: AppListSignature
    /// Root / folder / search list currently shown (search changes this without
    /// changing the full catalog).
    let display: AppListSignature
    let page: Int
    let quality: String
}

/// Reusable GPU storage for one in-flight frame. A slot is not written again
/// until Metal completes the command buffer that references it.
private final class FrameResources {
    let availability = DispatchSemaphore(value: 1)
    var iconBuffer: MTLBuffer?
    var iconCapacity = 0
    var textBuffer: MTLBuffer?
    var textCapacity = 0
}

// MARK: - Launchpad Metal view

@MainActor
final class LaunchpadMetalView: MTKView, MTKViewDelegate {
    private let store: AppStore
    private let commandQueue: MTLCommandQueue
    private let iconPipelineFloat16: MTLRenderPipelineState
    private let textPipelineFloat16: MTLRenderPipelineState
    private let iconPipelineUnorm8: MTLRenderPipelineState
    private let textPipelineUnorm8: MTLRenderPipelineState
    private let iconTextures: IconTextureStore
    private let folderIconTextures: FolderIconTextureStore
    private let textAtlas: TextAtlas

    private var iconSampler: MTLSamplerState!
    private var textSampler: MTLSamplerState!

    private var currentPageOffset = 0.0
    private var lastRenderQuality = IconRenderQuality.current
    private var lastCatalogSignature: AppListSignature?
    private var lastTextSignature: TextAtlasSignature?
    private var pendingTextSignature: TextAtlasSignature?
    private var textAtlasBuildTask: Task<Void, Never>?
    private var lastFrameTime = CACurrentMediaTime()
    /// Prewarm only a sliding page window — full-catalog upload was hundreds of MB.
    private var resourcePrewarmSignature: IconPrewarmSignature?
    private var resourcePrewarmTask: Task<Void, Never>?
    private var isResourcePrewarmingPaused = false
    private var lastTextureWindowPage: Int = -1
    /// Low-memory only: IDs whose texture was missing on a previous drawn frame.
    private var iconsMissingTexture: Set<String> = []
    /// Low-memory only: fade-in start time after an async bake lands.
    private var iconRevealStartedAt: [String: CFTimeInterval] = [:]
    private let iconRevealDuration: CFTimeInterval = 0.2
    /// True while a quality switch is filling caches — skip fade so modes compare cleanly.
    private var suppressLazyIconReveal = false
    private var firstFrameWaiters: [() -> Void] = []
    private var isFirstFrameCompletionScheduled = false

    private let inFlightFrameCount = 3
    private let inFlightFrames: [FrameResources]
    private var nextFrameIndex = 0
    private var iconDrawTextures: [MTLTexture] = []
    private var iconSprites: [SpriteInstance] = []
    private var labelsBySheet: [[SpriteInstance]] = []
    private var textSprites: [SpriteInstance] = []
    private var textBatches: [TextBatch] = []

    private var dragSource: Int?
    private var draggedAppID: String?
    private var dragGeneration: UInt64 = 0
    private var dragDestination: Int?
    private var dragStart: CGPoint = .zero
    /// Current pointer position in top-left view coordinates.
    private var dragPoint: CGPoint = .zero
    /// Keeps the icon under the same part of the pointer that was clicked.
    private var dragGrabOffset: CGPoint = .zero
    private var edgePageDirection = 0
    private var lastEdgePageTurnTime: CFTimeInterval = 0
    private var dragHoverTargetID: String?
    private var dragHoverVisualTargetID: String?
    private var dragHoverProgress: CGFloat = 0
    private var didDrag = false
    private var isPanningPage = false
    private var pageIndicatorClick = false
    private var panLastPoint: CGPoint = .zero
    private var contextMenuApp: AppInfo?
    private var contextMenuFolder: AppFolder?

    // Keep visual positions separate from the catalog order so reordering an
    // item does not make the surrounding icons jump to their new cells.
    private var reorderVisualSlots: [String: Double] = [:]
    private var isReorderAnimationActive = false
    private let reorderAnimationRate = 20.0

    private struct DragReleaseAnimation {
        let itemID: String
        let from: CGPoint
        let startTime: CFTimeInterval
    }
    private var dragReleaseAnimation: DragReleaseAnimation?
    private let dragReleaseDuration: CFTimeInterval = 0.24

    private var displayLink: CADisplayLink?
    private var animatingPresentation = false
    private var contentScale: CGFloat = 1
    /// Start visible so a missed present-notification never leaves a blank grid.
    private var contentAlpha: CGFloat = 1
    private var iconEntranceProgress: CGFloat = 1
    private var presentationPhase: CGFloat = 1
    private var isShowingPresentation = false
    private var isPrimingPresentationFrame = false
    private var presentationStyle: LaunchpadAnimationStyle = .fly
    private var stationaryDismissedAppID: String?

    private let pageSpringResponse: Double = 22
    private let edgePageInset: CGFloat = 72
    private let edgePageTurnDelay: CFTimeInterval = 0.45
    private var presentStartTime: CFTimeInterval = 0
    private var presentFrom: CGFloat = 0
    private var presentTo: CGFloat = 1
    private var presentDurationActive: CFTimeInterval = 1.3

    // Content view transition: sequential fade-out → swap → fade-in.
    private var displayedItems: [LaunchpadItem] = []
    private var pendingDisplayItems: [LaunchpadItem]?
    private var lastDisplaySignature: AppListSignature?
    private enum ContentTransitionPhase { case idle, fadingOut, fadingIn }
    private var contentTransitionPhase: ContentTransitionPhase = .idle
    private var contentTransitionStart: CFTimeInterval = 0
    private var contentTransitionAlpha: Float = 1
    private var frozenPageOffset: Double = 0
    private let contentTransitionHalfDuration: CFTimeInterval = 0.15

    // MARK: Init

    init(store: AppStore) {
        self.store = store
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal is required by QLaunch")
        }
        self.commandQueue = commandQueue
        iconTextures = IconTextureStore(device: device)
        folderIconTextures = FolderIconTextureStore(device: device)
        textAtlas = TextAtlas(device: device)
        inFlightFrames = (0..<3).map { _ in FrameResources() }

        let librarySource = Self.shaderSource
        guard let library = try? device.makeLibrary(source: librarySource, options: nil),
              let vertex = library.makeFunction(name: "ql_vertex"),
              let iconFrag = library.makeFunction(name: "ql_icon_fragment"),
              let textFrag = library.makeFunction(name: "ql_text_fragment") else {
            fatalError("Unable to compile QLaunch shaders")
        }

        // Quality: linear float16 drawable. Performance / low memory: 8-bit
        // Display P3 (not sRGB). An sRGB drawable encodes premul as sRGB(C*a),
        // but the window server wants sRGB(C)*a — that warp turns AA into jaggies.
        guard
            let pipelines16 = Self.makeSpritePipelines(
                device: device,
                vertex: vertex,
                iconFragment: iconFrag,
                textFragment: textFrag,
                pixelFormat: .rgba16Float
            ),
            let pipelines8 = Self.makeSpritePipelines(
                device: device,
                vertex: vertex,
                iconFragment: iconFrag,
                textFragment: textFrag,
                pixelFormat: .bgra8Unorm
            )
        else {
            fatalError("Unable to create sprite pipelines")
        }
        iconPipelineFloat16 = pipelines16.icon
        textPipelineFloat16 = pipelines16.text
        iconPipelineUnorm8 = pipelines8.icon
        textPipelineUnorm8 = pipelines8.text

        super.init(frame: .zero, device: device)
        delegate = self
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = min(120, NSScreen.main?.maximumFramesPerSecond ?? 60)
        framebufferOnly = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        wantsLayer = true
        layer?.isOpaque = false
        autoResizeDrawable = true
        applyDrawableConfiguration(for: IconRenderQuality.current)

        let iconSamp = MTLSamplerDescriptor()
        iconSamp.minFilter = .linear
        iconSamp.magFilter = .linear
        iconSamp.mipFilter = .notMipmapped
        iconSamp.sAddressMode = .clampToEdge
        iconSamp.tAddressMode = .clampToEdge
        iconSampler = device.makeSamplerState(descriptor: iconSamp)

        let textSamp = MTLSamplerDescriptor()
        textSamp.minFilter = .linear
        textSamp.magFilter = .linear
        textSamp.sAddressMode = .clampToEdge
        textSamp.tAddressMode = .clampToEdge
        textSampler = device.makeSamplerState(descriptor: textSamp)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .qlaunchpadStoreChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(presentationChanged(_:)),
            name: .qlaunchpadPresentationChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clearCacheRequested),
            name: .qlaunchpadCacheClearRequested, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(renderQualityChanged),
            name: .qlaunchpadRenderQualityChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(iconTexturesUpdated),
            name: .qlaunchpadIconTexturesUpdated, object: nil
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        resourcePrewarmTask?.cancel()
        textAtlasBuildTask?.cancel()
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private var activeIconPipeline: MTLRenderPipelineState {
        IconRenderQuality.current.usesUnorm8Drawable ? iconPipelineUnorm8 : iconPipelineFloat16
    }

    private var activeTextPipeline: MTLRenderPipelineState {
        IconRenderQuality.current.usesUnorm8Drawable ? textPipelineUnorm8 : textPipelineFloat16
    }

    private static func makeSpritePipelines(
        device: MTLDevice,
        vertex: MTLFunction,
        iconFragment: MTLFunction,
        textFragment: MTLFunction,
        pixelFormat: MTLPixelFormat
    ) -> (icon: MTLRenderPipelineState, text: MTLRenderPipelineState)? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = iconFragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let icon = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        desc.fragmentFunction = textFragment
        guard let text = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        return (icon, text)
    }

    /// Match the layer to the active quality. Performance / low memory: 8-bit
    /// Display P3. Only `colorPixelFormat` is updated live — replacing
    /// `CAMetalLayer` breaks MTKView's drawable until relaunch. Drawable count
    /// is init-only.
    private func applyDrawableConfiguration(for quality: IconRenderQuality) {
        let format: MTLPixelFormat = quality.usesUnorm8Drawable ? .bgra8Unorm : .rgba16Float
        colorPixelFormat = format
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.pixelFormat = format
        if appliedDrawableCount == nil {
            metalLayer.maximumDrawableCount = quality.maximumDrawableCount
            appliedDrawableCount = quality.maximumDrawableCount
        }
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        // 8-bit: shader emits gamma-premul Display P3 (`sRGB(C)*a`). Quality
        // stays linear float16 for the EDR compositor.
        metalLayer.colorspace = CGColorSpace(
            name: quality.usesUnorm8Drawable
                ? CGColorSpace.displayP3
                : CGColorSpace.extendedLinearDisplayP3
        )
    }

    private var appliedDrawableCount: Int?

    private var textAtlasOptions: TextAtlas.Options {
        switch IconRenderQuality.current {
        case .quality: .standard
        case .performance: .performance
        case .lowMemory: .lowMemory
        }
    }

    // MARK: Shader source

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Sprite {
        float4 centerSize; // xy center, zw size (points, top-left y)
        float4 uvRect;     // xy origin, zw size (Metal top-left UV)
        float4 kindAlpha;  // x kind, y alpha, z snap-to-pixel
    };
    struct Uniforms {
        float2 viewport;
        float2 drawable;
        // x: 1 = quality (4×4 binomial), 0 = performance (bilinear)
        float2 mode;
    };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float kind;
        float alpha;
    };

    // Display P3 uses the sRGB OETF. Convert linear premul → gamma premul so
    // a transparent 8-bit layer composites with sRGB(C)*a, not sRGB(C*a).
    float ql_linear_to_srgb(float x) {
        x = saturate(x);
        if (x <= 0.0031308) return x * 12.92;
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    }

    float4 ql_present(float4 c, float encodeGammaPremul) {
        if (encodeGammaPremul < 0.5) return c;
        float a = saturate(c.a);
        if (a <= 1.0e-6) return float4(0.0);
        float3 straight = saturate(c.rgb / a);
        float3 encoded = float3(
            ql_linear_to_srgb(straight.r),
            ql_linear_to_srgb(straight.g),
            ql_linear_to_srgb(straight.b)
        );
        return float4(encoded * a, a);
    }

    vertex VertexOut ql_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        device const Sprite *sprites [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]])
    {
        // Unit quad corners in local space (-0.5…0.5).
        const float2 corners[6] = {
            float2(-0.5, -0.5), float2( 0.5, -0.5), float2(-0.5,  0.5),
            float2(-0.5,  0.5), float2( 0.5, -0.5), float2( 0.5,  0.5)
        };
        Sprite s = sprites[iid];
        float2 local = corners[vid];
        float2 pixel = s.centerSize.xy + local * s.centerSize.zw;
        // Resting labels: snap origin and size in framebuffer pixels so a
        // 1:1 atlas quad cannot pick up a half-pixel from Float / NDC.
        if (s.kindAlpha.z > 0.5 && u.drawable.x > 0.5 && u.viewport.x > 0.5) {
            float2 origin = s.centerSize.xy - 0.5 * s.centerSize.zw;
            float2 originPx = origin / u.viewport * u.drawable;
            float2 sizePx = s.centerSize.zw / u.viewport * u.drawable;
            originPx = floor(originPx + 0.5);
            sizePx = floor(sizePx + 0.5);
            float2 fb = originPx + (local + 0.5) * sizePx;
            pixel = fb / u.drawable * u.viewport;
        }
        // Top-left pixel space → NDC (y flips).
        float2 ndc = float2(
            pixel.x / u.viewport.x * 2.0 - 1.0,
            1.0 - pixel.y / u.viewport.y * 2.0
        );
        VertexOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = s.uvRect.xy + (local + 0.5) * s.uvRect.zw;
        o.kind = s.kindAlpha.x;
        o.alpha = s.kindAlpha.y;
        return o;
    }

    fragment float4 ql_icon_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant Uniforms &u [[buffer(1)]])
    {
        if (in.kind < 0.5) {
            // A fourth-order superellipse closely follows the continuous rounded
            // silhouette used by modern macOS app icons.
            float2 p = abs(in.uv - 0.5) * 2.0;
            float shape = pow(p.x, 4.0) + pow(p.y, 4.0);
            float feather = max(fwidth(shape) * 0.75, 0.002);
            float coverage = 1.0 - smoothstep(1.0 - feather, 1.0 + feather, shape);
            float a = coverage * 0.34 * in.alpha;
            return ql_present(float4(0.0, 0.0, 0.0, a), 1.0 - u.mode.x);
        }

        // sample(): quality = rgba16Float linear; performance = rgba8Unorm_srgb
        // (hardware decodes to the same linear light domain).
        float4 c;
        if (u.mode.x > 0.5) {
            // Quality: 4x linear float16 + 4×4 separable binomial in screen space.
            const float offsets[4] = { -0.75, -0.25, 0.25, 0.75 };
            const float weights[4] = { 1.0, 3.0, 3.0, 1.0 };
            float2 pixelDx = dfdx(in.uv);
            float2 pixelDy = dfdy(in.uv);
            c = float4(0.0);
            for (uint y = 0; y < 4; ++y) {
                for (uint x = 0; x < 4; ++x) {
                    float2 sampleUV = in.uv
                        + pixelDx * offsets[x]
                        + pixelDy * offsets[y];
                    c += atlas.sample(samp, sampleUV) * weights[x] * weights[y];
                }
            }
            c *= (1.0 / 64.0);
        } else {
            // Performance: 2x sRGB 8-bit — hardware bilinear in decoded linear light.
            // Multi-tap when clearly minifying (entrance scale / zoom).
            float2 texSize = float2(atlas.get_width(), atlas.get_height());
            float2 uvDx = dfdx(in.uv);
            float2 uvDy = dfdy(in.uv);
            float footprint = max(length(uvDx * texSize), length(uvDy * texSize));
            if (footprint <= 1.4) {
                c = atlas.sample(samp, in.uv);
            } else {
                const float o = 0.3;
                c = (
                    atlas.sample(samp, in.uv + uvDx * (-o) + uvDy * (-o))
                  + atlas.sample(samp, in.uv + uvDx * ( o) + uvDy * (-o))
                  + atlas.sample(samp, in.uv + uvDx * (-o) + uvDy * ( o))
                  + atlas.sample(samp, in.uv + uvDx * ( o) + uvDy * ( o))
                ) * 0.25;
            }
        }
        float pressed = (in.kind > 1.5 && in.kind < 2.5) ? 0.4 : 1.0;
        // Pressed brightness is a real premultiplied opacity, not an RGB-only
        // darkening. Keeping RGB and alpha on the same curve prevents a launched
        // icon from appearing to brighten when its dismissal fade begins.
        return ql_present(c * (in.alpha * pressed), 1.0 - u.mode.x);
    }

    fragment float4 ql_text_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler samp [[sampler(0)]],
        constant Uniforms &u [[buffer(1)]])
    {
        // Atlas already matches the drawable (linear float16 or gamma P3).
        // Do not run ql_present: it would decode encoded 8-bit coverage twice.
        return atlas.sample(samp, in.uv) * in.alpha;
    }
    """

    // MARK: Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        let maxFps = Float(min(120, NSScreen.main?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxFps, preferred: maxFps)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTime = CACurrentMediaTime()
    }

    private func stopDisplayLinkIfIdle() {
        let pageSettled = abs(store.targetPage - currentPageOffset) < 0.0008
        let dragInteractionActive = didDrag && draggedAppID != nil
        if pageSettled
            && !animatingPresentation
            && contentTransitionPhase == .idle
            && !isReorderAnimationActive
            && !dragInteractionActive
            && dragReleaseAnimation == nil
            && dragHoverProgress < 0.001
            && iconRevealStartedAt.isEmpty
        {
            displayLink?.invalidate()
            displayLink = nil
            if abs(store.pageOffset - currentPageOffset) > 0.0001 {
                store.pageOffset = currentPageOffset
            }
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if let point = syncDragPointToMouse() {
            if store.openedFolderID != nil {
                updateFolderDrag(at: point)
            } else {
                updateReorderDestination(at: point)
            }
        }
        tickEdgePageTurn(now: CACurrentMediaTime())
        needsDisplay = true
    }

    private func setDragHoverTarget(_ id: String?) {
        dragHoverTargetID = id
        if let id, dragHoverVisualTargetID != id {
            dragHoverVisualTargetID = id
            dragHoverProgress = 0
        }
        startDisplayLink()
    }

    private func tickDragVisualAnimations(now: CFTimeInterval, dt: CFTimeInterval) {
        let hoverTarget: CGFloat = didDrag && dragHoverTargetID != nil ? 1 : 0
        let hoverStep = CGFloat(1 - exp(-dt * 18))
        dragHoverProgress += (hoverTarget - dragHoverProgress) * hoverStep
        if hoverTarget == 0, dragHoverProgress < 0.001 {
            dragHoverProgress = 0
            dragHoverVisualTargetID = nil
        }

        if let animation = dragReleaseAnimation,
           now - animation.startTime >= dragReleaseDuration {
            dragReleaseAnimation = nil
        }
    }

    private func beginDragReleaseAnimation(itemID: String) {
        dragReleaseAnimation = DragReleaseAnimation(
            itemID: itemID,
            from: CGPoint(
                x: dragPoint.x - dragGrabOffset.x,
                y: dragPoint.y - dragGrabOffset.y
            ),
            startTime: CACurrentMediaTime()
        )
        startDisplayLink()
    }

    /// AppKit can coalesce mouse-drag events. Read the current screen pointer
    /// on every display-link tick so the dragged sprite never waits for the
    /// next delivered event before moving.
    private func syncDragPointToMouse() -> CGPoint? {
        guard didDrag, draggedAppID != nil, let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(windowPoint, from: nil)
        dragPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        updateEdgePageDirection(for: point)
        return point
    }

    private func updateEdgePageDirection(for point: CGPoint) {
        guard didDrag, draggedAppID != nil, !isPanningPage else {
            edgePageDirection = 0
            return
        }

        let direction: Int
        if point.x <= edgePageInset {
            direction = -1
        } else if point.x >= bounds.width - edgePageInset {
            direction = 1
        } else {
            direction = 0
        }

        if direction != edgePageDirection {
            edgePageDirection = direction
            lastEdgePageTurnTime = CACurrentMediaTime()
        }
        // Keep the render loop alive for pointer-following even when the
        // pointer is not currently inside an edge paging zone.
        startDisplayLink()
    }

    private func tickEdgePageTurn(now: CFTimeInterval) {
        guard edgePageDirection != 0,
              didDrag,
              draggedAppID != nil,
              !isPanningPage,
              contentTransitionPhase == .idle,
              now - lastEdgePageTurnTime >= edgePageTurnDelay else {
            return
        }

        let destination = store.currentPage + edgePageDirection
        guard destination >= 0, destination < store.pageCount else {
            // Do not repeatedly try to page past the catalog ends while the
            // pointer remains against the edge.
            edgePageDirection = 0
            return
        }

        store.goToPage(destination)
        lastEdgePageTurnTime = now
    }

    private func updateReorderDestination(at point: CGPoint) {
        guard let source = dragSource,
              didDrag,
              store.allowsUserLayoutEditing,
              store.openedFolderID == nil,
              contentTransitionPhase == .idle else {
            return
        }

        let metrics = GridMetrics(size: bounds.size)
        let draggedCenter = CGPoint(
            x: dragPoint.x - dragGrabOffset.x,
            y: dragPoint.y - dragGrabOffset.y
        )

        // Once a grouping preview is active, keep it until the dragged icon is
        // moved clearly away. This hysteresis makes releasing near the boundary
        // reliable instead of flickering between group and reorder states.
        if let activeTargetID = dragHoverTargetID,
           let activeIndex = displayedItems.firstIndex(where: { $0.id == activeTargetID }) {
            let visualIndex = reorderVisualSlots[activeTargetID] ?? Double(activeIndex)
            let center = metrics.iconCenter(
                globalIndex: visualIndex,
                pageOffset: interactionPageOffset
            )
            if hypot(draggedCenter.x - center.x, draggedCenter.y - center.y)
                <= metrics.iconSize * 0.92 {
                return
            }
        }

        // Acquire grouping from the actual dragged icon center rather than the
        // pointer. Grabbing an icon near an edge therefore remains just as easy
        // as grabbing it in the middle.
        let groupingRadius = metrics.iconSize * 0.72
        var groupingCandidate: (id: String, distance: CGFloat)?
        for (index, item) in displayedItems.enumerated() where item.id != draggedAppID {
            let visualIndex = reorderVisualSlots[item.id] ?? Double(index)
            let center = metrics.iconCenter(
                globalIndex: visualIndex,
                pageOffset: interactionPageOffset
            )
            let distance = hypot(draggedCenter.x - center.x, draggedCenter.y - center.y)
            guard distance <= groupingRadius else { continue }
            if groupingCandidate == nil || distance < groupingCandidate!.distance {
                groupingCandidate = (item.id, distance)
            }
        }
        if let groupingCandidate {
            setDragHoverTarget(groupingCandidate.id)
            return
        }

        // Reordering uses a wider acquisition area than normal clicking. Its
        // outer region remains available for sorting, while the central overlap
        // region below is reserved for grouping.
        guard let hit = metrics.hitTest(
            point: point,
            pageOffset: interactionPageOffset,
            hitRadiusScale: 1.05
        ) else {
            setDragHoverTarget(nil)
            return
        }

        let destination = hit.page * store.pageCapacity + hit.localIndex
        guard displayedItems.indices.contains(destination) else {
            setDragHoverTarget(nil)
            return
        }
        if destination == source {
            setDragHoverTarget(nil)
            return
        }

        let target = displayedItems[destination]
        setDragHoverTarget(nil)

        if case .folder = target { return }

        store.moveItem(from: source, to: destination)
        displayedItems = store.displayItems
        lastDisplaySignature = AppListSignature(items: displayedItems)
        dragSource = destination
        dragDestination = destination
        isReorderAnimationActive = true
        startDisplayLink()
    }

    private var folderRemovalDropRect: CGRect {
        CGRect(
            x: bounds.midX - 140,
            y: max(0, bounds.height - 145),
            width: 280,
            height: 85
        )
    }

    private func updateFolderDrag(at point: CGPoint) {
        guard didDrag, store.openedFolderID != nil else { return }
        let isRemovalTargeted = folderRemovalDropRect.contains(dragPoint)
        store.setFolderDragState(isDragging: true, removalTargeted: isRemovalTargeted)
        if !isRemovalTargeted {
            updateFolderReorderDestination(at: point)
        }
    }

    private func updateFolderReorderDestination(at point: CGPoint) {
        guard let folderID = store.openedFolderID,
              let source = dragSource,
              didDrag,
              contentTransitionPhase == .idle else { return }

        let metrics = GridMetrics(size: bounds.size)
        guard let hit = metrics.hitTest(
            point: point,
            pageOffset: interactionPageOffset,
            hitRadiusScale: 1.05
        ) else { return }
        let destination = hit.page * store.pageCapacity + hit.localIndex
        guard displayedItems.indices.contains(destination), destination != source else { return }

        store.moveAppInsideFolder(folderID: folderID, from: source, to: destination)
        displayedItems = store.activeDisplayItems
        lastDisplaySignature = AppListSignature(items: displayedItems)
        dragSource = destination
        dragDestination = destination
        isReorderAnimationActive = true
        startDisplayLink()
    }

    @objc private func storeChanged() {
        if isDragCancelledByLayout {
            discardCancelledDrag()
        }
        // Page-turn publishes pageOffset many times a second. Replanning the
        // icon window on each event hitchs the trackpad gesture.
        if !store.isPageGestureActive {
            resourcePrewarmSignature = nil
            scheduleResourcePrewarmingIfNeeded(prune: true)
        }
        startDisplayLink()
        needsDisplay = true
    }

    @objc private func settingsChanged() {
        if IconRenderQuality.current != lastRenderQuality {
            applyRenderQualityChange()
            return
        }
        needsDisplay = true
    }

    @objc private func renderQualityChanged() {
        applyRenderQualityChange()
    }

    @objc private func iconTexturesUpdated() {
        // Background bakes finished — paint without doing work on this path.
        needsDisplay = true
        startDisplayLink()
    }

    /// Drop GPU caches and rebuild off the main thread so Settings stays responsive.
    private func applyRenderQualityChange() {
        let quality = IconRenderQuality.current
        if quality == lastRenderQuality, store.isApplyingRenderQuality {
            return
        }
        lastRenderQuality = quality
        store.setApplyingRenderQuality(true)
        suppressLazyIconReveal = true
        applyDrawableConfiguration(for: quality)

        pauseResourcePrewarming()
        iconTextures.resetForRenderQualityChange()
        folderIconTextures.clear()
        cancelTextAtlasBuild()
        textAtlas.clear()
        lastTextSignature = nil
        iconsMissingTexture.removeAll(keepingCapacity: true)
        iconRevealStartedAt.removeAll(keepingCapacity: true)
        lastCatalogSignature = nil
        resourcePrewarmSignature = nil
        isResourcePrewarmingPaused = false

        scheduleResourcePrewarmingIfNeeded(prune: true)
        if resourcePrewarmTask == nil {
            store.setApplyingRenderQuality(false)
            suppressLazyIconReveal = false
        }
        startDisplayLink()
        needsDisplay = true
    }

    @objc private func clearCacheRequested() {
        pauseResourcePrewarming()
        iconTextures.clear()
        folderIconTextures.clear()
        cancelTextAtlasBuild()
        textAtlas.clear()
        lastCatalogSignature = nil
        lastTextSignature = nil
        resourcePrewarmSignature = nil
        lastTextureWindowPage = -1
        isResourcePrewarmingPaused = false
        scheduleResourcePrewarmingIfNeeded(prune: true)
        startDisplayLink()
        needsDisplay = true
    }

    @objc private func presentationChanged(_ note: Notification) {
        guard let showing = note.userInfo?["showing"] as? Bool else { return }
        let style = (note.userInfo?["animationStyle"] as? String)
            .flatMap(LaunchpadAnimationStyle.init(rawValue:))
            ?? (showing ? LaunchpadAnimationStyle.current : presentationStyle)
        presentationStyle = style
        isShowingPresentation = showing
        stationaryDismissedAppID = showing
            ? nil
            : note.userInfo?["openingAppID"] as? String
        presentStartTime = CACurrentMediaTime()
        if showing {
            presentFrom = 0
            presentTo = 1
            // Unpause immediately so resident caches can be used / topped up
            // during the open animation (do not wait until animation end).
            isResourcePrewarmingPaused = false
            if !IconRenderQuality.current.usesLazyTextureLoading {
                iconTextures.setAllowedAppIDs(nil)
            }
            scheduleResourcePrewarmingIfNeeded(
                prune: IconRenderQuality.current.usesLazyTextureLoading
            )
        } else {
            presentFrom = store.presentationProgress
            presentTo = 0
            pauseResourcePrewarming()
        }
        let fullDuration = showing ? style.duration : style.dismissalDuration
        presentDurationActive = fullDuration * CFTimeInterval(abs(presentTo - presentFrom))
        if presentDurationActive <= 0.0001 {
            animatingPresentation = false
            applyPresentationPhase(presentTo)
            if showing {
                store.markVisible()
                resumeResourcePrewarming()
            } else {
                releaseIconGPUResources()
            }
            needsDisplay = true
            return
        }
        animatingPresentation = true
        startDisplayLink()
        needsDisplay = true
    }

    /// On hide: reclaim memory without making the next open wait for a full re-bake.
    /// - Quality / performance: keep **all** resident icon textures (fluency first).
    /// - Low memory: keep only the **current page**, drop the rest.
    private func releaseIconGPUResources() {
        pauseResourcePrewarming()
        resourcePrewarmTask = nil
        isResourcePrewarmingPaused = true

        let quality = IconRenderQuality.current
        if !quality.usesLazyTextureLoading {
            // Resident modes: leave the GPU cache intact so reopen is instant.
            // Only stop background work while hidden. Clear the prewarm signature
            // so an interrupted full-catalog bake can resume (cache hits are free).
            iconTextures.setAllowedAppIDs(nil)
            resourcePrewarmSignature = nil
            return
        }

        let items = displayedItems.isEmpty ? store.activeDisplayItems : displayedItems
        let page = max(0, Int(currentPageOffset.rounded()))
        let window = iconCacheWindow(around: page, items: items, radius: 0)
        pruneIconTextureCaches(appIDs: window.appIDs, folderIDs: window.folderIDs)
        lastTextureWindowPage = page

        // Low-memory mode drops labels while hidden; rebuild them off-main on
        // the next presentation.
        cancelTextAtlasBuild()
        textAtlas.clear()
        lastTextSignature = nil
        iconsMissingTexture.removeAll(keepingCapacity: true)
        iconRevealStartedAt.removeAll(keepingCapacity: true)

        // Low-memory: re-plan neighbor prewarm on next show; keep current-page cache.
        resourcePrewarmSignature = nil
    }

    private func applyPresentationPhase(_ phase: CGFloat) {
        let progress = min(1, max(0, phase))
        presentationPhase = progress
        let fastDismissAlpha = progress * progress * progress
        switch presentationStyle {
        case .fly:
            // The per-icon flight currently resolves at internal time 0.87.
            // Stretch that useful range across the full presentation duration so
            // the exact reverse starts moving immediately instead of idling first.
            iconEntranceProgress = progress >= 0.999 ? 1 : progress * 0.87
            contentAlpha = isShowingPresentation ? 1 : fastDismissAlpha
            contentScale = 1
        case .zoom:
            iconEntranceProgress = 1
            contentAlpha = isShowingPresentation ? 1 : fastDismissAlpha
            contentScale = 1
        case .fade:
            let eased = 1 - pow(1 - progress, 3)
            iconEntranceProgress = 1
            // Fade dismissal is applied once to the composited NSPanel so the
            // wallpaper and all content share an identical opacity curve.
            contentAlpha = isShowingPresentation ? eased : 1
            contentScale = 1
        case .none:
            iconEntranceProgress = 1
            contentAlpha = 1
            contentScale = 1
        }
        store.presentationProgress = progress
    }

    /// Submit the icon layer's presentation-start frame while the window already
    /// shows its cached wallpaper. Icon timing starts after the GPU completes it.
    func submitFirstPresentationFrame(
        style: LaunchpadAnimationStyle,
        completion: @escaping () -> Void
    ) {
        firstFrameWaiters.append(completion)
        animatingPresentation = false
        isShowingPresentation = true
        isPrimingPresentationFrame = true
        presentationStyle = style
        applyPresentationPhase(0)
        // Do not clear textures here. Resume residency so a second open can paint
        // from cache immediately (especially quality / performance modes).
        isResourcePrewarmingPaused = false
        if !IconRenderQuality.current.usesLazyTextureLoading {
            iconTextures.setAllowedAppIDs(nil)
        }
        scheduleResourcePrewarmingIfNeeded(prune: IconRenderQuality.current.usesLazyTextureLoading)
        startDisplayLink()
        needsDisplay = true
    }

    /// Prewarm icon GPU resources according to the active render-quality profile.
    /// - Quality / performance: full-catalog resident (smooth paging).
    /// - Low memory: page-window lazy load + prune.
    private func scheduleResourcePrewarmingIfNeeded(
        around page: Int? = nil,
        prune: Bool = true
    ) {
        guard !isResourcePrewarmingPaused else { return }
        let quality = IconRenderQuality.current
        if quality.usesLazyTextureLoading {
            scheduleLazyResourcePrewarming(around: page, prune: prune)
        } else {
            scheduleResidentResourcePrewarming()
        }
    }

    /// Original-style full-catalog upload for quality & performance modes.
    private func scheduleResidentResourcePrewarming() {
        let catalog = store.apps
        let visibleApps = store.filteredApps
        guard !catalog.isEmpty else { return }

        let signature = IconPrewarmSignature(
            catalog: AppListSignature(apps: catalog),
            display: AppListSignature(apps: catalog),
            page: -1,
            quality: IconRenderQuality.current.rawValue
        )
        // Unrestricted baking — always clear the allow-list first so a previous
        // low-memory session cannot block resident uploads.
        iconTextures.setAllowedAppIDs(nil)
        folderIconTextures.setAllowedFolderIDs(nil)

        // Skip only while the same full-catalog job is already running or done.
        if signature == resourcePrewarmSignature {
            return
        }

        resourcePrewarmSignature = signature
        resourcePrewarmTask?.cancel()
        lastCatalogSignature = signature.catalog
        lastTextureWindowPage = -1

        if displayedItems.isEmpty {
            displayedItems = store.displayItems
            lastDisplaySignature = AppListSignature(items: displayedItems)
            contentTransitionPhase = .idle
            contentTransitionAlpha = 1
        }

        let items = displayedItems.isEmpty ? store.activeDisplayItems : displayedItems
        let capacity = max(store.pageCapacity, 1)
        let firstPageEnd = min(capacity, visibleApps.isEmpty ? catalog.count : visibleApps.count)
        let firstPageApps: [AppInfo]
        if !visibleApps.isEmpty {
            firstPageApps = Array(visibleApps.prefix(firstPageEnd))
        } else {
            firstPageApps = Array(catalog.prefix(firstPageEnd))
        }
        let firstPageIDs = Set(firstPageApps.map(\.id))
        let remainingApps = catalog.filter { !firstPageIDs.contains($0.id) }

        // Bake folder composites for the whole item list (resident).
        var allFolders: [(AppFolder, [AppInfo])] = []
        var seenFolders = Set<String>()
        for item in items {
            guard case .folder(let folder) = item else { continue }
            let current = store.folder(withID: folder.id) ?? folder
            guard seenFolders.insert(current.id).inserted else { continue }
            let members = current.appIDs.compactMap { store.app(withID: $0) }
            allFolders.append((current, members))
        }

        let textureStore = iconTextures
        let folderStore = folderIconTextures
        let preset = GridLayoutPreset.current

        resourcePrewarmTask = Task.detached(priority: .utility) { [self] in
            for app in firstPageApps {
                guard !Task.isCancelled else { return }
                autoreleasepool { _ = textureStore.texture(for: app, allowCreate: true) }
            }
            for entry in allFolders {
                guard !Task.isCancelled else { return }
                autoreleasepool {
                    _ = folderStore.texture(
                        for: entry.0,
                        members: entry.1,
                        preset: preset,
                        allowCreate: true
                    )
                }
            }

            // Reveal the visible batch once. Remaining off-page resident bakes
            // must not wake the main thread once per completed texture.
            guard !Task.isCancelled else { return }
            await refreshAfterPriorityPrewarming(expectedSignature: signature)

            for app in remainingApps {
                guard !Task.isCancelled else { return }
                autoreleasepool { _ = textureStore.texture(for: app, allowCreate: true) }
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            await finishResourcePrewarming(expectedSignature: signature)
        }
    }

    /// Page-window lazy load used only by「低内存占用」.
    /// Search uses the active result list (not the root page window), otherwise
    /// result icons stay blank because they were never allowed into the cache.
    private func scheduleLazyResourcePrewarming(around page: Int?, prune: Bool) {
        let catalog = store.apps
        // Prefer the list about to appear during a content transition.
        let items: [LaunchpadItem]
        if contentTransitionPhase == .fadingOut, let pending = pendingDisplayItems {
            items = pending
        } else {
            items = displayedItems.isEmpty ? store.activeDisplayItems : displayedItems
        }
        guard !catalog.isEmpty else { return }
        // Empty search results still need a signature update so allow-lists reset.
        let targetPage = max(0, page ?? Int(currentPageOffset.rounded()))
        let displaySignature = AppListSignature(items: items)
        let signature = IconPrewarmSignature(
            catalog: AppListSignature(apps: catalog),
            display: displaySignature,
            page: store.isSearching ? -2 : targetPage,
            quality: IconRenderQuality.current.rawValue
        )

        // Search: keep the whole result set (capped). Root/folder: page ± 1.
        let searchCap = max(store.pageCapacity * 6, 48)
        let window: IconCacheWindow
        if store.isSearching {
            window = iconCacheWindow(covering: items, maxCount: searchCap)
        } else {
            window = iconCacheWindow(around: targetPage, items: items, radius: 1)
        }

        if prune {
            pruneIconTextureCaches(appIDs: window.appIDs, folderIDs: window.folderIDs)
            lastTextureWindowPage = targetPage
        } else {
            iconTextures.expandAllowedAppIDs(window.appIDs)
            folderIconTextures.expandAllowedFolderIDs(window.folderIDs)
        }

        if signature == resourcePrewarmSignature, resourcePrewarmTask != nil {
            return
        }
        if signature == resourcePrewarmSignature, !prune {
            return
        }

        resourcePrewarmSignature = signature
        resourcePrewarmTask?.cancel()
        lastCatalogSignature = signature.catalog

        if displayedItems.isEmpty {
            displayedItems = store.displayItems
            lastDisplaySignature = AppListSignature(items: displayedItems)
            contentTransitionPhase = .idle
            contentTransitionAlpha = 1
        }

        let capacity = max(store.pageCapacity, 1)
        let pageStart = min(items.count, targetPage * capacity)
        let pageEnd = min(items.count, pageStart + capacity)
        let pageItems: [LaunchpadItem]
        if store.isSearching {
            // Prioritize the first screen of search hits, then the rest of the cap.
            pageItems = Array(items.prefix(capacity))
        } else {
            pageItems = pageStart < pageEnd ? Array(items[pageStart..<pageEnd]) : []
        }
        var pageAppIDs = Set<String>()
        for item in pageItems {
            if case .app(let app) = item { pageAppIDs.insert(app.id) }
        }
        let priorityApps =
            window.apps.filter { pageAppIDs.contains($0.id) }
            + window.apps.filter { !pageAppIDs.contains($0.id) }
        let priorityFolders = window.folders
        let textureStore = iconTextures
        let folderStore = folderIconTextures
        let preset = GridLayoutPreset.current

        resourcePrewarmTask = Task.detached(priority: .utility) { [self] in
            for app in priorityApps {
                guard !Task.isCancelled else { return }
                autoreleasepool { _ = textureStore.texture(for: app, allowCreate: true) }
            }
            for entry in priorityFolders {
                guard !Task.isCancelled else { return }
                autoreleasepool {
                    _ = folderStore.texture(
                        for: entry.folder,
                        members: entry.members,
                        preset: preset,
                        allowCreate: true
                    )
                }
            }

            guard !Task.isCancelled else { return }
            await finishResourcePrewarming(expectedSignature: signature)
        }
    }

    private struct IconCacheWindow {
        var apps: [AppInfo]
        var appIDs: Set<String>
        var folders: [(folder: AppFolder, members: [AppInfo])]
        var folderIDs: Set<String>
    }

    private func itemsForPages(
        around page: Int,
        radius: Int,
        in items: [LaunchpadItem]
    ) -> [LaunchpadItem] {
        let capacity = max(store.pageCapacity, 1)
        let startPage = max(0, page - radius)
        let endPage = page + radius
        let start = min(items.count, startPage * capacity)
        let end = min(items.count, (endPage + 1) * capacity)
        guard start < end else { return [] }
        return Array(items[start..<end])
    }

    /// Apps/folders on `[page-radius ... page+radius]` (clamped).
    private func iconCacheWindow(
        around page: Int,
        items: [LaunchpadItem],
        radius: Int = 1
    ) -> IconCacheWindow {
        let capacity = max(store.pageCapacity, 1)
        let startPage = max(0, page - radius)
        let endPage = page + radius
        let start = min(items.count, startPage * capacity)
        let end = min(items.count, (endPage + 1) * capacity)
        guard start < end else {
            return IconCacheWindow(apps: [], appIDs: [], folders: [], folderIDs: [])
        }
        return iconCacheWindow(covering: Array(items[start..<end]), maxCount: end - start)
    }

    /// Flatten an arbitrary item list into a bake/retain window (search results).
    private func iconCacheWindow(
        covering items: [LaunchpadItem],
        maxCount: Int
    ) -> IconCacheWindow {
        var apps: [AppInfo] = []
        var appIDs = Set<String>()
        var folders: [(AppFolder, [AppInfo])] = []
        var folderIDs = Set<String>()
        var seenApps = Set<String>()
        var counted = 0

        for item in items {
            guard counted < maxCount else { break }
            switch item {
            case .app(let app):
                if seenApps.insert(app.id).inserted {
                    apps.append(app)
                    appIDs.insert(app.id)
                    counted += 1
                }
            case .folder(let folder):
                let current = store.folder(withID: folder.id) ?? folder
                if folderIDs.insert(current.id).inserted {
                    let members = current.appIDs.compactMap { store.app(withID: $0) }
                    folders.append((current, members))
                    counted += 1
                }
            }
        }
        return IconCacheWindow(
            apps: apps,
            appIDs: appIDs,
            folders: folders,
            folderIDs: folderIDs
        )
    }

    private func pruneIconTextureCaches(appIDs: Set<String>, folderIDs: Set<String>) {
        iconTextures.retainOnly(appIDs: appIDs)
        folderIconTextures.retainOnly(folderIDs: folderIDs)
    }

    private func scheduleTextAtlasRebuildIfNeeded(
        apps: [AppInfo],
        scale: CGFloat,
        options: TextAtlas.Options
    ) {
        guard !apps.isEmpty else { return }
        let signature = TextAtlasSignature(apps: apps, scale: scale, options: options)
        guard lastTextSignature != signature, pendingTextSignature != signature else { return }

        textAtlasBuildTask?.cancel()
        pendingTextSignature = signature
        let source = textAtlas
        textAtlasBuildTask = Task.detached(priority: .utility) { [weak self] in
            let replacement = source.rebuilt(with: apps, scale: scale, options: options)
            guard !Task.isCancelled else { return }
            await self?.installTextAtlas(replacement, signature: signature)
        }
    }

    private func installTextAtlas(_ replacement: TextAtlas, signature: TextAtlasSignature) {
        guard pendingTextSignature == signature else { return }
        textAtlas.replaceContents(with: replacement)
        lastTextSignature = signature
        pendingTextSignature = nil
        textAtlasBuildTask = nil
        store.setApplyingRenderQuality(false)
        suppressLazyIconReveal = false
        startDisplayLink()
        needsDisplay = true
    }

    private func cancelTextAtlasBuild() {
        textAtlasBuildTask?.cancel()
        textAtlasBuildTask = nil
        pendingTextSignature = nil
    }

    private func finishResourcePrewarming(expectedSignature: IconPrewarmSignature) {
        guard !isResourcePrewarmingPaused,
              resourcePrewarmSignature == expectedSignature else { return }
        resourcePrewarmTask = nil
        store.setApplyingRenderQuality(false)
        suppressLazyIconReveal = false
        startDisplayLink()
        needsDisplay = true
    }

    private func refreshAfterPriorityPrewarming(expectedSignature: IconPrewarmSignature) {
        guard !isResourcePrewarmingPaused,
              resourcePrewarmSignature == expectedSignature else { return }
        startDisplayLink()
        needsDisplay = true
    }

    private func pauseResourcePrewarming() {
        isResourcePrewarmingPaused = true
        resourcePrewarmTask?.cancel()
        resourcePrewarmTask = nil
    }

    private func resumeResourcePrewarming() {
        isResourcePrewarmingPaused = false
        resourcePrewarmSignature = nil
        scheduleResourcePrewarmingIfNeeded(prune: true)
    }

    private func signalFirstFrameRenderedIfNeeded() {
        guard !firstFrameWaiters.isEmpty else { return }
        let waiters = firstFrameWaiters
        firstFrameWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0() }
    }

    private func attachFirstFrameCompletion(to commandBuffer: MTLCommandBuffer) {
        guard !firstFrameWaiters.isEmpty, !isFirstFrameCompletionScheduled else { return }
        isFirstFrameCompletionScheduled = true
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let succeeded = buffer.status == .completed
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFirstFrameCompletionScheduled = false
                if succeeded {
                    self.isPrimingPresentationFrame = false
                    self.signalFirstFrameRenderedIfNeeded()
                } else {
                    // Keep the panel transparent and retry instead of starting
                    // presentation with a missing drawable.
                    self.startDisplayLink()
                    self.needsDisplay = true
                }
            }
        }
    }

    func playPresentAnimation() {
        presentationChanged(Notification(
            name: .qlaunchpadPresentationChanged,
            object: nil,
            userInfo: [
                "showing": true,
                "animationStyle": LaunchpadAnimationStyle.current.rawValue
            ]
        ))
    }

    func playDismissAnimation(completion: @escaping @Sendable () -> Void) {
        let style = presentationStyle
        presentationChanged(Notification(
            name: .qlaunchpadPresentationChanged,
            object: nil,
            userInfo: [
                "showing": false,
                "animationStyle": style.rawValue
            ]
        ))
        DispatchQueue.main.asyncAfter(
            deadline: .now() + style.dismissalDuration + 0.02,
            execute: completion
        )
    }

    // MARK: Search transition

    /// Root tiles, every app (including folder members), and folder titles.
    /// Resident quality / performance keep this set so view swaps do not
    /// rebuild the atlas on the first fade-in frame.
    private func residentTextAtlasItems() -> [LaunchpadItem] {
        var items: [LaunchpadItem] = []
        var seen = Set<String>()
        func append(_ item: LaunchpadItem) {
            guard seen.insert(item.id).inserted else { return }
            items.append(item)
        }
        for item in store.launchpadItems {
            append(item)
        }
        for app in store.apps {
            append(.app(app))
        }
        return items
    }

    private func textAtlasApps(for items: [LaunchpadItem]) -> [AppInfo] {
        var result: [AppInfo] = []
        var seen = Set<String>()
        func append(_ app: AppInfo) {
            guard seen.insert(app.id).inserted else { return }
            result.append(app)
        }

        for item in items {
            switch item {
            case .app(let app):
                append(app)
            case .folder(let folder):
                let memberURL = folder.appIDs.lazy.compactMap { self.store.app(withID: $0)?.url }.first
                    ?? URL(fileURLWithPath: "/Applications")
                append(
                    AppInfo(
                        id: folder.id,
                        name: folder.name,
                        url: memberURL,
                        bundleIdentifier: folder.id
                    )
                )
            }
        }
        return result
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    private func resetReorderVisualSlots(to items: [LaunchpadItem]) {
        reorderVisualSlots = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { index, item in
                (item.id, Double(index))
            }
        )
        isReorderAnimationActive = false
    }

    private func synchronizeReorderVisualSlots(with items: [LaunchpadItem]) {
        let ids = Set(items.map(\.id))
        reorderVisualSlots = reorderVisualSlots.filter { ids.contains($0.key) }
        for (index, item) in items.enumerated() where reorderVisualSlots[item.id] == nil {
            reorderVisualSlots[item.id] = Double(index)
        }
    }

    /// Replace the visible collection without discarding the current visual
    /// slots. Surviving icons then glide from their old cells to their new
    /// indices instead of snapping after folder membership changes.
    private func applyAnimatedLayout(
        _ items: [LaunchpadItem],
        emergingItemIDs: Set<String> = [],
        emergingFrom originSlot: Double? = nil
    ) {
        displayedItems = items
        lastDisplaySignature = AppListSignature(items: items)
        if let originSlot {
            for id in emergingItemIDs where items.contains(where: { $0.id == id }) {
                reorderVisualSlots[id] = originSlot
            }
        }
        synchronizeReorderVisualSlots(with: items)
        isReorderAnimationActive = items.enumerated().contains { index, item in
            abs((reorderVisualSlots[item.id] ?? Double(index)) - Double(index)) >= 0.001
        }
        if isReorderAnimationActive { startDisplayLink() }
        needsDisplay = true
    }

    private func tickReorderAnimation(dt: CFTimeInterval) {
        guard !reorderVisualSlots.isEmpty else {
            isReorderAnimationActive = false
            return
        }

        let step = 1 - exp(-dt * reorderAnimationRate)
        var active = false
        for (index, item) in displayedItems.enumerated() {
            let target = Double(index)
            let current = reorderVisualSlots[item.id] ?? target
            let distance = target - current
            if abs(distance) < 0.001 {
                reorderVisualSlots[item.id] = target
            } else {
                reorderVisualSlots[item.id] = current + distance * step
                active = true
            }
        }
        isReorderAnimationActive = active
    }

    private func noteDisplayChangeIfNeeded() {
        let target = store.activeDisplayItems
        guard lastDisplaySignature?.matches(target) != true else { return }
        let signature = AppListSignature(items: target)
        lastDisplaySignature = signature

        if displayedItems.isEmpty {
            displayedItems = target
            pendingDisplayItems = nil
            contentTransitionPhase = .idle
            contentTransitionAlpha = 1
            return
        }
        if signature.matches(displayedItems) {
            pendingDisplayItems = nil
            return
        }

        pendingDisplayItems = target
        switch contentTransitionPhase {
        case .idle:
            frozenPageOffset = currentPageOffset
            contentTransitionPhase = .fadingOut
            contentTransitionStart = CACurrentMediaTime()
            contentTransitionAlpha = 1
            startDisplayLink()
        case .fadingOut:
            break
        case .fadingIn:
            frozenPageOffset = currentPageOffset
            let already = 1 - CGFloat(contentTransitionAlpha)
            contentTransitionPhase = .fadingOut
            contentTransitionStart = CACurrentMediaTime()
                - contentTransitionHalfDuration * already
            startDisplayLink()
        }
        // Kick low-memory baking for the incoming list (search/folder) during fade-out
        // so icons are ready when the new grid fades in.
        if IconRenderQuality.current.usesLazyTextureLoading {
            resourcePrewarmSignature = nil
            lastTextureWindowPage = -1
            isResourcePrewarmingPaused = false
            scheduleLazyResourcePrewarming(
                around: max(0, Int(store.pageOffset.rounded())),
                prune: false
            )
        }
    }

    private func tickContentTransition(now: CFTimeInterval) {
        guard contentTransitionPhase != .idle else { return }
        let t = CGFloat((now - contentTransitionStart) / contentTransitionHalfDuration)
        switch contentTransitionPhase {
        case .idle:
            break
        case .fadingOut:
            contentTransitionAlpha = Float(1 - smoothstep(t))
            if t >= 1 {
                displayedItems = pendingDisplayItems ?? store.activeDisplayItems
                resetReorderVisualSlots(to: displayedItems)
                pendingDisplayItems = nil
                currentPageOffset = store.pageOffset
                frozenPageOffset = store.pageOffset
                contentTransitionPhase = .fadingIn
                contentTransitionStart = now
                contentTransitionAlpha = 0
                // Search / folder swaps change the visible app set. Refresh the
                // low-memory texture window immediately or results stay blank.
                if IconRenderQuality.current.usesLazyTextureLoading {
                    resourcePrewarmSignature = nil
                    lastTextureWindowPage = -1
                    isResourcePrewarmingPaused = false
                    scheduleLazyResourcePrewarming(
                        around: max(0, Int(store.pageOffset.rounded())),
                        prune: true
                    )
                }
            }
        case .fadingIn:
            contentTransitionAlpha = Float(smoothstep(t))
            if t >= 1 {
                contentTransitionAlpha = 1
                contentTransitionPhase = .idle
                if lastDisplaySignature?.matches(displayedItems) != true {
                    lastDisplaySignature = nil
                    noteDisplayChangeIfNeeded()
                }
            }
        }
    }

    // MARK: Draw

    func draw(in view: MTKView) {
        // Layout / render-quality changes need a matching raster size. Clears
        // the previous cache when the pixel edge length changes.
        iconTextures.configure(for: GridLayoutPreset.current)

        // If apps just arrived, populate the grid immediately (no empty first open).
        if displayedItems.isEmpty, !store.activeDisplayItems.isEmpty {
            displayedItems = store.activeDisplayItems
            lastDisplaySignature = AppListSignature(items: displayedItems)
            contentTransitionPhase = .idle
            contentTransitionAlpha = 1
            lastTextSignature = nil
        }

        noteDisplayChangeIfNeeded()

        let quality = IconRenderQuality.current
        if quality.usesLazyTextureLoading {
            // Low-memory: also react to search/folder list identity, not just page.
            let destPage = max(
                0,
                Int((store.isPageGestureActive ? store.pageOffset : store.targetPage).rounded())
            )
            let pageSettled = !store.isPageGestureActive
                && abs(currentPageOffset - store.targetPage) < 0.02
            let displaySignature = AppListSignature(items: displayedItems)
            let displayChanged = resourcePrewarmSignature?.display != displaySignature
            if lastCatalogSignature?.matches(store.apps) != true || displayChanged {
                scheduleResourcePrewarmingIfNeeded(around: destPage, prune: true)
            } else if pageSettled {
                let page = max(0, Int(store.targetPage.rounded()))
                if page != lastTextureWindowPage
                    || iconTextures.cachedTextureCount > (store.pageCapacity * 3 + 8) {
                    scheduleResourcePrewarmingIfNeeded(around: page, prune: true)
                }
            } else if !store.isSearching, destPage != resourcePrewarmSignature?.page {
                scheduleResourcePrewarmingIfNeeded(around: destPage, prune: false)
            }
        } else {
            // Quality / performance: keep full-catalog residency for smooth paging.
            scheduleResourcePrewarmingIfNeeded()
        }

        // Text atlas: resident modes keep labels for the full item list;
        // low-memory bakes the visible page ± 1 (same window as icons).
        let scale = windowScale
        let labelItems: [LaunchpadItem]
        if quality.usesLazyTextureLoading {
            if store.isSearching {
                let searchCap = max(store.pageCapacity * 6, 48)
                labelItems = Array(displayedItems.prefix(searchCap))
            } else {
                let labelPage = max(0, Int(currentPageOffset.rounded()))
                labelItems = itemsForPages(around: labelPage, radius: 1, in: displayedItems)
            }
        } else {
            // Keep every app + folder title resident so opening/closing a
            // folder does not rebuild the quality atlas on the fade-in frame.
            labelItems = residentTextAtlasItems()
        }
        let labelApps = textAtlasApps(for: labelItems)
        if lastTextSignature?.matches(labelApps, scale: scale, options: textAtlasOptions) != true {
            scheduleTextAtlasRebuildIfNeeded(
                apps: labelApps,
                scale: scale,
                options: textAtlasOptions
            )
        }

        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 1.0 / 240.0), 1.0 / 30.0)
        lastFrameTime = now
        tickContentTransition(now: now)
        tickDragVisualAnimations(now: now, dt: dt)
        synchronizeReorderVisualSlots(with: displayedItems)
        tickReorderAnimation(dt: dt)

        if contentTransitionPhase != .fadingOut {
            let pageTarget = store.isPageGestureActive ? store.pageOffset : store.targetPage
            if store.isPageGestureActive {
                // Trackpad/pan must follow 1:1. A spring here lags noisy deltas
                // and the grid looks like it is shaking.
                currentPageOffset = pageTarget
            } else {
                let distance = pageTarget - currentPageOffset
                if abs(distance) > 0.0005 {
                    currentPageOffset += distance * (1.0 - exp(-dt * pageSpringResponse))
                } else {
                    currentPageOffset = pageTarget
                }
            }
        }

        if animatingPresentation {
            let t = min(1, max(0, (now - presentStartTime) / presentDurationActive))
            let phase = presentFrom + (presentTo - presentFrom) * CGFloat(t)
            applyPresentationPhase(phase)
            if t >= 1 {
                animatingPresentation = false
                applyPresentationPhase(presentTo)
                if isShowingPresentation {
                    store.markVisible()
                    resumeResourcePrewarming()
                } else {
                    // Panel closed — free GPU icon textures so RSS does not stay elevated.
                    releaseIconGPUResources()
                }
            }
        }

        // Never stick at zero alpha while the panel is on-screen.
        if !animatingPresentation,
           store.presentation != .dismissing,
           contentAlpha < 0.01,
           window?.isVisible == true {
            contentAlpha = 1
            contentScale = 1
        }
        let presentAlpha = Float(max(contentAlpha, 0))
        let gridAlpha = presentAlpha * max(contentTransitionAlpha, 0)
        guard gridAlpha > 0.001 else {
            // A folder/search swap ends fade-out at alpha 0 in the same
            // draw. Clearing here blanks the layer until the next atlas
            // rebuild finishes — quality text bake made that a long hitch.
            if contentTransitionPhase == .idle {
                clearDrawableIfAvailable()
                stopDisplayLinkIfIdle()
            } else {
                startDisplayLink()
                needsDisplay = true
            }
            return
        }

        // Avoid building frame storage when the layer cannot supply a drawable.
        guard let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            if !firstFrameWaiters.isEmpty {
                startDisplayLink()
                needsDisplay = true
            }
            return
        }

        let frameSlot = inFlightFrames[nextFrameIndex]
        nextFrameIndex = (nextFrameIndex + 1) % inFlightFrameCount
        // Never overwrite this slot while its previous command buffer is using it.
        // With three slots, this normally returns immediately and only applies
        // backpressure when the GPU falls more than two frames behind.
        frameSlot.availability.wait()

        let metrics = GridMetrics(size: bounds.size)
        let midX = bounds.midX
        let midY = bounds.height * 0.5
        let pageOffset = contentTransitionPhase == .fadingOut
            ? frozenPageOffset
            : currentPageOffset

        // Reuse CPU scratch capacity and only replace GPU storage when a slot must
        // grow. Typical frames perform no heap or Metal buffer allocation here.
        iconDrawTextures.removeAll(keepingCapacity: true)
        iconSprites.removeAll(keepingCapacity: true)
        if iconSprites.capacity == 0 {
            let maximumVisibleSprites = GridMetrics.pageCapacity * 3 + 1
            iconDrawTextures.reserveCapacity(maximumVisibleSprites)
            iconSprites.reserveCapacity(maximumVisibleSprites)
            textSprites.reserveCapacity(GridMetrics.pageCapacity * 3)
        }
        while labelsBySheet.count < textAtlas.sheets.count {
            var sheet: [SpriteInstance] = []
            sheet.reserveCapacity(GridMetrics.pageCapacity * 3)
            labelsBySheet.append(sheet)
        }
        for sheet in labelsBySheet.indices {
            labelsBySheet[sheet].removeAll(keepingCapacity: true)
        }

        buildGrid(
            items: displayedItems,
            pageOffset: pageOffset,
            alphaScale: gridAlpha,
            now: now,
            metrics: metrics,
            midX: midX,
            midY: midY,
            iconDrawTextures: &iconDrawTextures,
            iconSprites: &iconSprites,
            labelsBySheet: &labelsBySheet
        )
        prepareFrameResources(frameSlot)

        var uniforms = FrameUniforms(
            viewport: SIMD2(Float(bounds.width), Float(bounds.height)),
            drawable: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            mode: SIMD2(IconRenderQuality.current.shaderQualityMode, 0)
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            frameSlot.availability.signal()
            return
        }

        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<FrameUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<FrameUniforms>.stride,
            index: 1
        )

        encoder.setRenderPipelineState(activeIconPipeline)
        encoder.setFragmentSamplerState(iconSampler, index: 0)
        if let iconBuffer = frameSlot.iconBuffer {
            for index in iconSprites.indices {
                let texture = iconDrawTextures[index]
                encoder.setVertexBuffer(
                    iconBuffer,
                    offset: index * MemoryLayout<SpriteInstance>.stride,
                    index: 0
                )
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: 1
                )
            }
        }

        if let textBuffer = frameSlot.textBuffer {
            encoder.setRenderPipelineState(activeTextPipeline)
            encoder.setFragmentSamplerState(textSampler, index: 0)
            for batch in textBatches {
                guard batch.sheet < textAtlas.sheets.count else { continue }
                encoder.setVertexBuffer(
                    textBuffer,
                    offset: batch.range.lowerBound * MemoryLayout<SpriteInstance>.stride,
                    index: 0
                )
                encoder.setFragmentTexture(textAtlas.sheets[batch.sheet], index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: batch.range.count
                )
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        attachFirstFrameCompletion(to: commandBuffer)
        let frameSemaphore = frameSlot.availability
        commandBuffer.addCompletedHandler { _ in
            frameSemaphore.signal()
        }
        commandBuffer.commit()
        stopDisplayLinkIfIdle()
    }

    private func clearDrawableIfAvailable() {
        guard let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func prepareFrameResources(_ resources: FrameResources) {
        textSprites.removeAll(keepingCapacity: true)
        textBatches.removeAll(keepingCapacity: true)
        textBatches.reserveCapacity(labelsBySheet.count)
        for (sheet, sprites) in labelsBySheet.enumerated() {
            guard !sprites.isEmpty else { continue }
            let start = textSprites.count
            textSprites.append(contentsOf: sprites)
            textBatches.append(TextBatch(sheet: sheet, range: start..<textSprites.count))
        }
        upload(
            iconSprites,
            to: &resources.iconBuffer,
            capacity: &resources.iconCapacity,
            label: "QLaunch icon instances"
        )
        upload(
            textSprites,
            to: &resources.textBuffer,
            capacity: &resources.textCapacity,
            label: "QLaunch text instances"
        )
    }

    private func upload(
        _ instances: [SpriteInstance],
        to buffer: inout MTLBuffer?,
        capacity: inout Int,
        label: String
    ) {
        guard !instances.isEmpty else { return }
        let requiredLength = instances.count * MemoryLayout<SpriteInstance>.stride
        if buffer == nil || capacity < requiredLength {
            var newCapacity = max(capacity, 4_096)
            while newCapacity < requiredLength { newCapacity *= 2 }
            buffer = device?.makeBuffer(length: newCapacity, options: .storageModeShared)
            buffer?.label = label
            capacity = buffer == nil ? 0 : newCapacity
        }
        guard let buffer else { return }
        instances.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(buffer.contents(), source, bytes.count)
        }
    }

    /// iOS-style unlock entrance: a bottom-center wave staggers each icon's
    /// flight, and every icon starts its positional rebound exactly on arrival.
    private func iconEntrance(
        localIndex: Int
    ) -> (
        opacity: Float,
        scale: CGFloat,
        position: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat
    ) {
        guard iconEntranceProgress < 0.999 else { return (1, 1, 1, 0, 0) }

        let column = CGFloat(localIndex % GridMetrics.columns)
        let row = CGFloat(localIndex / GridMetrics.columns)
        let centerColumn = CGFloat(GridMetrics.columns - 1) * 0.5
        let rowProgress = row / CGFloat(max(GridMetrics.rows - 1, 1))
        let horizontalDistance = abs(column - centerColumn)
        let horizontalProgress = min(
            1,
            max(0, (horizontalDistance - 0.5) / max(centerColumn - 0.5, 0.001))
        )
        let verticalFromBottom = 1 - rowProgress
        // A weighted diamond wave produces clearly separated phase bands on
        // the 6 x 4 grid. Bottom-center is phase zero; top-outer is phase one.
        let ripplePhase = min(
            1,
            0.58 * verticalFromBottom + 0.42 * horizontalProgress
        )

        // Arrival and rebound share one per-icon clock. Earlier wave phases
        // start flying first, arrive first, and rebound immediately on arrival.
        let flightDelay = 0.32 * ripplePhase
        let flightSpan: CGFloat = 0.35
        let flight = min(
            1,
            max(0, (iconEntranceProgress - flightDelay) / flightSpan)
        )
        let opacityT = min(1, flight / 0.65)
        let opacity = 1 - pow(1 - opacityT, 3)

        // The temporary landing point contracts toward the grid center as well
        // as moving downward. Returning this offset to zero makes the rebound
        // visibly expand from the middle toward both sides.
        let horizontalDirection: CGFloat = column < centerColumn ? 1 : -1
        let landingHorizontalOffset = horizontalDirection * 12 * horizontalProgress
        let landingVerticalOffset = (18 - 13 * rowProgress) * 0.8
        let position: CGFloat
        let scale: CGFloat
        let horizontalOffset: CGFloat
        let verticalOffset: CGFloat
        if flight < 1 {
            position = 1 - pow(1 - flight, 4)
            scale = 0.72 + 0.28 * (1 - pow(1 - flight, 3))
            horizontalOffset = landingHorizontalOffset
            verticalOffset = landingVerticalOffset
        } else {
            position = 1
            let reboundStart = flightDelay + flightSpan
            let reboundSpan: CGFloat = 0.2
            let tail = min(
                1,
                max(0, (iconEntranceProgress - reboundStart) / reboundSpan)
            )
            // Power ease-out keeps the velocity monotonically decreasing for the
            // entire rebound. The 1.3 exponent deliberately preserves visible
            // displacement late in the timeline instead of becoming sub-pixel
            // too early, so the slow tail can actually be perceived.
            let settled = 1 - pow(1 - tail, 1.3)
            let remainingOffset = 1 - settled
            horizontalOffset = landingHorizontalOffset * remainingOffset
            verticalOffset = landingVerticalOffset * remainingOffset
            scale = 1
        }
        return (Float(opacity), scale, position, horizontalOffset, verticalOffset)
    }

    /// Per-icon center expansion for the zoom style. Icons near the grid center
    /// use a stronger ease-out and therefore advance earlier; the curve becomes
    /// progressively slower toward the outer corners.
    private func iconZoom(
        localIndex: Int
    ) -> (opacity: Float, layoutScale: CGFloat, iconScale: CGFloat) {
        guard presentationStyle == .zoom, presentationPhase < 0.999 else {
            return (1, 1, 1)
        }

        let column = CGFloat(localIndex % GridMetrics.columns)
        let row = CGFloat(localIndex / GridMetrics.columns)
        let centerColumn = CGFloat(GridMetrics.columns - 1) * 0.5
        let centerRow = CGFloat(GridMetrics.rows - 1) * 0.5
        let distance = hypot(column - centerColumn, row - centerRow)
        let minimumDistance = hypot(CGFloat(0.5), CGFloat(0.5))
        let maximumDistance = hypot(centerColumn, centerRow)
        let distanceProgress = min(
            1,
            max(0, (distance - minimumDistance) / max(maximumDistance - minimumDistance, 0.001))
        )

        // Mirror the fly-in mechanism: every icon owns an independent arrival
        // and rebound timeline. Exponential radial distance makes center icons
        // arrive first, while outer icons start later and move for longer.
        let exponentialStrength: CGFloat = 2.4
        let exponentialPhase = (
            exp(exponentialStrength * distanceProgress) - 1
        ) / (exp(exponentialStrength) - 1)
        let totalDuration: CGFloat = 0.62
        let elapsed = presentationPhase * totalDuration
        let expansionDelay = 0.06 * exponentialPhase
        let expansionDuration = 0.26 + 0.08 * exponentialPhase
        let arrivalTime = expansionDelay + expansionDuration
        let reboundDuration = 0.08 + 0.14 * exponentialPhase

        if elapsed < arrivalTime {
            let expansionPhase = min(
                1,
                max(0, (elapsed - expansionDelay) / expansionDuration)
            )
            let positionProgress = 1 - pow(1 - expansionPhase, 4)
            let sizeProgress = 1 - pow(1 - expansionPhase, 3)
            let opacityPhase = min(1, expansionPhase / 0.65)
            let opacity = 1 - pow(1 - opacityPhase, 3)
            return (
                Float(opacity),
                0.72 + 0.32 * positionProgress,
                0.72 + 0.28 * sizeProgress
            )
        }

        let reboundPhase = min(1, (elapsed - arrivalTime) / reboundDuration)
        // Match the fly-in rebound: a visible power ease-out that keeps enough
        // radial displacement late in the timeline for the slowdown to read.
        let settled = 1 - pow(1 - reboundPhase, 1.3)
        return (1, 1.04 - 0.04 * settled, 1)
    }

    /// Extend the center-to-icon ray until the icon is fully beyond the nearest
    /// screen edge, then interpolate back to its final grid center.
    private func offscreenStart(
        for finalCenter: CGPoint,
        screenCenter: CGPoint,
        margin: CGFloat
    ) -> CGPoint {
        let dx = finalCenter.x - screenCenter.x
        let dy = finalCenter.y - screenCenter.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length

        let xBoundary = ux >= 0 ? bounds.width + margin : -margin
        let yBoundary = uy >= 0 ? bounds.height + margin : -margin
        let tx = abs(ux) > 0.0001 ? (xBoundary - finalCenter.x) / ux : .greatestFiniteMagnitude
        let ty = abs(uy) > 0.0001 ? (yBoundary - finalCenter.y) / uy : .greatestFiniteMagnitude
        let travel = max(0, min(tx, ty))
        return CGPoint(
            x: finalCenter.x + ux * travel,
            y: finalCenter.y + uy * travel
        )
    }

    /// Fade an icon that just arrived from the low-memory async bake. Cached
    /// textures (already present on first draw) stay at full opacity.
    private func lazyIconRevealAlpha(
        id: String,
        hasTexture: Bool,
        now: CFTimeInterval
    ) -> Float {
        guard IconRenderQuality.current.usesLazyTextureLoading else { return 1 }
        if suppressLazyIconReveal || store.isApplyingRenderQuality {
            iconRevealStartedAt.removeValue(forKey: id)
            return hasTexture ? 1 : 0
        }
        if !hasTexture {
            iconsMissingTexture.insert(id)
            iconRevealStartedAt.removeValue(forKey: id)
            return 0
        }
        if iconsMissingTexture.contains(id) {
            iconsMissingTexture.remove(id)
            iconRevealStartedAt[id] = now
        }
        guard let start = iconRevealStartedAt[id] else { return 1 }
        let t = (now - start) / iconRevealDuration
        if t >= 1 {
            iconRevealStartedAt.removeValue(forKey: id)
            return 1
        }
        let x = min(1, max(0, t))
        return Float(x * x * (3 - 2 * x))
    }

    /// - Parameter allowCreate: `false` during interactive frames so paging never
    ///   stalls on CG→Metal uploads (those run on the icon bake queue).
    private func iconTexture(for item: LaunchpadItem, allowCreate: Bool = false) -> MTLTexture? {
        switch item {
        case .app(let app):
            return allowCreate
                ? iconTextures.texture(for: app, allowCreate: true)
                : iconTextures.cachedTexture(for: app)
        case .folder(let folder):
            // `displayedItems` can intentionally stay frozen during a content
            // transition. Always resolve the latest folder value so a membership
            // edit invalidates its flattened texture even when the ID is stable.
            let currentFolder = store.folder(withID: folder.id) ?? folder
            let members = currentFolder.appIDs.compactMap { store.app(withID: $0) }
            return folderIconTextures.texture(
                for: currentFolder,
                members: members,
                preset: GridLayoutPreset.current,
                allowCreate: allowCreate
            )
        }
    }

    private func buildGrid(
        items: [LaunchpadItem],
        pageOffset: Double,
        alphaScale: Float,
        now: CFTimeInterval,
        metrics: GridMetrics,
        midX: CGFloat,
        midY: CGFloat,
        iconDrawTextures: inout [MTLTexture],
        iconSprites: inout [SpriteInstance],
        labelsBySheet: inout [[SpriteInstance]]
    ) {
        guard !items.isEmpty, alphaScale > 0.001 else { return }
        let cap = store.pageCapacity
        let pages = max(1, Int(ceil(Double(items.count) / Double(cap))))
        // During a root/folder or search view swap, the only animated property
        // is the shared view opacity. Do not let page-edge fading, icon entrance,
        // zoom, or content scaling modulate individual sprites at the same time.
        let viewTransitionActive = contentTransitionPhase != .idle
        let center = Int(pageOffset.rounded())
        // Avoid lazy-loading adjacent pages while the entrance animation is live.
        // The background prewarmer resumes as soon as presentation completes.
        let entranceActive = iconEntranceProgress < 0.999 && !viewTransitionActive
        var first = entranceActive ? center : max(0, center - 1)
        var last = entranceActive ? center : min(pages - 1, center + 1)
        // Keep the dragged item alive even if the pointer has auto-paged more
        // than one page away from its current catalog slot.
        if let draggedAppID,
           let draggedIndex = items.firstIndex(where: { $0.id == draggedAppID }) {
            let draggedPage = draggedIndex / cap
            first = min(first, draggedPage)
            last = max(last, draggedPage)
        }
        if let returningID = dragReleaseAnimation?.itemID,
           let returningIndex = items.firstIndex(where: { $0.id == returningID }) {
            let returningPage = returningIndex / cap
            first = min(first, returningPage)
            last = max(last, returningPage)
        }
        let showLabels = UserDefaults.standard.object(forKey: "showLabels") as? Bool ?? true
        // Full-image UV for per-icon textures.
        let fullUV = SIMD4<Float>(0, 0, 1, 1)
        var draggedIconDraw: (texture: MTLTexture, sprite: SpriteInstance)?

        for page in first...last {
            let start = page * cap
            let end = min(start + cap, items.count)
            guard start < end else { continue }
            for index in start..<end {
                let local = index - start
                let item = items[index]
                let itemID = item.id
                let app: AppInfo? = if case .app(let value) = item { value } else { nil }
                let folder: AppFolder? = if case .folder(let value) = item { value } else { nil }
                let isOpeningAppTarget = !isShowingPresentation
                    && stationaryDismissedAppID == app?.id
                let visualIndex = reorderVisualSlots[itemID] ?? Double(index)
                var c = metrics.iconCenter(globalIndex: visualIndex, pageOffset: pageOffset)
                if didDrag,
                   contentTransitionPhase == .idle,
                   draggedAppID == itemID {
                    // The dragged icon follows the pointer directly. The other
                    // icons still use their animated visual slots below.
                    c = CGPoint(
                        x: dragPoint.x - dragGrabOffset.x,
                        y: dragPoint.y - dragGrabOffset.y
                    )
                }
                let isDragged = didDrag
                    && contentTransitionPhase == .idle
                    && draggedAppID == itemID
                let zoom = isOpeningAppTarget
                    ? (
                        opacity: Float(1),
                        layoutScale: CGFloat(1),
                        iconScale: CGFloat(1)
                    )
                    : (viewTransitionActive
                        ? (
                            opacity: Float(1),
                            layoutScale: CGFloat(1),
                            iconScale: CGFloat(1)
                        )
                        : iconZoom(localIndex: local))
                if !viewTransitionActive,
                   presentationStyle == .zoom,
                   presentationPhase < 0.999 {
                    c.x = midX + (c.x - midX) * zoom.layoutScale
                    c.y = midY + (c.y - midY) * zoom.layoutScale
                }
                if !viewTransitionActive, contentScale < 0.999 {
                    c.x = midX + (c.x - midX) * contentScale
                    c.y = midY + (c.y - midY) * contentScale
                }
                // The launched app remains at its exact final position and size.
                // Its extra fifth-power fade combines with the shared cubic fade,
                // producing a fast eighth-power disappearance near the start.
                let openingAppOpacity = Float(pow(presentationPhase, 5))
                let entrance = isOpeningAppTarget
                    ? (
                        opacity: openingAppOpacity,
                        scale: CGFloat(1),
                        position: CGFloat(1),
                        horizontalOffset: CGFloat(0),
                        verticalOffset: CGFloat(0)
                    )
                    : (viewTransitionActive
                        ? (
                            opacity: Float(1),
                            scale: CGFloat(1),
                            position: CGFloat(1),
                            horizontalOffset: CGFloat(0),
                            verticalOffset: CGFloat(0)
                        )
                        : iconEntrance(localIndex: local))
                let finalCenter = c
                let landingCenter = CGPoint(
                    x: finalCenter.x + entrance.horizontalOffset,
                    y: finalCenter.y + entrance.verticalOffset
                )
                if abs(entrance.position - 1) > 0.0001 {
                    let start = offscreenStart(
                        for: finalCenter,
                        screenCenter: CGPoint(x: midX, y: midY),
                        margin: metrics.iconSize * 0.65
                    )
                    c.x = start.x + (landingCenter.x - start.x) * entrance.position
                    c.y = start.y + (landingCenter.y - start.y) * entrance.position
                } else {
                    c = landingCenter
                }
                let isReturning = dragReleaseAnimation?.itemID == itemID
                if let release = dragReleaseAnimation, isReturning {
                    let elapsed = CACurrentMediaTime() - release.startTime
                    let raw = CGFloat(elapsed / dragReleaseDuration)
                    let progress = smoothstep(raw)
                    c.x = release.from.x + (finalCenter.x - release.from.x) * progress
                    c.y = release.from.y + (finalCenter.y - release.from.y) * progress
                }
                let pageFade: Float = viewTransitionActive ? 1 : Float(max(
                    0,
                    min(1, 1.15 - abs(finalCenter.x - midX) / max(bounds.width, 1))
                ))
                let alpha = pageFade * alphaScale * entrance.opacity * zoom.opacity

                // Resolve the transparent presentation frame too, but never
                // rasterize or upload a cache miss from the draw path. The
                // resident/page-window prewarmer fills the same cache off-main.
                let texture = iconTexture(for: item, allowCreate: false)
                guard alpha > 0.002 else { continue }
                // Folder previews are already flattened into a single texture,
                // so every item below follows the exact same sprite path.
                let reveal = lazyIconRevealAlpha(
                    id: itemID,
                    hasTexture: texture != nil,
                    now: now
                )
                let drawnAlpha = alpha * reveal

                // Preserve the exact 40% pressed opacity while the launched
                // icon fades. Clearing dragSource on mouse-up must not briefly
                // restore full brightness and produce a visible flash.
                let pressed = !isDragged
                    && contentTransitionPhase == .idle
                    && (dragSource == index || isOpeningAppTarget)
                let itemScale = (viewTransitionActive ? 1 : contentScale)
                    * entrance.scale * zoom.iconScale
                let hoverProgress = smoothstep(dragHoverProgress)
                let isHoverVisualTarget = dragHoverVisualTargetID == itemID
                    && draggedAppID != itemID
                let isFolderDropTarget = isHoverVisualTarget && folder != nil
                let targetScale = isFolderDropTarget ? 1 + 0.08 * hoverProgress : 1
                let iconSize = metrics.iconSize * itemScale * targetScale

                if let texture {
                    if isHoverVisualTarget,
                       app != nil,
                       let backgroundTexture = folderIconTextures.backgroundTexture(
                        for: GridLayoutPreset.current
                       ) {
                        let previewScale = 0.82 + 0.26 * hoverProgress
                        iconDrawTextures.append(backgroundTexture)
                        iconSprites.append(
                            .icon(
                                center: c,
                                size: metrics.iconSize * itemScale * previewScale,
                                uv: fullUV,
                                alpha: drawnAlpha * Float(hoverProgress),
                                pressed: false
                            )
                        )
                    }
                    if contentTransitionPhase == .idle,
                       store.isKeyboardNavigationActive,
                       store.keyboardFocusID == itemID {
                        // Insert at the front so the focus plate is encoded before
                        // every icon and can never cover a neighbouring sprite.
                        iconDrawTextures.insert(texture, at: 0)
                        iconSprites.insert(
                            .focus(center: c, size: iconSize * 1.06, alpha: drawnAlpha),
                            at: 0
                        )
                    }
                    let iconSprite = SpriteInstance.icon(
                        center: c,
                        size: iconSize,
                        uv: fullUV,
                        alpha: drawnAlpha,
                        pressed: pressed
                    )
                    if isDragged || isReturning {
                        // Draw the dragged item last so it remains visible when
                        // the pointer is over another icon.
                        draggedIconDraw = (texture, iconSprite)
                    } else {
                        iconDrawTextures.append(texture)
                        iconSprites.append(iconSprite)
                    }
                }

                if showLabels,
                   let label = textAtlas.layouts[itemID],
                   labelsBySheet.indices.contains(label.sheet) {
                    let snapToPixels = abs(itemScale - 1) < 0.001
                    let lc = CGPoint(
                        x: c.x,
                        y: c.y + metrics.iconSize * itemScale * 0.5
                            + 6 + label.heightPoints * 0.5 * itemScale
                    )
                    // Resting: size is an integer framebuffer pixel count so the
                    // vertex shader can snap the origin without stretching UVs.
                    // Animation keeps the point size and skips the snap.
                    let size = snapToPixels
                        ? pixelAlignedLabelSize(label)
                        : CGSize(
                            width: label.widthPoints * itemScale,
                            height: label.heightPoints * itemScale
                        )
                    labelsBySheet[label.sheet].append(
                        .label(
                            center: lc,
                            size: size,
                            uv: label.uv,
                            alpha: drawnAlpha * 0.95,
                            snapToPixels: snapToPixels
                        )
                    )
                }
            }
        }
        if let draggedIconDraw {
            iconDrawTextures.append(draggedIconDraw.texture)
            iconSprites.append(draggedIconDraw.sprite)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    private var windowScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Actual framebuffer pixels per view point. Prefer drawable metrics over
    /// `backingScaleFactor` so a 1:1 label covers an integer number of pixels
    /// even if the layer scale and window scale briefly disagree.
    private var pixelsPerPoint: CGSize {
        let fallback = max(windowScale, 1)
        let scaleX = drawableSize.width / max(bounds.width, 1)
        let scaleY = drawableSize.height / max(bounds.height, 1)
        return CGSize(
            width: scaleX >= 0.5 ? scaleX : fallback,
            height: scaleY >= 0.5 ? scaleY : fallback
        )
    }

    /// Display size whose framebuffer coverage equals the atlas texel count.
    private func pixelAlignedLabelSize(_ label: LabelLayout) -> CGSize {
        let scale = pixelsPerPoint
        return CGSize(
            width: CGFloat(label.widthPixels) / scale.width,
            height: CGFloat(label.heightPixels) / scale.height
        )
    }

    override func layout() {
        super.layout()
        // Text atlas validity already includes backing scale in its signature.
        // Bounds-only layouts must not trigger a full atlas rebuild mid-animation.
        needsDisplay = true
    }

    // MARK: - Input

    private var interactionPageOffset: Double {
        contentTransitionPhase == .fadingOut ? frozenPageOffset : currentPageOffset
    }

    private var isDragCancelledByLayout: Bool {
        dragGeneration != store.dragGeneration
    }

    private func discardCancelledDrag() {
        dragSource = nil
        draggedAppID = nil
        dragDestination = nil
        dragHoverTargetID = nil
        dragHoverVisualTargetID = nil
        didDrag = false
        store.setFolderDragState(isDragging: false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        draggedAppID = nil
        dragGeneration = store.dragGeneration
        dragPoint = CGPoint(x: dragStart.x, y: bounds.height - dragStart.y)
        dragGrabOffset = .zero
        edgePageDirection = 0
        dragHoverTargetID = nil
        dragHoverVisualTargetID = nil
        dragHoverProgress = 0
        dragReleaseAnimation = nil
        didDrag = false
        dragDestination = nil
        isPanningPage = false
        pageIndicatorClick = false
        panLastPoint = dragStart

        if LaunchpadFieldHitArea.rect(in: bounds).contains(dragStart) {
            return
        }
        if LaunchpadPageIndicatorHitArea.isEnabled(
            pageCount: store.pageCount,
            isSearching: store.isSearching
        ), LaunchpadPageIndicatorHitArea.rect(
            in: bounds,
            pageCount: store.pageCount,
            currentPage: store.currentPage
        ).contains(dragStart) {
            pageIndicatorClick = true
            return
        }

        if contentTransitionPhase != .idle {
            isPanningPage = true
            store.beginPagePan()
            startDisplayLink()
            needsDisplay = true
            return
        }

        let metrics = GridMetrics(size: bounds.size)
        if let hit = metrics.hitTest(point: dragStart, pageOffset: interactionPageOffset) {
            let index = hit.page * store.pageCapacity + hit.localIndex
            if displayedItems.indices.contains(index) {
                let item = displayedItems[index]
                if store.openedFolderID != nil, case .app(let app) = item {
                    store.focusApp(id: app.id)
                } else if store.openedFolderID != nil {
                    return
                } else if case .app(let app) = item {
                    store.focusApp(id: app.id)
                }
                dragSource = index
                draggedAppID = item.id
                let iconCenter = metrics.iconCenter(
                    globalIndex: Double(index),
                    pageOffset: interactionPageOffset
                )
                dragGrabOffset = CGPoint(
                    x: dragPoint.x - iconCenter.x,
                    y: dragPoint.y - iconCenter.y
                )
                if store.allowsUserLayoutEditing {
                    startDisplayLink()
                }
                needsDisplay = true
                return
            }
        }

        if store.openedFolderID != nil {
            // A blank click exits the folder. A drag that starts in blank space
            // remains a normal page-pan gesture and can move between folder pages.
            isPanningPage = true
            store.beginPagePan()
            startDisplayLink()
            needsDisplay = true
            return
        }

        isPanningPage = true
        store.beginPagePan()
        startDisplayLink()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard contentTransitionPhase == .idle else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if LaunchpadFieldHitArea.rect(in: bounds).contains(point) {
            return nil
        }
        if LaunchpadPageIndicatorHitArea.isEnabled(
            pageCount: store.pageCount,
            isSearching: store.isSearching
        ), LaunchpadPageIndicatorHitArea.rect(
            in: bounds,
            pageCount: store.pageCount,
            currentPage: store.currentPage
        ).contains(point) {
            return nil
        }

        let metrics = GridMetrics(size: bounds.size)
        if let hit = metrics.hitTest(point: point, pageOffset: interactionPageOffset) {
            let index = hit.page * store.pageCapacity + hit.localIndex
            if displayedItems.indices.contains(index) {
                if case .folder(let folder) = displayedItems[index] {
                    contextMenuApp = nil
                    contextMenuFolder = folder
                    return makeFolderContextMenu(for: folder)
                }
                if case .app(let app) = displayedItems[index] {
                    return makeAppContextMenu(for: app)
                }
            }
        }

        guard !store.isSearching else { return nil }
        contextMenuApp = nil
        contextMenuFolder = nil
        return makeLayoutSelectorMenu()
    }

    private func makeAppContextMenu(for app: AppInfo) -> NSMenu {
        contextMenuFolder = nil
        contextMenuApp = app
        store.focusApp(id: app.id)
        needsDisplay = true

        let menu = NSMenu(title: app.name)
        menu.addItem(withTitle: "打开", action: #selector(openContextMenuApp), keyEquivalent: "")
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealContextMenuApp), keyEquivalent: "")
        menu.addItem(withTitle: "显示简介", action: #selector(showContextMenuAppInfo), keyEquivalent: "")
        menu.addItem(.separator())

        let currentFolderID = store.folderContaining(appID: app.id)?.id
        let moveToFolderItem = NSMenuItem(title: "移入文件夹", action: nil, keyEquivalent: "")
        let folderSubmenu = NSMenu(title: "移入文件夹")
        for folder in store.orderedFolders {
            let item = NSMenuItem(
                title: folder.name,
                action: #selector(moveContextMenuAppToFolder(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = folder.id
            item.isEnabled = folder.id != currentFolderID
            folderSubmenu.addItem(item)
        }
        moveToFolderItem.submenu = folderSubmenu
        moveToFolderItem.isEnabled = store.allowsUserLayoutEditing && !store.orderedFolders.isEmpty
        menu.addItem(moveToFolderItem)

        if currentFolderID != nil {
            let removeItem = menu.addItem(
                withTitle: "从文件夹移出",
                action: #selector(removeContextMenuAppFromFolder),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.isEnabled = store.allowsUserLayoutEditing
        }
        menu.addItem(.separator())
        let hideItem = menu.addItem(withTitle: "隐藏", action: #selector(hideContextMenuApp), keyEquivalent: "")
        hideItem.isEnabled = !store.hiddenAppIDs.contains(app.id)
        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    private func makeLayoutSelectorMenu() -> NSMenu {
        let menu = NSMenu(title: "布局")

        let userHeader = NSMenuItem(title: "用户布局", action: nil, keyEquivalent: "")
        userHeader.isEnabled = false
        menu.addItem(userHeader)
        for profile in store.layoutProfiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(selectLayoutFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = LaunchpadLayoutSelectorID.user(profile.id)
            item.state = (store.layoutMode.isUser && store.activeLayoutProfileID == profile.id) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let autoHeader = NSMenuItem(title: "自动布局", action: nil, keyEquivalent: "")
        autoHeader.isEnabled = false
        menu.addItem(autoHeader)
        for kind in LaunchpadAutoLayoutKind.allCases {
            let item = NSMenuItem(
                title: kind.title,
                action: #selector(selectLayoutFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = LaunchpadLayoutSelectorID.auto(kind)
            if case .auto(let current) = store.layoutMode, current == kind {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectLayoutFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try store.selectLayoutSelector(id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法切换布局"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func makeFolderContextMenu(for folder: AppFolder) -> NSMenu {
        let menu = NSMenu(title: folder.name)
        let renameItem = menu.addItem(
            withTitle: "重命名",
            action: #selector(renameContextMenuFolder),
            keyEquivalent: ""
        )
        renameItem.target = self

        let mergeItem = NSMenuItem(title: "合并入文件夹", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "合并入文件夹")
        for target in store.orderedFolders where target.id != folder.id {
            let item = NSMenuItem(
                title: target.name,
                action: #selector(mergeContextMenuFolder(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = target.id
            submenu.addItem(item)
        }
        mergeItem.submenu = submenu
        mergeItem.isEnabled = !submenu.items.isEmpty
        menu.addItem(mergeItem)
        menu.addItem(.separator())
        let dissolveItem = menu.addItem(
            withTitle: "解散文件夹",
            action: #selector(dissolveContextMenuFolder),
            keyEquivalent: ""
        )
        dissolveItem.target = self
        return menu
    }

    @objc private func openContextMenuApp() {
        guard let app = contextMenuApp else { return }
        NotificationCenter.default.post(
            name: .qlaunchpadDismiss,
            object: nil,
            userInfo: ["openingAppID": app.id]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            QLaunchAppLauncher.open(app)
        }
        store.recordAppLaunch(app)
    }

    @objc private func revealContextMenuApp() {
        guard let app = contextMenuApp else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    @objc private func showContextMenuAppInfo() {
        guard let app = contextMenuApp else { return }
        let bundle = Bundle(url: app.url)
        let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "未知"
        let alert = NSAlert()
        alert.messageText = app.name
        alert.informativeText = "版本：\(version)\n标识符：\(app.bundleIdentifier)\n位置：\(app.url.path)"
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func hideContextMenuApp() {
        guard let app = contextMenuApp else { return }
        store.hide(app)
        contextMenuApp = nil
    }

    @objc private func moveContextMenuAppToFolder(_ sender: NSMenuItem) {
        guard let app = contextMenuApp,
              let folderID = sender.representedObject as? String else { return }
        _ = store.moveAppToFolder(appID: app.id, folderID: folderID)
        applyAnimatedLayout(store.activeDisplayItems)
        contextMenuApp = nil
        needsDisplay = true
    }

    @objc private func removeContextMenuAppFromFolder() {
        guard let app = contextMenuApp,
              let folderID = store.folderContaining(appID: app.id)?.id else { return }
        _ = store.removeAppFromFolder(appID: app.id, folderID: folderID)
        applyAnimatedLayout(store.activeDisplayItems)
        contextMenuApp = nil
        needsDisplay = true
    }

    @objc private func renameContextMenuFolder() {
        guard let folder = contextMenuFolder else { return }
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        field.selectText(nil)
        alert.accessoryView = field

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.store.renameFolder(folder.id, to: field.stringValue)
            }
            self.contextMenuFolder = nil
            self.needsDisplay = true
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func mergeContextMenuFolder(_ sender: NSMenuItem) {
        guard let source = contextMenuFolder,
              let targetID = sender.representedObject as? String,
              store.mergeFolder(sourceID: source.id, into: targetID) else { return }
        applyAnimatedLayout(store.activeDisplayItems)
        contextMenuFolder = nil
    }

    @objc private func dissolveContextMenuFolder() {
        guard let folder = contextMenuFolder else { return }
        let originSlot = reorderVisualSlots[folder.id]
            ?? Double(displayedItems.firstIndex(where: { $0.id == folder.id }) ?? 0)
        guard let memberIDs = store.dissolveFolder(folder.id) else { return }
        applyAnimatedLayout(
            store.activeDisplayItems,
            emergingItemIDs: Set(memberIDs),
            emergingFrom: originSlot
        )
        contextMenuFolder = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragCancelledByLayout {
            discardCancelledDrag()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        dragPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        if hypot(point.x - dragStart.x, point.y - dragStart.y) > 6 { didDrag = true }

        if !store.allowsUserLayoutEditing,
           draggedAppID != nil,
           !isPanningPage,
           didDrag {
            draggedAppID = nil
            dragSource = nil
            isPanningPage = true
            store.beginPagePan()
            startDisplayLink()
            needsDisplay = true
            return
        }

        if pageIndicatorClick {
            store.selectPage(at: point, in: bounds, scrubbing: true)
            startDisplayLink()
            needsDisplay = true
            return
        }

        if store.openedFolderID != nil, !isPanningPage {
            updateEdgePageDirection(for: point)
            updateFolderDrag(at: point)
            startDisplayLink()
            needsDisplay = true
            return
        }

        updateEdgePageDirection(for: point)

        if isPanningPage {
            let dx = point.x - panLastPoint.x
            panLastPoint = point
            store.updatePagePan(deltaPages: Double(-dx) / Double(max(bounds.width, 1)))
            startDisplayLink()
            needsDisplay = true
            return
        }

        guard dragSource != nil else { return }
        updateReorderDestination(at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragSource = nil
            draggedAppID = nil
            dragDestination = nil
            dragPoint = .zero
            dragGrabOffset = .zero
            edgePageDirection = 0
            dragHoverTargetID = nil
            isPanningPage = false
            pageIndicatorClick = false
            store.setFolderDragState(isDragging: false)
            needsDisplay = true
        }
        if pageIndicatorClick {
            let point = convert(event.locationInWindow, from: nil)
            store.selectPage(at: point, in: bounds, scrubbing: true)
            startDisplayLink()
            return
        }
        if isDragCancelledByLayout {
            if isPanningPage {
                store.endPagePan()
            }
            discardCancelledDrag()
            return
        }
        if isPanningPage {
            store.endPagePan()
            startDisplayLink()
            if store.openedFolderID != nil {
                if !didDrag {
                    store.exitFolder()
                }
                return
            }
            // Search results: a blank click clears the query and returns to the
            // page that was visible before search. A drag still pans results.
            if store.isSearching {
                if !didDrag {
                    store.updateSearch("")
                }
                return
            }
            // An empty-area click is a dismissal gesture. Once the pointer
            // moves past the drag threshold, the same gesture remains a page
            // pan and must not dismiss the Launchpad on mouse-up.
            if !didDrag {
                NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
            }
            return
        }

        if store.openedFolderID != nil {
            guard let draggedAppID else { return }
            if didDrag {
                if store.isFolderRemovalTargeted,
                   let folderID = store.openedFolderID,
                   store.removeAppFromFolder(appID: draggedAppID, folderID: folderID) {
                    applyAnimatedLayout(store.activeDisplayItems)
                } else {
                    beginDragReleaseAnimation(itemID: draggedAppID)
                }
                return
            }
            guard let app = store.app(withID: draggedAppID) else { return }
            store.recordAppLaunch(app)
            NotificationCenter.default.post(
                name: .qlaunchpadDismiss,
                object: nil,
                userInfo: ["openingAppID": app.id]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                QLaunchAppLauncher.open(app)
            }
            return
        }

        if didDrag, let draggedAppID {
            var completedGrouping = false
            if let dragHoverTargetID,
               let source = displayedItems.first(where: { $0.id == draggedAppID }),
               let target = displayedItems.first(where: { $0.id == dragHoverTargetID }) {
                switch (source, target) {
                case (.folder(let sourceFolder), .folder(let targetFolder)):
                    completedGrouping = store.mergeFolder(
                        sourceID: sourceFolder.id,
                        into: targetFolder.id
                    )
                case (.app, .folder):
                    store.moveAppIntoFolder(appID: draggedAppID, folderID: target.id)
                    completedGrouping = true
                case (.app, .app(let targetApp)):
                    if targetApp.id != draggedAppID {
                        completedGrouping = store.createFolder(
                            draggedAppID: draggedAppID,
                            targetAppID: targetApp.id
                        ) != nil
                    }
                case (.folder, .app):
                    break
                }
                if completedGrouping {
                    applyAnimatedLayout(store.activeDisplayItems)
                }
            }
            if !completedGrouping {
                beginDragReleaseAnimation(itemID: draggedAppID)
            }
            return
        }

        guard let source = dragSource, displayedItems.indices.contains(source) else { return }
        if !didDrag, contentTransitionPhase == .idle {
            let item = displayedItems[source]
            if case .folder(let folder) = item {
                store.enterFolder(folder.id)
                return
            }
            guard case .app(let app) = item else { return }
            store.recordAppLaunch(app)
            NotificationCenter.default.post(
                name: .qlaunchpadDismiss,
                object: nil,
                userInfo: ["openingAppID": app.id]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                QLaunchAppLauncher.open(app)
            }
        }
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }

    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }

    override func scrollWheel(with event: NSEvent) {
        store.handleScroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            isPrecise: event.hasPreciseScrollingDeltas
        )
        startDisplayLink()
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
}
