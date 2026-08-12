import AppKit
import Metal
import MetalKit
import QuartzCore
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
    /// x = kind (0 focus plate, 1 icon, 2 pressed icon, 3 text), y = alpha
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
        alpha: Float
    ) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size.width), Float(size.height)),
            uvRect: uv,
            kindAlpha: SIMD4(3, alpha, 0, 0)
        )
    }

    static func folderBackground(center: CGPoint, size: CGSize, alpha: Float) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size.width), Float(size.height)),
            uvRect: SIMD4(0, 0, 1, 1),
            kindAlpha: SIMD4(4, alpha, 0, 0)
        )
    }

    static func dimOverlay(center: CGPoint, size: CGSize, alpha: Float) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size.width), Float(size.height)),
            uvRect: SIMD4(0, 0, 1, 1),
            kindAlpha: SIMD4(5, alpha, 0, 0)
        )
    }

    static func roundedPanel(center: CGPoint, size: CGSize, alpha: Float) -> SpriteInstance {
        SpriteInstance(
            centerSize: SIMD4(Float(center.x), Float(center.y), Float(size.width), Float(size.height)),
            uvRect: SIMD4(0, 0, 1, 1),
            kindAlpha: SIMD4(6, alpha, 0, 0)
        )
    }
}

private struct FrameUniforms {
    var viewport: SIMD2<Float>
    var _pad: SIMD2<Float> = .zero
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

    init(apps: [AppInfo], scale: CGFloat) {
        self.apps = AppListSignature(apps: apps)
        self.scale = scale
    }

    func matches(_ displayedApps: [AppInfo], scale: CGFloat) -> Bool {
        self.scale == scale && apps.matches(displayedApps)
    }
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
    private let iconPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let iconTextures: IconTextureStore
    private let textAtlas: TextAtlas

    private var iconSampler: MTLSamplerState!
    private var textSampler: MTLSamplerState!

    private var currentPageOffset = 0.0
    private var lastCatalogSignature: AppListSignature?
    private var lastTextSignature: TextAtlasSignature?
    private var lastFrameTime = CACurrentMediaTime()
    private var resourcePrewarmSignature: AppListSignature?
    private var resourcePrewarmTask: Task<Void, Never>?
    private var isResourcePrewarmingPaused = false
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
    private var dragDestination: Int?
    private var dragStart: CGPoint = .zero
    /// Current pointer position in top-left view coordinates.
    private var dragPoint: CGPoint = .zero
    /// Keeps the icon under the same part of the pointer that was clicked.
    private var dragGrabOffset: CGPoint = .zero
    private var edgePageDirection = 0
    private var lastEdgePageTurnTime: CFTimeInterval = 0
    private var dragHoverTargetID: String?
    private var folderPressedAppID: String?
    private var didDrag = false
    private var isPanningPage = false
    private var panLastPoint: CGPoint = .zero
    private var contextMenuApp: AppInfo?

    // Keep visual positions separate from the catalog order so reordering an
    // item does not make the surrounding icons jump to their new cells.
    private var reorderVisualSlots: [String: Double] = [:]
    private var isReorderAnimationActive = false
    private let reorderAnimationRate = 20.0

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

    // Search: sequential fade-out → swap → fade-in (single grid only).
    private var displayedItems: [LaunchpadItem] = []
    private var pendingFilterItems: [LaunchpadItem]?
    private var lastFilterSignature: AppListSignature?
    private enum SearchPhase { case idle, fadingOut, fadingIn }
    private var searchPhase: SearchPhase = .idle
    private var searchPhaseStart: CFTimeInterval = 0
    private var searchGridAlpha: Float = 1
    private var frozenPageOffset: Double = 0
    private let searchHalfDuration: CFTimeInterval = 0.15

    private var openFolderID: String?
    private var folderScrollOffset: CGFloat = 0
    private var folderScrollTarget: CGFloat = 0
    private let folderColumns = 3
    private let folderRows = 4
    private let folderPreviewSize: CGFloat = 102
    private let folderPreviewIconSize: CGFloat = 22
    private let folderPreviewIconSpacing: CGFloat = 4
    private let folderPreviewPadding: CGFloat = 14

    // MARK: Init

    init(store: AppStore) {
        self.store = store
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal is required by QLaunchpad")
        }
        self.commandQueue = commandQueue
        iconTextures = IconTextureStore(device: device)
        textAtlas = TextAtlas(device: device)
        inFlightFrames = (0..<3).map { _ in FrameResources() }

        let librarySource = Self.shaderSource
        guard let library = try? device.makeLibrary(source: librarySource, options: nil),
              let vertex = library.makeFunction(name: "ql_vertex"),
              let iconFrag = library.makeFunction(name: "ql_icon_fragment"),
              let textFrag = library.makeFunction(name: "ql_text_fragment") else {
            fatalError("Unable to compile QLaunchpad shaders")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = iconFrag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        // Premultiplied alpha blending (atlas + loader produce premultiplied content).
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let iconPipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            fatalError("Unable to create icon pipeline")
        }
        self.iconPipeline = iconPipeline

        desc.fragmentFunction = textFrag
        guard let textPipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            fatalError("Unable to create text pipeline")
        }
        self.textPipeline = textPipeline

        super.init(frame: .zero, device: device)
        delegate = self
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = min(120, NSScreen.main?.maximumFramesPerSecond ?? 60)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm_srgb
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(
            name: CGColorSpace.displayP3
        )
        autoResizeDrawable = true

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
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        resourcePrewarmTask?.cancel()
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Shader source

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Sprite {
        float4 centerSize; // xy center, zw size (points, top-left y)
        float4 uvRect;     // xy origin, zw size (Metal top-left UV)
        float4 kindAlpha;  // x kind, y alpha
    };
    struct Uniforms {
        float2 viewport;
        float2 pad;
    };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float2 size;
        float kind;
        float alpha;
    };

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
        // Top-left pixel space → NDC (y flips).
        float2 ndc = float2(
            pixel.x / u.viewport.x * 2.0 - 1.0,
            1.0 - pixel.y / u.viewport.y * 2.0
        );
        VertexOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = s.uvRect.xy + (local + 0.5) * s.uvRect.zw;
        o.size = s.centerSize.zw;
        o.kind = s.kindAlpha.x;
        o.alpha = s.kindAlpha.y;
        return o;
    }

    fragment float4 ql_icon_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler samp [[sampler(0)]])
    {
        if (in.kind > 5.5) {
            float2 halfSize = in.size * 0.5;
            float2 p = abs((in.uv - 0.5) * in.size);
            float radius = min(28.0, min(halfSize.x, halfSize.y) * 0.18);
            float2 q = max(p - (halfSize - radius), 0.0);
            float distance = length(q) + min(max(p.x - halfSize.x + radius,
                                                  p.y - halfSize.y + radius), 0.0) - radius;
            float coverage = 1.0 - smoothstep(-1.0, 1.0, distance);
            float topLight = (1.0 - in.uv.y) * 0.12;
            float3 glass = float3(0.74, 0.81, 0.90) + topLight;
            float a = coverage * in.alpha * 0.72;
            return float4(glass * a, a);
        }
        if (in.kind > 4.5) {
            return float4(0.0, 0.0, 0.0, in.alpha * 0.34);
        }
        if (in.kind > 3.5) {
            float2 p = abs(in.uv - 0.5) * 2.0;
            float shape = pow(p.x, 4.0) + pow(p.y, 4.0);
            float feather = max(fwidth(shape) * 1.25, 0.003);
            float coverage = 1.0 - smoothstep(1.0 - feather, 1.0 + feather, shape);
            float highlight = (1.0 - p.y) * 0.13 + (1.0 - p.x) * 0.04;
            float3 glass = float3(0.78, 0.84, 0.91) + highlight;
            float a = coverage * in.alpha * 0.78;
            return float4(glass * a, a);
        }
        if (in.kind < 0.5) {
            // A fourth-order superellipse closely follows the continuous rounded
            // silhouette used by modern macOS app icons.
            float2 p = abs(in.uv - 0.5) * 2.0;
            float shape = pow(p.x, 4.0) + pow(p.y, 4.0);
            float feather = max(fwidth(shape) * 0.75, 0.002);
            float coverage = 1.0 - smoothstep(1.0 - feather, 1.0 + feather, shape);
            float a = coverage * 0.34 * in.alpha;
            return float4(0.0, 0.0, 0.0, a);
        }

        // High-quality 4x4 separable binomial reconstruction over premultiplied
        // linear-P3 values. Positive [1, 3, 3, 1]^2 weights avoid the ringing
        // that negative-lobe filters such as Lanczos can create around alpha.
        const float offsets[4] = { -0.75, -0.25, 0.25, 0.75 };
        const float weights[4] = { 1.0, 3.0, 3.0, 1.0 };
        float2 pixelDx = dfdx(in.uv);
        float2 pixelDy = dfdy(in.uv);
        float4 c = float4(0.0);
        for (uint y = 0; y < 4; ++y) {
            for (uint x = 0; x < 4; ++x) {
                float2 sampleUV = in.uv
                    + pixelDx * offsets[x]
                    + pixelDy * offsets[y];
                c += atlas.sample(samp, sampleUV) * weights[x] * weights[y];
            }
        }
        c *= (1.0 / 64.0);
        float pressed = (in.kind > 1.5 && in.kind < 2.5) ? 0.4 : 1.0;
        // Pressed brightness is a real premultiplied opacity, not an RGB-only
        // darkening. Keeping RGB and alpha on the same curve prevents a launched
        // icon from appearing to brighten when its dismissal fade begins.
        return c * (in.alpha * pressed);
    }

    fragment float4 ql_text_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler samp [[sampler(0)]])
    {
        // Text atlas is already linear Display P3 + premultiplied alpha, exactly
        // like icon textures. Filtering and blending therefore stay linear.
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
        let folderScrollActive = openFolderID != nil
            && abs(folderScrollTarget - folderScrollOffset) > 0.001
        if pageSettled
            && !animatingPresentation
            && searchPhase == .idle
            && !isReorderAnimationActive
            && !dragInteractionActive
            && !folderScrollActive {
            displayLink?.invalidate()
            displayLink = nil
            if abs(store.pageOffset - currentPageOffset) > 0.0001 {
                store.pageOffset = currentPageOffset
            }
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if let point = syncDragPointToMouse() {
            updateReorderDestination(at: point)
        }
        tickEdgePageTurn(now: CACurrentMediaTime())
        needsDisplay = true
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
              searchPhase == .idle,
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
              !store.isSearching,
              searchPhase == .idle else {
            return
        }

        let metrics = GridMetrics(size: bounds.size)
        guard let hit = metrics.hitTest(point: point, pageOffset: interactionPageOffset) else {
            dragHoverTargetID = nil
            return
        }

        let destination = hit.page * store.pageCapacity + hit.localIndex
        guard displayedItems.indices.contains(destination) else {
            dragHoverTargetID = nil
            return
        }
        if destination == source { return }

        let target = displayedItems[destination]
        dragHoverTargetID = target.id
        if case .folder = target {
            return
        }

        store.moveItem(from: source, to: destination)
        displayedItems = store.displayItems
        lastFilterSignature = AppListSignature(items: displayedItems)
        dragSource = destination
        dragDestination = destination
        isReorderAnimationActive = true
        startDisplayLink()
    }

    @objc private func storeChanged() {
        scheduleResourcePrewarmingIfNeeded()
        startDisplayLink()
        needsDisplay = true
    }

    @objc private func settingsChanged() {
        needsDisplay = true
    }

    @objc private func clearCacheRequested() {
        pauseResourcePrewarming()
        iconTextures.clear()
        textAtlas.clear()
        lastCatalogSignature = nil
        lastTextSignature = nil
        resourcePrewarmSignature = nil
        isResourcePrewarmingPaused = false
        scheduleResourcePrewarmingIfNeeded()
        startDisplayLink()
        needsDisplay = true
    }

    @objc private func presentationChanged(_ note: Notification) {
        guard let showing = note.userInfo?["showing"] as? Bool else { return }
        let style = (note.userInfo?["animationStyle"] as? String)
            .flatMap(LaunchpadAnimationStyle.init(rawValue:))
            ?? (showing ? LaunchpadAnimationStyle.current : presentationStyle)
        pauseResourcePrewarming()
        presentationStyle = style
        isShowingPresentation = showing
        stationaryDismissedAppID = showing
            ? nil
            : note.userInfo?["openingAppID"] as? String
        presentStartTime = CACurrentMediaTime()
        if showing {
            presentFrom = 0
            presentTo = 1
        } else {
            presentFrom = store.presentationProgress
            presentTo = 0
        }
        let fullDuration = showing ? style.duration : style.dismissalDuration
        presentDurationActive = fullDuration * CFTimeInterval(abs(presentTo - presentFrom))
        if presentDurationActive <= 0.0001 {
            animatingPresentation = false
            applyPresentationPhase(presentTo)
            if showing { store.markVisible() }
            resumeResourcePrewarming()
            needsDisplay = true
            return
        }
        animatingPresentation = true
        startDisplayLink()
        needsDisplay = true
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
        pauseResourcePrewarming()
        startDisplayLink()
        needsDisplay = true
    }

    /// Warm page one first, then continue through the remaining catalog on a
    /// utility-priority worker so later page turns never synchronously decode icons.
    private func scheduleResourcePrewarmingIfNeeded() {
        guard !isResourcePrewarmingPaused else { return }
        let catalog = store.apps
        let visibleApps = store.filteredApps
        guard !catalog.isEmpty, !visibleApps.isEmpty else { return }
        let signature = AppListSignature(apps: catalog)
        guard signature != resourcePrewarmSignature else { return }
        resourcePrewarmSignature = signature

        resourcePrewarmTask?.cancel()
        iconTextures.rebuild(with: catalog)
        lastCatalogSignature = signature

        if displayedItems.isEmpty {
            displayedItems = store.displayItems
            lastFilterSignature = AppListSignature(items: displayedItems)
            searchPhase = .idle
            searchGridAlpha = 1
        }

        let firstPageEnd = min(store.pageCapacity, visibleApps.count)
        let firstPage = Array(visibleApps[..<firstPageEnd])
        let firstPageIDs = Set(firstPage.map(\.id))
        let remaining = catalog.filter { !firstPageIDs.contains($0.id) }
        let textureStore = iconTextures
        let scale = windowScale
        let textSignature = TextAtlasSignature(apps: visibleApps, scale: scale)

        resourcePrewarmTask = Task.detached(priority: .utility) { [self] in
            // Page one is deliberately first in the queue.
            for app in firstPage {
                guard !Task.isCancelled else { return }
                autoreleasepool { _ = textureStore.texture(for: app) }
            }

            guard !Task.isCancelled else { return }
            await installPrewarmedTextAtlas(
                apps: visibleApps,
                catalogSignature: signature,
                textSignature: textSignature,
                scale: scale
            )

            // Decode/upload the other pages incrementally at lower priority.
            for app in remaining {
                guard !Task.isCancelled else { return }
                autoreleasepool { _ = textureStore.texture(for: app) }
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            await finishResourcePrewarming(catalogSignature: signature)
        }
    }

    private func installPrewarmedTextAtlas(
        apps: [AppInfo],
        catalogSignature: AppListSignature,
        textSignature: TextAtlasSignature,
        scale: CGFloat
    ) {
        guard !isResourcePrewarmingPaused,
              resourcePrewarmSignature == catalogSignature else { return }
        if lastTextSignature != textSignature {
            textAtlas.rebuild(with: apps, scale: scale)
            lastTextSignature = textSignature
        }
        needsDisplay = true
    }

    private func finishResourcePrewarming(catalogSignature: AppListSignature) {
        guard !isResourcePrewarmingPaused,
              resourcePrewarmSignature == catalogSignature else { return }
        resourcePrewarmTask = nil
        needsDisplay = true
    }

    private func pauseResourcePrewarming() {
        isResourcePrewarmingPaused = true
        resourcePrewarmTask?.cancel()
        resourcePrewarmTask = nil
    }

    private func resumeResourcePrewarming() {
        isResourcePrewarmingPaused = false
        // Restart the ordered queue; already-cached page-one textures are no-ops.
        resourcePrewarmSignature = nil
        scheduleResourcePrewarmingIfNeeded()
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
                guard let member = folder.appIDs.lazy.compactMap({ self.store.app(withID: $0) }).first else {
                    continue
                }
                append(
                    AppInfo(
                        id: folder.id,
                        name: folder.name,
                        url: member.url,
                        bundleIdentifier: folder.id
                    )
                )
                for appID in folder.appIDs {
                    if let app = store.app(withID: appID) { append(app) }
                }
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

    private func noteFilterChangeIfNeeded() {
        let target = store.displayItems
        guard lastFilterSignature?.matches(target) != true else { return }
        let signature = AppListSignature(items: target)
        lastFilterSignature = signature

        if displayedItems.isEmpty {
            displayedItems = target
            pendingFilterItems = nil
            searchPhase = .idle
            searchGridAlpha = 1
            return
        }
        if signature.matches(displayedItems) {
            pendingFilterItems = nil
            return
        }

        pendingFilterItems = target
        switch searchPhase {
        case .idle:
            frozenPageOffset = currentPageOffset
            searchPhase = .fadingOut
            searchPhaseStart = CACurrentMediaTime()
            searchGridAlpha = 1
            startDisplayLink()
        case .fadingOut:
            break
        case .fadingIn:
            frozenPageOffset = currentPageOffset
            let already = 1 - CGFloat(searchGridAlpha)
            searchPhase = .fadingOut
            searchPhaseStart = CACurrentMediaTime() - searchHalfDuration * already
            startDisplayLink()
        }
    }

    private func tickSearchTransition(now: CFTimeInterval) {
        guard searchPhase != .idle else { return }
        let t = CGFloat((now - searchPhaseStart) / searchHalfDuration)
        switch searchPhase {
        case .idle:
            break
        case .fadingOut:
            searchGridAlpha = Float(1 - smoothstep(t))
            if t >= 1 {
                displayedItems = pendingFilterItems ?? store.displayItems
                resetReorderVisualSlots(to: displayedItems)
                pendingFilterItems = nil
                currentPageOffset = store.pageOffset
                frozenPageOffset = store.pageOffset
                searchPhase = .fadingIn
                searchPhaseStart = now
                searchGridAlpha = 0
            }
        case .fadingIn:
            searchGridAlpha = Float(smoothstep(t))
            if t >= 1 {
                searchGridAlpha = 1
                searchPhase = .idle
                if lastFilterSignature?.matches(displayedItems) != true {
                    lastFilterSignature = nil
                    noteFilterChangeIfNeeded()
                }
            }
        }
    }

    // MARK: Draw

    func draw(in view: MTKView) {
        // A 256pt layout needs a freshly rasterized 1024px icon source. Clear
        // the previous 512px cache before any new frame can draw it.
        iconTextures.configure(for: GridLayoutPreset.current)

        // Prune icon cache when catalog changes (icons load lazily when drawn).
        if lastCatalogSignature?.matches(store.apps) != true {
            let catalogSignature = AppListSignature(apps: store.apps)
            iconTextures.rebuild(with: store.apps)
            lastCatalogSignature = catalogSignature
        }
        // If apps just arrived, populate the grid immediately (no empty first open).
        if displayedItems.isEmpty, !store.displayItems.isEmpty {
            displayedItems = store.displayItems
            lastFilterSignature = AppListSignature(items: displayedItems)
            searchPhase = .idle
            searchGridAlpha = 1
            lastTextSignature = nil
        }

        noteFilterChangeIfNeeded()
        if store.isSearching {
            openFolderID = nil
        }

        // Text atlas only for currently displayed apps (fast). Full-catalog rebuild
        // was freezing the first frame so nothing appeared for seconds.
        let scale = windowScale
        let labelApps = textAtlasApps(for: displayedItems)
        if lastTextSignature?.matches(labelApps, scale: scale) != true,
           !labelApps.isEmpty {
            let textSignature = TextAtlasSignature(apps: labelApps, scale: scale)
            textAtlas.rebuild(with: labelApps, scale: scale)
            lastTextSignature = textSignature
        }

        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 1.0 / 240.0), 1.0 / 30.0)
        lastFrameTime = now
        tickSearchTransition(now: now)
        tickFolderScroll(dt: dt)
        synchronizeReorderVisualSlots(with: displayedItems)
        tickReorderAnimation(dt: dt)

        if searchPhase != .fadingOut {
            let pageTarget = store.isPageGestureActive ? store.pageOffset : store.targetPage
            let distance = pageTarget - currentPageOffset
            if abs(distance) > 0.0005 {
                let k = store.isPageGestureActive ? 56.0 : pageSpringResponse
                currentPageOffset += distance * (1.0 - exp(-dt * k))
            } else {
                currentPageOffset = pageTarget
            }
        }

        if animatingPresentation {
            let t = min(1, max(0, (now - presentStartTime) / presentDurationActive))
            let phase = presentFrom + (presentTo - presentFrom) * CGFloat(t)
            applyPresentationPhase(phase)
            if t >= 1 {
                animatingPresentation = false
                applyPresentationPhase(presentTo)
                if isShowingPresentation { store.markVisible() }
                resumeResourcePrewarming()
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
        let gridAlpha = presentAlpha * max(searchGridAlpha, 0)
        guard gridAlpha > 0.001 else {
            clearDrawableIfAvailable()
            stopDisplayLinkIfIdle()
            return
        }

        // Avoid building frame storage when the layer cannot supply a drawable.
        guard let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
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
        let pageOffset = searchPhase == .fadingOut ? frozenPageOffset : currentPageOffset

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
            metrics: metrics,
            midX: midX,
            midY: midY,
            iconDrawTextures: &iconDrawTextures,
            iconSprites: &iconSprites,
            labelsBySheet: &labelsBySheet
        )
        if !store.isSearching {
            buildOpenFolder(
                alpha: gridAlpha,
                iconDrawTextures: &iconDrawTextures,
                iconSprites: &iconSprites,
                labelsBySheet: &labelsBySheet
            )
        }

        prepareFrameResources(frameSlot)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            frameSlot.availability.signal()
            return
        }

        var uniforms = FrameUniforms(
            viewport: SIMD2(Float(bounds.width), Float(bounds.height))
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<FrameUniforms>.stride,
            index: 1
        )

        encoder.setRenderPipelineState(iconPipeline)
        encoder.setFragmentSamplerState(iconSampler, index: 0)
        if let iconBuffer = frameSlot.iconBuffer {
            for (index, texture) in iconDrawTextures.enumerated() {
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

        // Labels remain atlas-batched, but also live in immutable frame storage.
        if let textBuffer = frameSlot.textBuffer {
            encoder.setRenderPipelineState(textPipeline)
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
            label: "QLaunchpad icon instances"
        )
        upload(
            textSprites,
            to: &resources.textBuffer,
            capacity: &resources.textCapacity,
            label: "QLaunchpad text instances"
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

    private func buildFolderPreview(
        _ folder: AppFolder,
        center: CGPoint,
        size: CGFloat,
        alpha: Float,
        iconDrawTextures: inout [MTLTexture],
        iconSprites: inout [SpriteInstance]
    ) {
        let members = folder.appIDs.compactMap { store.app(withID: $0) }.prefix(9)
        guard let backgroundApp = members.first,
              let backgroundTexture = iconTextures.texture(for: backgroundApp) else {
            return
        }

        iconDrawTextures.append(backgroundTexture)
        iconSprites.append(
            .folderBackground(
                center: center,
                size: CGSize(width: size, height: size),
                alpha: alpha
            )
        )

        let miniSize = folderPreviewIconSize
        let gap = folderPreviewIconSpacing
        let left = center.x - size * 0.5 + folderPreviewPadding + miniSize * 0.5
        let top = center.y - size * 0.5 + folderPreviewPadding + miniSize * 0.5
        for (offset, app) in members.enumerated() {
            guard let texture = iconTextures.texture(for: app) else { continue }
            let column = offset % 3
            let row = offset / 3
            let miniCenter = CGPoint(
                x: left + CGFloat(column) * (miniSize + gap),
                y: top + CGFloat(row) * (miniSize + gap)
            )
            iconDrawTextures.append(texture)
            iconSprites.append(
                .icon(
                    center: miniCenter,
                    size: miniSize,
                    uv: SIMD4(0, 0, 1, 1),
                    alpha: alpha,
                    pressed: false
                )
            )
        }
    }

    private func buildGrid(
        items: [LaunchpadItem],
        pageOffset: Double,
        alphaScale: Float,
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
        let center = Int(pageOffset.rounded())
        // Avoid lazy-loading adjacent pages while the entrance animation is live.
        // The background prewarmer resumes as soon as presentation completes.
        let entranceActive = iconEntranceProgress < 0.999
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
                if case .folder(let folder) = item {
                    let visualIndex = reorderVisualSlots[folder.id] ?? Double(index)
                    var center = metrics.iconCenter(globalIndex: visualIndex, pageOffset: pageOffset)
                    let isDragged = didDrag
                        && searchPhase == .idle
                        && draggedAppID == folder.id
                    if isDragged {
                        center = CGPoint(
                            x: dragPoint.x - dragGrabOffset.x,
                            y: dragPoint.y - dragGrabOffset.y
                        )
                    }
                    let pageFade = Float(max(
                        0,
                        min(1, 1.15 - abs(center.x - midX) / max(bounds.width, 1))
                    ))
                    let alpha = pageFade * alphaScale
                    if alpha > 0.002 {
                        let folderSize = folderPreviewSize * (isDragged ? 1.08 : 1)
                        buildFolderPreview(
                            folder,
                            center: center,
                            size: folderSize,
                            alpha: alpha,
                            iconDrawTextures: &iconDrawTextures,
                            iconSprites: &iconSprites
                        )
                        if showLabels,
                           let label = textAtlas.layouts[folder.id],
                           labelsBySheet.indices.contains(label.sheet) {
                            let lc = CGPoint(
                                x: center.x,
                                y: center.y + folderSize * 0.5
                                    + 6 + label.heightPoints * 0.5 * (isDragged ? 1.08 : 1)
                            )
                            labelsBySheet[label.sheet].append(
                                .label(
                                    center: lc,
                                    size: CGSize(
                                        width: label.widthPoints * (isDragged ? 1.08 : 1),
                                        height: label.heightPoints * (isDragged ? 1.08 : 1)
                                    ),
                                    uv: label.uv,
                                    alpha: alpha * 0.9
                                )
                            )
                        }
                    }
                    continue
                }
                guard case .app(let app) = item else { continue }
                let isOpeningAppTarget = !isShowingPresentation
                    && stationaryDismissedAppID == app.id
                let visualIndex = reorderVisualSlots[app.id] ?? Double(index)
                var c = metrics.iconCenter(globalIndex: visualIndex, pageOffset: pageOffset)
                if didDrag,
                   searchPhase == .idle,
                   draggedAppID == app.id {
                    // The dragged icon follows the pointer directly. The other
                    // icons still use their animated visual slots below.
                    c = CGPoint(
                        x: dragPoint.x - dragGrabOffset.x,
                        y: dragPoint.y - dragGrabOffset.y
                    )
                }
                let isDragged = didDrag
                    && searchPhase == .idle
                    && draggedAppID == app.id
                let zoom = isOpeningAppTarget
                    ? (
                        opacity: Float(1),
                        layoutScale: CGFloat(1),
                        iconScale: CGFloat(1)
                    )
                    : iconZoom(localIndex: local)
                if presentationStyle == .zoom, presentationPhase < 0.999 {
                    c.x = midX + (c.x - midX) * zoom.layoutScale
                    c.y = midY + (c.y - midY) * zoom.layoutScale
                }
                if contentScale < 0.999 {
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
                    : iconEntrance(localIndex: local)
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
                let pageFade = Float(max(
                    0,
                    min(1, 1.15 - abs(finalCenter.x - midX) / max(bounds.width, 1))
                ))
                let alpha = pageFade * alphaScale * entrance.opacity * zoom.opacity

                // The start frame is visually empty, but it still resolves every
                // first-page texture before the GPU-completion presentation gate.
                let primedTexture = isPrimingPresentationFrame
                    ? iconTextures.texture(for: app)
                    : nil
                guard alpha > 0.002 else { continue }

                // Preserve the exact 40% pressed opacity while the launched
                // icon fades. Clearing dragSource on mouse-up must not briefly
                // restore full brightness and produce a visible flash.
                let pressed = !isDragged
                    && searchPhase == .idle
                    && (dragSource == index || isOpeningAppTarget)
                let dragScale: CGFloat = isDragged ? 1.08 : 1
                let itemScale = contentScale * entrance.scale * zoom.iconScale * dragScale
                let iconSize = metrics.iconSize * itemScale

                if let texture = primedTexture ?? iconTextures.texture(for: app) {
                    if searchPhase == .idle,
                       store.isKeyboardNavigationActive,
                       store.keyboardFocusID == app.id {
                        // Insert at the front so the focus plate is encoded before
                        // every icon and can never cover a neighbouring sprite.
                        iconDrawTextures.insert(texture, at: 0)
                        iconSprites.insert(
                            .focus(center: c, size: iconSize * 1.06, alpha: alpha),
                            at: 0
                        )
                    }
                    let iconSprite = SpriteInstance.icon(
                        center: c,
                        size: iconSize,
                        uv: fullUV,
                        alpha: alpha,
                        pressed: pressed
                    )
                    if isDragged {
                        // Draw the dragged item last so it remains visible when
                        // the pointer is over another icon.
                        draggedIconDraw = (texture, iconSprite)
                    } else {
                        iconDrawTextures.append(texture)
                        iconSprites.append(iconSprite)
                    }
                }

                if showLabels,
                   let label = textAtlas.layouts[app.id],
                   labelsBySheet.indices.contains(label.sheet) {
                    let lc = CGPoint(
                        x: c.x,
                        y: c.y + iconSize * 0.5 + 6 + label.heightPoints * 0.5 * itemScale
                    )
                    labelsBySheet[label.sheet].append(
                        .label(
                            center: lc,
                            size: CGSize(
                                width: label.widthPoints * itemScale,
                                height: label.heightPoints * itemScale
                            ),
                            uv: label.uv,
                            alpha: alpha * 0.9
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

    private var folderWindowRect: CGRect {
        let iconSize = GridMetrics(size: bounds.size).iconSize
        let columnGap: CGFloat = 16
        let horizontalPadding: CGFloat = 28
        let titleAndTopPadding: CGFloat = 64
        let rowHeight = iconSize + 28
        let bottomPadding: CGFloat = 24
        let contentWidth = iconSize * 3 + columnGap * 2 + horizontalPadding * 2
        let contentHeight = titleAndTopPadding + rowHeight * 4 + bottomPadding
        let width = min(max(contentWidth, 400), bounds.width - 48)
        let height = min(max(contentHeight, 520), bounds.height - 48)
        return CGRect(
            x: (bounds.width - width) * 0.5,
            y: (bounds.height - height) * 0.5,
            width: width,
            height: height
        )
    }

    private var folderCellMetrics: (rect: CGRect, cellWidth: CGFloat, cellHeight: CGFloat, iconSize: CGFloat) {
        let rect = folderWindowRect
        let iconSize = GridMetrics(size: bounds.size).iconSize
        let cellWidth = (rect.width - 56) / CGFloat(folderColumns)
        let cellHeight = iconSize + 28
        return (rect, cellWidth, cellHeight, iconSize)
    }

    private func folderMaxScrollOffset(for count: Int) -> CGFloat {
        let totalRows = Int(ceil(Double(max(count, 1)) / Double(folderColumns)))
        return CGFloat(max(0, totalRows - folderRows))
    }

    private func tickFolderScroll(dt: CFTimeInterval) {
        guard openFolderID != nil else { return }
        let distance = folderScrollTarget - folderScrollOffset
        if abs(distance) < 0.001 {
            folderScrollOffset = folderScrollTarget
        } else {
            folderScrollOffset += distance * (1 - exp(-dt * 18))
        }
    }

    private func buildOpenFolder(
        alpha: Float,
        iconDrawTextures: inout [MTLTexture],
        iconSprites: inout [SpriteInstance],
        labelsBySheet: inout [[SpriteInstance]]
    ) {
        guard let openFolderID,
              let folder = store.folder(withID: openFolderID) else {
            return
        }
        let children = folder.appIDs.compactMap { store.app(withID: $0) }
        let rect = folderWindowRect
        guard let backgroundApp = children.first,
              let backgroundTexture = iconTextures.texture(for: backgroundApp) else {
            return
        }

        iconDrawTextures.append(backgroundTexture)
        iconSprites.append(
            .dimOverlay(
                center: CGPoint(x: bounds.midX, y: bounds.midY),
                size: bounds.size,
                alpha: alpha
            )
        )
        let center = CGPoint(x: rect.midX, y: rect.midY)
        iconDrawTextures.append(backgroundTexture)
        iconSprites.append(.roundedPanel(center: center, size: rect.size, alpha: alpha))
        let titleTop: CGFloat = 30
        if let label = textAtlas.layouts[folder.id], labelsBySheet.indices.contains(label.sheet) {
            labelsBySheet[label.sheet].append(
                .label(
                    center: CGPoint(x: rect.midX, y: rect.minY + titleTop),
                    size: CGSize(width: label.widthPoints, height: label.heightPoints),
                    uv: label.uv,
                    alpha: alpha
                )
            )
        }

        let contentTop = rect.minY + 72
        let metrics = folderCellMetrics
        let cellWidth = metrics.cellWidth
        let cellHeight = metrics.cellHeight
        let iconSize = metrics.iconSize
        let maxOffset = folderMaxScrollOffset(for: children.count)
        folderScrollOffset = min(max(folderScrollOffset, 0), maxOffset)
        folderScrollTarget = min(max(folderScrollTarget, 0), maxOffset)
        let firstRow = max(0, Int(floor(folderScrollOffset)) - 1)
        let lastRow = min(
            max(0, Int(ceil(folderScrollOffset)) + folderRows),
            Int(ceil(Double(max(children.count, 1)) / Double(folderColumns))) - 1
        )

        for index in children.indices {
            let globalRow = index / folderColumns
            guard globalRow >= firstRow, globalRow <= lastRow else { continue }
            let app = children[index]
            guard let texture = iconTextures.texture(for: app) else { continue }
            let column = index % folderColumns
            let cellCenter = CGPoint(
                x: rect.minX + 24 + cellWidth * (CGFloat(column) + 0.5),
                y: contentTop + cellHeight * (CGFloat(globalRow) - folderScrollOffset + 0.42)
            )
            iconDrawTextures.append(texture)
            iconSprites.append(
                .icon(
                    center: cellCenter,
                    size: iconSize,
                    uv: SIMD4(0, 0, 1, 1),
                    alpha: alpha,
                    pressed: false
                )
            )
            if let label = textAtlas.layouts[app.id], labelsBySheet.indices.contains(label.sheet) {
                labelsBySheet[label.sheet].append(
                    .label(
                        center: CGPoint(
                            x: cellCenter.x,
                            y: cellCenter.y + iconSize * 0.5 + 10
                        ),
                        size: CGSize(width: label.widthPoints, height: label.heightPoints),
                        uv: label.uv,
                        alpha: alpha * 0.9
                    )
                )
            }
        }
    }

    private func openFolder(_ folderID: String) {
        guard store.folder(withID: folderID) != nil else { return }
        openFolderID = folderID
        folderScrollOffset = 0
        folderScrollTarget = 0
        startDisplayLink()
        needsDisplay = true
    }

    private func closeFolder() {
        openFolderID = nil
        folderScrollOffset = 0
        folderScrollTarget = 0
        needsDisplay = true
    }

    private func folderChildApp(at point: CGPoint) -> AppInfo? {
        guard let openFolderID,
              let folder = store.folder(withID: openFolderID),
              folderWindowRect.contains(point) else {
            return nil
        }

        let rect = folderWindowRect
        let metrics = folderCellMetrics
        let contentTop = rect.minY + 72
        let cellWidth = metrics.cellWidth
        let cellHeight = metrics.cellHeight
        let localX = point.x - rect.minX - 24
        let localY = point.y - contentTop + folderScrollOffset * cellHeight
        guard localX >= 0, localY >= 0,
              localX < cellWidth * CGFloat(folderColumns),
              localY < cellHeight * CGFloat(max(folderRows, Int(ceil(Double(max(folder.appIDs.count, 1)) / Double(folderColumns))))) else {
            return nil
        }

        let column = min(folderColumns - 1, Int(localX / cellWidth))
        let row = max(0, Int(localY / cellHeight))
        let index = row * folderColumns + column
        guard folder.appIDs.indices.contains(index) else { return nil }
        return store.app(withID: folder.appIDs[index])
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    private var windowScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        // Text atlas validity already includes backing scale in its signature.
        // Bounds-only layouts must not trigger a full atlas rebuild mid-animation.
        needsDisplay = true
    }

    // MARK: - Input

    private var interactionPageOffset: Double {
        searchPhase == .fadingOut ? frozenPageOffset : currentPageOffset
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        draggedAppID = nil
        dragPoint = CGPoint(x: dragStart.x, y: bounds.height - dragStart.y)
        dragGrabOffset = .zero
        edgePageDirection = 0
        dragHoverTargetID = nil
        folderPressedAppID = nil
        didDrag = false
        dragDestination = nil
        isPanningPage = false
        panLastPoint = dragStart

        if searchPhase != .idle {
            isPanningPage = true
            store.beginPagePan()
            startDisplayLink()
            needsDisplay = true
            return
        }

        let topPoint = CGPoint(x: dragStart.x, y: bounds.height - dragStart.y)
        if openFolderID != nil {
            if folderWindowRect.contains(topPoint) {
                folderPressedAppID = folderChildApp(at: topPoint)?.id
                if let folderPressedAppID {
                    store.focusApp(id: folderPressedAppID)
                }
                needsDisplay = true
            } else {
                closeFolder()
            }
            return
        }

        let metrics = GridMetrics(size: bounds.size)
        if let hit = metrics.hitTest(point: dragStart, pageOffset: interactionPageOffset) {
            let index = hit.page * store.pageCapacity + hit.localIndex
            if displayedItems.indices.contains(index) {
                let item = displayedItems[index]
                if case .app(let app) = item {
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
                startDisplayLink()
                needsDisplay = true
                return
            }
        }

        isPanningPage = true
        store.beginPagePan()
        startDisplayLink()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard searchPhase == .idle, openFolderID == nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let metrics = GridMetrics(size: bounds.size)
        guard let hit = metrics.hitTest(point: point, pageOffset: interactionPageOffset) else {
            return nil
        }
        let index = hit.page * store.pageCapacity + hit.localIndex
        guard displayedItems.indices.contains(index),
              case .app(let app) = displayedItems[index] else { return nil }

        contextMenuApp = app
        store.focusApp(id: app.id)
        needsDisplay = true

        let menu = NSMenu(title: app.name)
        menu.addItem(withTitle: "打开", action: #selector(openContextMenuApp), keyEquivalent: "")
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealContextMenuApp), keyEquivalent: "")
        menu.addItem(withTitle: "显示简介", action: #selector(showContextMenuAppInfo), keyEquivalent: "")
        menu.addItem(.separator())
        let hideItem = menu.addItem(withTitle: "隐藏", action: #selector(hideContextMenuApp), keyEquivalent: "")
        hideItem.isEnabled = !store.hiddenAppIDs.contains(app.id)
        for item in menu.items where item.action != nil {
            item.target = self
        }
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
            NSWorkspace.shared.open(app.url)
        }
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

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        if hypot(point.x - dragStart.x, point.y - dragStart.y) > 6 { didDrag = true }
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
            folderPressedAppID = nil
            isPanningPage = false
            needsDisplay = true
        }
        if isPanningPage {
            store.endPagePan()
            startDisplayLink()
            // An empty-area click is a dismissal gesture. Once the pointer
            // moves past the drag threshold, the same gesture remains a page
            // pan and must not dismiss the Launchpad on mouse-up.
            if !didDrag {
                NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
            }
            return
        }

        if let folderPressedAppID, !didDrag, let app = store.app(withID: folderPressedAppID) {
            NotificationCenter.default.post(
                name: .qlaunchpadDismiss,
                object: nil,
                userInfo: ["openingAppID": app.id]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSWorkspace.shared.open(app.url)
            }
            return
        }

        if didDrag,
           let draggedAppID,
           let dragHoverTargetID,
           case .app = displayedItems.first(where: { $0.id == draggedAppID }) {
            if let target = displayedItems.first(where: { $0.id == dragHoverTargetID }) {
                switch target {
                case .folder:
                    store.moveAppIntoFolder(appID: draggedAppID, folderID: target.id)
                    displayedItems = store.displayItems
                    lastFilterSignature = AppListSignature(items: displayedItems)
                case .app(let targetApp):
                    if targetApp.id != draggedAppID {
                        if store.createFolder(
                            draggedAppID: draggedAppID,
                            targetAppID: targetApp.id
                        ) != nil {
                            displayedItems = store.displayItems
                            lastFilterSignature = AppListSignature(items: displayedItems)
                        }
                    }
                }
            }
            return
        }

        guard let source = dragSource, displayedItems.indices.contains(source) else { return }
        if !didDrag, searchPhase == .idle {
            let item = displayedItems[source]
            if case .folder(let folder) = item {
                openFolder(folder.id)
                return
            }
            guard case .app(let app) = item else { return }
            NotificationCenter.default.post(
                name: .qlaunchpadDismiss,
                object: nil,
                userInfo: ["openingAppID": app.id]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSWorkspace.shared.open(app.url)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if openFolderID != nil {
            let point = convert(event.locationInWindow, from: nil)
            let topPoint = CGPoint(x: point.x, y: bounds.height - point.y)
            if folderWindowRect.contains(topPoint) {
                if let openFolderID,
                   let folder = store.folder(withID: openFolderID) {
                    let maxOffset = folderMaxScrollOffset(for: folder.appIDs.count)
                    // Trackpad deltas are already in points; mouse-wheel
                    // deltas are smaller and get a modest multiplier.
                    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 0.012 : 0.035
                    folderScrollTarget -= event.scrollingDeltaY * multiplier
                    folderScrollTarget = min(max(folderScrollTarget, 0), maxOffset)
                    startDisplayLink()
                }
                needsDisplay = true
                return
            }
        }
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
