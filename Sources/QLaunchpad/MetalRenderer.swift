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
}

private struct FrameUniforms {
    var viewport: SIMD2<Float>
    var _pad: SIMD2<Float> = .zero
}

private struct TextBatch {
    let sheet: Int
    let range: Range<Int>
}

/// All GPU-visible memory for one submitted frame is immutable. In particular,
/// icon draw calls must not repeatedly overwrite one shared `MTLBuffer`: Metal
/// executes those calls later, after the CPU has finished encoding the frame.
private struct RenderFrame {
    let iconBuffer: MTLBuffer?
    let iconDraws: [(texture: MTLTexture, index: Int)]
    let textBuffer: MTLBuffer?
    let textBatches: [TextBatch]
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
    private var lastCatalogSignature = ""
    private var lastTextSignature = ""
    private var lastFrameTime = CACurrentMediaTime()
    private var resourcePrewarmSignature = ""
    private var resourcePrewarmTask: Task<Void, Never>?
    private var isResourcePrewarmingPaused = false
    private var firstFrameWaiters: [() -> Void] = []
    private var isFirstFrameCompletionScheduled = false

    private var dragSource: Int?
    private var dragDestination: Int?
    private var dragStart: CGPoint = .zero
    private var didDrag = false
    private var isPanningPage = false
    private var panLastPoint: CGPoint = .zero
    private var contextMenuApp: AppInfo?

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
    private var presentStartTime: CFTimeInterval = 0
    private var presentFrom: CGFloat = 0
    private var presentTo: CGFloat = 1
    private var presentDurationActive: CFTimeInterval = 1.3

    // Search: sequential fade-out → swap → fade-in (single grid only).
    private var displayedApps: [AppInfo] = []
    private var pendingFilterApps: [AppInfo]?
    private var lastFilterSignature = ""
    private enum SearchPhase { case idle, fadingOut, fadingIn }
    private var searchPhase: SearchPhase = .idle
    private var searchPhaseStart: CFTimeInterval = 0
    private var searchGridAlpha: Float = 1
    private var frozenPageOffset: Double = 0
    private let searchHalfDuration: CFTimeInterval = 0.15

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
        o.kind = s.kindAlpha.x;
        o.alpha = s.kindAlpha.y;
        return o;
    }

    fragment float4 ql_icon_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler samp [[sampler(0)]])
    {
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
        if pageSettled && !animatingPresentation && searchPhase == .idle {
            displayLink?.invalidate()
            displayLink = nil
            if abs(store.pageOffset - currentPageOffset) > 0.0001 {
                store.pageOffset = currentPageOffset
            }
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        needsDisplay = true
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
        lastCatalogSignature = ""
        lastTextSignature = ""
        resourcePrewarmSignature = ""
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
        let signature = catalog.map(\.id).joined(separator: "|")
        guard signature != resourcePrewarmSignature else { return }
        resourcePrewarmSignature = signature

        resourcePrewarmTask?.cancel()
        iconTextures.rebuild(with: catalog)
        lastCatalogSignature = signature

        if displayedApps.isEmpty {
            displayedApps = visibleApps
            lastFilterSignature = visibleApps.map(\.id).joined(separator: "|")
            searchPhase = .idle
            searchGridAlpha = 1
        }

        let firstPageEnd = min(store.pageCapacity, visibleApps.count)
        let firstPage = Array(visibleApps[..<firstPageEnd])
        let firstPageIDs = Set(firstPage.map(\.id))
        let remaining = catalog.filter { !firstPageIDs.contains($0.id) }
        let textureStore = iconTextures
        let scale = windowScale
        let textSignature = visibleApps.map(\.id).joined(separator: "|") + "|s\(scale)"

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
        catalogSignature: String,
        textSignature: String,
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

    private func finishResourcePrewarming(catalogSignature: String) {
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
        resourcePrewarmSignature = ""
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

    private func smoothstep(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    private func noteFilterChangeIfNeeded() {
        let signature = store.filteredApps.map(\.id).joined(separator: "|")
        guard signature != lastFilterSignature else { return }
        lastFilterSignature = signature
        let target = store.filteredApps

        if displayedApps.isEmpty {
            displayedApps = target
            pendingFilterApps = nil
            searchPhase = .idle
            searchGridAlpha = 1
            return
        }
        if displayedApps.map(\.id) == target.map(\.id) {
            pendingFilterApps = nil
            return
        }

        pendingFilterApps = target
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
                displayedApps = pendingFilterApps ?? store.filteredApps
                pendingFilterApps = nil
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
                let latest = store.filteredApps.map(\.id).joined(separator: "|")
                let shown = displayedApps.map(\.id).joined(separator: "|")
                if latest != shown {
                    lastFilterSignature = ""
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
        let catalogSignature = store.apps.map(\.id).joined(separator: "|")
        if catalogSignature != lastCatalogSignature {
            iconTextures.rebuild(with: store.apps)
            lastCatalogSignature = catalogSignature
        }
        // If apps just arrived, populate the grid immediately (no empty first open).
        if displayedApps.isEmpty, !store.filteredApps.isEmpty {
            displayedApps = store.filteredApps
            lastFilterSignature = store.filteredApps.map(\.id).joined(separator: "|")
            searchPhase = .idle
            searchGridAlpha = 1
            lastTextSignature = ""
        }

        noteFilterChangeIfNeeded()

        // Text atlas only for currently displayed apps (fast). Full-catalog rebuild
        // was freezing the first frame so nothing appeared for seconds.
        let scale = windowScale
        let textSig = displayedApps.map(\.id).joined(separator: "|") + "|s\(scale)"
        if textSig != lastTextSignature, !displayedApps.isEmpty {
            textAtlas.rebuild(with: displayedApps, scale: scale)
            lastTextSignature = textSig
        }

        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 1.0 / 240.0), 1.0 / 30.0)
        lastFrameTime = now
        tickSearchTransition(now: now)

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

        let metrics = GridMetrics(size: bounds.size)
        let midX = bounds.midX
        let midY = bounds.height * 0.5
        let pageOffset = searchPhase == .fadingOut ? frozenPageOffset : currentPageOffset

        // App icons use independent textures. We still store every sprite once in
        // a frame-local buffer and select it by offset for each texture draw.
        var iconDrawList: [(texture: MTLTexture, sprite: SpriteInstance)] = []
        var labelsBySheet: [Int: [SpriteInstance]] = [:]

        buildGrid(
            apps: displayedApps,
            pageOffset: pageOffset,
            alphaScale: gridAlpha,
            metrics: metrics,
            midX: midX,
            midY: midY,
            iconDrawList: &iconDrawList,
            labelsBySheet: &labelsBySheet
        )

        let frame = makeRenderFrame(
            iconItems: iconDrawList,
            labelsBySheet: labelsBySheet
        )

        guard let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
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
        if let iconBuffer = frame.iconBuffer {
            for draw in frame.iconDraws {
                encoder.setVertexBuffer(
                    iconBuffer,
                    offset: draw.index * MemoryLayout<SpriteInstance>.stride,
                    index: 0
                )
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: 1
                )
            }
        }

        // Labels remain atlas-batched, but also live in immutable frame storage.
        if let textBuffer = frame.textBuffer {
            encoder.setRenderPipelineState(textPipeline)
            encoder.setFragmentSamplerState(textSampler, index: 0)
            for batch in frame.textBatches {
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

    private func makeRenderFrame(
        iconItems: [(texture: MTLTexture, sprite: SpriteInstance)],
        labelsBySheet: [Int: [SpriteInstance]]
    ) -> RenderFrame {
        let iconSprites = iconItems.map(\.sprite)
        let iconBuffer = makeImmutableBuffer(iconSprites)
        let iconDraws = iconItems.enumerated().map { index, item in
            (texture: item.texture, index: index)
        }

        var textSprites: [SpriteInstance] = []
        var textBatches: [TextBatch] = []
        for sheet in labelsBySheet.keys.sorted() {
            guard let sprites = labelsBySheet[sheet], !sprites.isEmpty else { continue }
            let start = textSprites.count
            textSprites.append(contentsOf: sprites)
            textBatches.append(TextBatch(sheet: sheet, range: start..<textSprites.count))
        }

        return RenderFrame(
            iconBuffer: iconBuffer,
            iconDraws: iconDraws,
            textBuffer: makeImmutableBuffer(textSprites),
            textBatches: textBatches
        )
    }

    private func makeImmutableBuffer(_ instances: [SpriteInstance]) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        return instances.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device?.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
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

    private func buildGrid(
        apps: [AppInfo],
        pageOffset: Double,
        alphaScale: Float,
        metrics: GridMetrics,
        midX: CGFloat,
        midY: CGFloat,
        iconDrawList: inout [(texture: MTLTexture, sprite: SpriteInstance)],
        labelsBySheet: inout [Int: [SpriteInstance]]
    ) {
        guard !apps.isEmpty, alphaScale > 0.001 else { return }
        let cap = store.pageCapacity
        let pages = max(1, Int(ceil(Double(apps.count) / Double(cap))))
        let center = Int(pageOffset.rounded())
        // Avoid lazy-loading adjacent pages while the entrance animation is live.
        // The background prewarmer resumes as soon as presentation completes.
        let entranceActive = iconEntranceProgress < 0.999
        let first = entranceActive ? center : max(0, center - 1)
        let last = entranceActive ? center : min(pages - 1, center + 1)
        let showLabels = UserDefaults.standard.object(forKey: "showLabels") as? Bool ?? true
        // Full-image UV for per-icon textures.
        let fullUV = SIMD4<Float>(0, 0, 1, 1)

        for page in first...last {
            let start = page * cap
            let end = min(start + cap, apps.count)
            guard start < end else { continue }
            for index in start..<end {
                let local = index - start
                let app = apps[index]
                let isOpeningAppTarget = !isShowingPresentation
                    && stationaryDismissedAppID == app.id
                var c = metrics.iconCenter(localIndex: local, page: page, pageOffset: pageOffset)
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
                let pressed = searchPhase == .idle
                    && (dragSource == index || isOpeningAppTarget)
                let itemScale = contentScale * entrance.scale * zoom.iconScale
                let iconSize = metrics.iconSize * itemScale

                if let texture = primedTexture ?? iconTextures.texture(for: app) {
                    if searchPhase == .idle,
                       store.isKeyboardNavigationActive,
                       store.keyboardFocusID == app.id {
                        // Insert at the front so the focus plate is encoded before
                        // every icon and can never cover a neighbouring sprite.
                        iconDrawList.insert((
                            texture,
                            .focus(center: c, size: iconSize * 1.06, alpha: alpha)
                        ), at: 0)
                    }
                    iconDrawList.append((
                        texture,
                        .icon(center: c, size: iconSize, uv: fullUV, alpha: alpha, pressed: pressed)
                    ))
                }

                if showLabels, let label = textAtlas.layouts[app.id] {
                    let lc = CGPoint(
                        x: c.x,
                        y: c.y + iconSize * 0.5 + 6 + label.heightPoints * 0.5 * itemScale
                    )
                    labelsBySheet[label.sheet, default: []].append(
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

        let metrics = GridMetrics(size: bounds.size)
        if let hit = metrics.hitTest(point: dragStart, pageOffset: interactionPageOffset) {
            let index = hit.page * store.pageCapacity + hit.localIndex
            if displayedApps.indices.contains(index) {
                store.focusApp(id: displayedApps[index].id)
                dragSource = index
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
        guard searchPhase == .idle else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let metrics = GridMetrics(size: bounds.size)
        guard let hit = metrics.hitTest(point: point, pageOffset: interactionPageOffset) else {
            return nil
        }
        let index = hit.page * store.pageCapacity + hit.localIndex
        guard displayedApps.indices.contains(index) else { return nil }

        let app = displayedApps[index]
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
        if hypot(point.x - dragStart.x, point.y - dragStart.y) > 6 { didDrag = true }

        if isPanningPage {
            let dx = point.x - panLastPoint.x
            panLastPoint = point
            store.updatePagePan(deltaPages: Double(-dx) / Double(max(bounds.width, 1)))
            startDisplayLink()
            needsDisplay = true
            return
        }

        guard let source = dragSource else { return }
        guard didDrag, !store.isSearching, searchPhase == .idle else {
            needsDisplay = true
            return
        }
        let metrics = GridMetrics(size: bounds.size)
        if let hit = metrics.hitTest(point: point, pageOffset: interactionPageOffset) {
            let destination = hit.page * store.pageCapacity + hit.localIndex
            if store.apps.indices.contains(destination), destination != source {
                store.moveApp(from: source, to: destination)
                displayedApps = store.filteredApps
                lastFilterSignature = displayedApps.map(\.id).joined(separator: "|")
                dragSource = destination
                dragDestination = destination
                needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragSource = nil
            dragDestination = nil
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
        guard let source = dragSource, displayedApps.indices.contains(source) else { return }
        if !didDrag, searchPhase == .idle {
            let app = displayedApps[source]
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
