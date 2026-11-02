import Metal
import MetalKit
import AppKit
import simd

struct Globals { var viewport: V2; var time: Float; var pad: Float = 0 }
struct SpriteGPU {
    var center: V2; var half_: V2
    var intake: V2; var angle: Float; var scale: Float
    var alpha: Float; var slice: UInt32; var pull: Float; var agit: Float
    var tint: SIMD4<Float>
    var shadowOffset: V2; var shadowAlpha: Float; var pad: Float = 0
}
struct PartGPU { var pos: V2; var size: Float; var ang: Float; var color: SIMD4<Float>; var chip: Float; var pad0: Float = 0; var pad1: Float = 0; var pad2: Float = 0 }
struct RobotU {
    var center: V2; var radius: Float; var heading: Float
    var lidar: Float; var bumper: Float; var binFill: Float; var ledPulse: Float
    var led: SIMD4<Float>
    var alpha: Float; var shakeX: Float; var shakeY: Float; var lift: Float
}
struct BrushU { var center: V2; var radius: Float; var angle: Float; var speed: Float; var alpha: Float; var sign_: Float; var pad: Float = 0 }
struct ShadowU { var center: V2; var radius: Float; var strength: Float; var offset: V2; var blur: Float; var kind: Float; var halfBox: V2; var angle: Float; var pad: Float = 0 }
struct QuadU { var center: V2; var half_: V2; var angle: Float = 0; var pad0: Float = 0; var pad1: Float = 0; var pad2: Float = 0 }
struct DockU { var center: V2; var radius: Float; var alpha: Float; var bag: Float; var glow: Float; var ledPulse: Float; var pad0: Float = 0; var led: SIMD4<Float> }
struct LidarU { var center: V2; var radius: Float; var angle: Float; var alpha: Float; var pad0: Float = 0; var pad1: Float = 0; var pad2: Float = 0 }
struct StampU { var center: V2; var half_: V2; var angle: Float; var dir: Float; var pad0: Float = 0; var pad1: Float = 0 }

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let sizePts: V2
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    var pBg, pSprite, pShadowSprite, pPart, pRobot, pBrush, pShadow, pDock, pLidar, pStamp, pFade: MTLRenderPipelineState!
    var gridBuf: MTLBuffer!
    var gridCount = 0
    var wall: MTLTexture!
    var track: MTLTexture
    var iconTex: MTLTexture?
    var labelTex: MTLTexture?
    var logoTex: MTLTexture!

    var spriteBufs: [MTLBuffer] = []
    var partBufs: [MTLBuffer] = []
    var frameIdx = 0
    let inflight = DispatchSemaphore(value: 3)
    var fadeAcc: Float = 0
    var lastStamp: V2?

    init(device: MTLDevice, sizePts: V2) throws {
        self.device = device
        self.sizePts = sizePts
        queue = device.makeCommandQueue()!
        let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal")
            ?? URL(fileURLWithPath: "Resources/Shaders.metal")
        let lib = try device.makeLibrary(source: String(contentsOf: url), options: nil)

        func pipe(_ vs: String, _ fs: String, blend: Bool = true, format: MTLPixelFormat = .bgra8Unorm, mask: MTLColorWriteMask = .all) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            let c = d.colorAttachments[0]!
            c.pixelFormat = format
            c.writeMask = mask
            if blend {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pBg = try pipe("bgVS", "bgFS", blend: false)
        pSprite = try pipe("spriteVS", "spriteFS")
        pShadowSprite = try pipe("spriteShadowVS", "spriteShadowFS")
        pPart = try pipe("partVS", "partFS")
        pRobot = try pipe("robotVS", "robotFS")
        pBrush = try pipe("brushVS", "brushFS")
        pShadow = try pipe("shadowVS", "shadowFS")
        pDock = try pipe("dockVS", "dockFS")
        pLidar = try pipe("lidarVS", "lidarFS")
        pStamp = try pipe("stampVS", "stampFS", blend: false, format: .rgba8Unorm, mask: .all)
        do {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fadeVS")
            d.fragmentFunction = lib.makeFunction(name: "fadeFS")
            let c = d.colorAttachments[0]!
            c.pixelFormat = .rgba8Unorm
            c.writeMask = .red
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .reverseSubtract
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
            pFade = try device.makeRenderPipelineState(descriptor: d)
        }

        // 14x14 cell mesh per sprite: fine enough to bend smoothly into the intake.
        let n = 14
        var verts: [V2] = []
        for j in 0..<n { for i in 0..<n {
            let a = V2(Float(i) / Float(n) - 0.5, Float(j) / Float(n) - 0.5)
            let b = a + V2(1 / Float(n), 0), c = a + V2(0, 1 / Float(n)), d = a + V2(1 / Float(n), 1 / Float(n))
            verts += [a, b, c, c, b, d]
        } }
        gridCount = verts.count
        gridBuf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<V2>.stride)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Int(sizePts.x), height: Int(sizePts.y), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        track = device.makeTexture(descriptor: td)!
        for _ in 0..<3 {
            spriteBufs.append(device.makeBuffer(length: MemoryLayout<SpriteGPU>.stride * 4096, options: .storageModeShared)!)
            partBufs.append(device.makeBuffer(length: MemoryLayout<PartGPU>.stride * 2600, options: .storageModeShared)!)
        }
        logoTex = makeLogo()
        clearTrack()
    }

    func clearTrack() {
        let cb = queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = track
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0.5, 0, 0)
        rp.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rp)!.endEncoding()
        cb.commit()
    }

    func makeLogo() -> MTLTexture {
        let w = 512, h = 180
        let ctx = SpriteFactory.context(w: w, h: h, space: CGColorSpaceCreateDeviceRGB())
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = NSAttributedString(string: "robodust", attributes: [.font: NSFont.systemFont(ofSize: 92, weight: .semibold), .foregroundColor: NSColor.white, .kern: 4])
        let sz = s.size()
        s.draw(at: NSPoint(x: (CGFloat(w) - sz.width) / 2, y: (CGFloat(h) - sz.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return texture(from: ctx.makeImage()!, space: CGColorSpaceCreateDeviceRGB())
    }

    func texture(from img: CGImage, space: CGColorSpace) -> MTLTexture {
        let ctx = SpriteFactory.context(w: img.width, h: img.height, space: space)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: img.width, height: img.height, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow)
        return t
    }

    func setWallpaper(_ img: CGImage, space: CGColorSpace) { wall = texture(from: img, space: space) }

    func arrayTexture(_ images: [CGImage], space: CGColorSpace, mipmapped: Bool) -> MTLTexture {
        let w = images[0].width, h = images[0].height
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .bgra8Unorm
        d.width = w; d.height = h
        d.arrayLength = images.count
        d.usage = .shaderRead
        d.storageMode = .shared
        d.mipmapLevelCount = mipmapped ? Int(log2(Double(max(w, h)))) + 1 : 1
        let t = device.makeTexture(descriptor: d)!
        for (i, img) in images.enumerated() {
            let ctx = SpriteFactory.context(w: w, h: h, space: space)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: i, withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow, bytesPerImage: 0)
        }
        if mipmapped, let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        return t
    }

    func setSprites(_ s: [SpriteFactory.Sprite], space: CGColorSpace) {
        iconTex = arrayTexture(s.map(\.icon), space: space, mipmapped: true)
        labelTex = arrayTexture(s.map(\.label), space: space, mipmapped: true)
    }

    // MARK: - Frame

    func encode(sim: Sim, target: MTLTexture, cb: MTLCommandBuffer, dt: Float) {
        stampTrack(sim: sim, cb: cb, dt: dt)
        frameIdx = (frameIdx + 1) % 3
        var g = Globals(viewport: sizePts, time: sim.t)

        // Assemble sprite instances: labels first, then icons, things being eaten on top.
        var ground: [SpriteGPU] = []
        var groundLabels: [SpriteGPU] = []
        var top: [SpriteGPU] = []
        var topLabels: [SpriteGPU] = []
        ground.reserveCapacity(sim.items.count)
        let intake = sim.intake
        let iconHalf = V2(32, 32), labelHalf = V2(62, 17)
        var late: [SpriteGPU] = []
        // Funnels in up close. From far away it shrinks and zips over, or it would smear across the screen.
        let funnelReach = sim.R * 2.2
        func funnel(_ b: Body) -> (pull: Float, scale: Float, near: Bool) {
            guard b.ingesting else { return (0, 1, true) }
            let near = (intake - b.pos).len < funnelReach
            return near ? (b.pull, 1, true) : (0, 1 - b.pull * 0.55, false)
        }
        for it in sim.items {
            let i = UInt32(it.index)
            let flying = it.flight != .none && it.flightDelay <= 0
            if it.flight != .none && it.flightDelay > 0 && it.flight != .toBag {
                // Queued: still resting where it was (tidied) or invisible in the bag.
                if it.inDock { continue }
            }
            if it.inBin || (it.inDock && !flying) { continue }
            let far = intake + V2(0, 100000)

            if !it.icon.gone || flying {
                let a = it.icon.agit
                let wob = flying ? 0 : a * 0.13 * sin(sim.t * (17 + it.icon.seed.truncatingRemainder(dividingBy: 7)) + it.icon.seed)
                let jitter = flying ? V2(0, 0) : V2(sin(sim.t * 33 + it.icon.seed), cos(sim.t * 29 + it.icon.seed * 2)) * (a * a * 1.6)
                let squash = 1 + it.land * 0.12 * sin(it.land * 6)
                let iconFunnel = funnel(it.icon)
                let scale = (flying ? it.flightScale : 1 + a * 0.05) * squash * iconFunnel.scale
                let lift = flying ? sin(it.flightT * .pi) : a
                var tint = SIMD4<Float>(0, 0, 0, 0)
                if it.ping > 0 { tint = SIMD4(0.45, 0.95, 1, it.ping * 0.55) }
                let inst = SpriteGPU(center: it.icon.pos + jitter, half_: iconHalf, intake: flying ? far : intake,
                                     angle: it.icon.ang + wob, scale: scale, alpha: 1, slice: i,
                                     pull: iconFunnel.pull, agit: flying || !iconFunnel.near ? 0 : a, tint: tint,
                                     shadowOffset: V2(2, 3) + V2(5, 9) * lift, shadowAlpha: 0.34 * max(lift, 0))
                if flying && it.flight == .toBag { late.append(inst) }
                else if flying { top.append(inst) }
                else if it.icon.ingesting { top.append(inst) }
                else { ground.append(inst) }
            }
            // Label.
            let labelVisible = !it.label.gone || flying
            if labelVisible && it.flight != .toBag {
                let attached = it.labelAttached
                let lpos: V2 = attached ? it.icon.pos + V2(0, Item.labelOffset * (flying ? it.flightScale : 1)).rotated(it.icon.ang) : it.label.pos
                let lang = attached ? it.icon.ang : it.label.ang
                let labelFunnel = attached ? (pull: Float(0), scale: Float(1), near: true) : funnel(it.label)
                let scale: Float = (attached && flying ? it.flightScale : 1) * labelFunnel.scale
                let a = !labelFunnel.near ? 0 : (attached ? it.icon.agit * 0.6 : it.label.agit)
                var tint = SIMD4<Float>(0, 0, 0, 0)
                if it.ping > 0 { tint = SIMD4(0.55, 0.97, 1, it.ping * 0.7) }
                let inst = SpriteGPU(center: lpos, half_: labelHalf, intake: flying ? far : intake, angle: lang, scale: scale, alpha: 1, slice: i,
                                     pull: labelFunnel.pull, agit: flying ? 0 : a, tint: tint,
                                     shadowOffset: V2(0, 0), shadowAlpha: 0)
                if flying || it.label.ingesting { topLabels.append(inst) } else { groundLabels.append(inst) }
            }
        }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }

        // Wallpaper.
        e.setRenderPipelineState(pBg)
        e.setFragmentTexture(wall, index: 0)
        e.setFragmentTexture(track, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        let buf = spriteBufs[frameIdx]
        var cursor = 0
        func draw(_ list: [SpriteGPU], tex: MTLTexture?, shadows: Bool) {
            guard !list.isEmpty, let tex = tex, cursor + list.count <= 4096 else { return }
            list.withUnsafeBytes { memcpy(buf.contents() + cursor * MemoryLayout<SpriteGPU>.stride, $0.baseAddress!, $0.count) }
            if shadows {
                e.setRenderPipelineState(pShadowSprite)
                e.setVertexBuffer(gridBuf, offset: 0, index: 0)
                e.setVertexBuffer(buf, offset: cursor * MemoryLayout<SpriteGPU>.stride, index: 1)
                e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 2)
                e.setFragmentTexture(tex, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridCount, instanceCount: list.count)
            }
            e.setRenderPipelineState(pSprite)
            e.setVertexBuffer(gridBuf, offset: 0, index: 0)
            e.setVertexBuffer(buf, offset: cursor * MemoryLayout<SpriteGPU>.stride, index: 1)
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 2)
            e.setFragmentTexture(tex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridCount, instanceCount: list.count)
            cursor += list.count
        }

        draw(groundLabels, tex: labelTex, shadows: false)
        // Only lifted icons cast a shadow, so the resting ones match Finder's look exactly.
        let lifted = ground.filter { $0.shadowAlpha > 0.015 }
        let flat = ground.filter { $0.shadowAlpha <= 0.015 }
        draw(flat, tex: iconTex, shadows: false)
        draw(lifted, tex: iconTex, shadows: true)
        draw(topLabels, tex: labelTex, shadows: false)
        draw(top, tex: iconTex, shadows: true)

        // Lidar sweep sits on the floor, under the robot.
        if sim.scanActive > 0.01 {
            var u = LidarU(center: sim.pos, radius: max(sizePts.x, sizePts.y) * 0.85, angle: -.pi / 2 + sim.scanSweep, alpha: sim.scanActive)
            e.setRenderPipelineState(pLidar)
            e.setVertexBytes(&u, length: MemoryLayout<LidarU>.stride, index: 0)
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<LidarU>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        drawDock(sim, e, &g)
        drawParticles(sim, e, &g)
        drawRobot(sim, e, &g)
        draw(late, tex: iconTex, shadows: false)
        e.endEncoding()
    }

    func drawDock(_ sim: Sim, _ e: MTLRenderCommandEncoder, _ g: inout Globals) {
        let drop = sim.dockDrop
        let bounce = 1 - pow(1 - drop, 3)
        let scale = 1 + (1 - bounce) * 0.55
        let alpha = sim.dockAlpha * smooth(0, 0.35, drop)
        let shakeK = sim.phase == .dropping ? sim.shake : 0
        let shakeOff = V2(sin(sim.t * 70), cos(sim.t * 61)) * shakeK * 3
        let center = sim.dockPos + shakeOff
        let R = sim.R * scale
        let towerC = center + V2(0, R * 1.04)
        let height = (1 - bounce)
        var s1 = ShadowU(center: towerC, radius: R * 0.3, strength: 0.44 * alpha * (1 - height * 0.6),
                         offset: V2(5, 8) + V2(40, 70) * height, blur: 20 + height * 40, kind: 1,
                         halfBox: V2(R * 1.3, R * 1.02), angle: 0)
        e.setRenderPipelineState(pShadow)
        e.setVertexBytes(&s1, length: MemoryLayout<ShadowU>.stride, index: 0)
        e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        e.setFragmentBytes(&s1, length: MemoryLayout<ShadowU>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        var q = QuadU(center: center + V2(0, R * 0.7), half_: V2(R * 1.32, R * 1.42))
        // The fragment wants coordinates relative to the docked robot centre.
        q.center = center
        q.half_ = V2(R * 1.36, R * 2.14)
        var u = DockU(center: center, radius: R, alpha: alpha, bag: sim.bagFill, glow: sim.bagGlow, ledPulse: sim.ledPulse,
                      led: SIMD4(sim.led.x, sim.led.y, sim.led.z, 1))
        e.setRenderPipelineState(pDock)
        e.setVertexBytes(&q, length: MemoryLayout<QuadU>.stride, index: 0)
        e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        e.setFragmentBytes(&u, length: MemoryLayout<DockU>.stride, index: 0)
        e.setFragmentTexture(logoTex, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func drawParticles(_ sim: Sim, _ e: MTLRenderCommandEncoder, _ g: inout Globals) {
        guard !sim.particles.isEmpty else { return }
        let buf = partBufs[frameIdx]
        let p = buf.contents().bindMemory(to: PartGPU.self, capacity: 2600)
        var n = 0
        for q in sim.particles where n < 2600 {
            let k = clampf(q.life / q.maxLife, 0, 1)
            var c = q.color; c.w *= q.chip > 0.5 ? smooth(0, 0.3, k) : sin(k * .pi)
            p[n] = PartGPU(pos: q.pos, size: q.size, ang: q.ang, color: c, chip: q.chip); n += 1
        }
        e.setRenderPipelineState(pPart)
        e.setVertexBuffer(buf, offset: 0, index: 0)
        e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
    }

    func drawRobot(_ sim: Sim, _ e: MTLRenderCommandEncoder, _ g: inout Globals) {
        let drop = sim.dockDrop
        let bounce = 1 - pow(1 - drop, 3)
        let dropScale = 1 + (1 - bounce) * 0.55
        let liftK = sim.lift
        let scale = dropScale * (1 + liftK * 0.13)
        let R = sim.R * scale
        let alpha = sim.robotAlpha * smooth(0, 0.35, drop)
        let height = (1 - bounce) + liftK * 0.9
        var shakeP = V2(sin(sim.t * 83), cos(sim.t * 71)) * sim.shake * 2.6
        if sim.picked { shakeP = V2(sin(sim.t * 19), cos(sim.t * 15)) * 1.2 }
        let pos = sim.pos
        // Two-part shadow: a tight contact core and a wide soft one.
        for (offset, blur, strength) in [(V2(2, 3) + V2(26, 44) * height, Float(7) + 18 * height, Float(0.40) * (1 - height * 0.5)),
                                         (V2(10, 16) + V2(34, 58) * height, Float(26) + 34 * height, Float(0.30) * (1 - height * 0.5))] {
            var s = ShadowU(center: pos, radius: R * 0.985, strength: strength * alpha, offset: offset, blur: blur, kind: 0, halfBox: V2(0, 0), angle: 0)
            e.setRenderPipelineState(pShadow)
            e.setVertexBytes(&s, length: MemoryLayout<ShadowU>.stride, index: 0)
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            e.setFragmentBytes(&s, length: MemoryLayout<ShadowU>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        // Side brushes reach out from under the shell.
        let (l, r) = sim.brushCenters
        for (c, sign) in [(l, Float(1)), (r, Float(-1))] {
            var b = BrushU(center: pos + (c - pos) * scale + shakeP, radius: R * 0.56, angle: sim.brushAngle, speed: sim.brushSpeed, alpha: alpha, sign_: sign)
            e.setRenderPipelineState(pBrush)
            e.setVertexBytes(&b, length: MemoryLayout<BrushU>.stride, index: 0)
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            e.setFragmentBytes(&b, length: MemoryLayout<BrushU>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        var u = RobotU(center: pos, radius: R, heading: sim.heading, lidar: sim.lidarAngle, bumper: sim.bumper,
                       binFill: Float(sim.binCount) / Float(max(sim.binCapacity, 1)), ledPulse: sim.ledPulse,
                       led: SIMD4(sim.led.x, sim.led.y, sim.led.z, 1), alpha: alpha, shakeX: shakeP.x, shakeY: shakeP.y, lift: liftK)
        e.setRenderPipelineState(pRobot)
        e.setVertexBytes(&u, length: MemoryLayout<RobotU>.stride, index: 0)
        e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        e.setFragmentBytes(&u, length: MemoryLayout<RobotU>.stride, index: 0)
        e.setFragmentTexture(logoTex, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// For artwork exports: just the robot's shell, or just the dock, on a chosen clear colour.
    func renderPart(robot: Bool, sim: Sim, target: MTLTexture, clear: MTLClearColor) {
        let cb = queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = clear
        rp.colorAttachments[0].storeAction = .store
        let e = cb.makeRenderCommandEncoder(descriptor: rp)!
        var g = Globals(viewport: sizePts, time: 0)
        if robot {
            var u = RobotU(center: sim.pos, radius: sim.R, heading: sim.heading, lidar: 0.8, bumper: 0, binFill: 0, ledPulse: 0.5,
                           led: SIMD4(sim.led.x, sim.led.y, sim.led.z, 1), alpha: 1, shakeX: 0, shakeY: 0, lift: 0)
            e.setRenderPipelineState(pRobot)
            e.setVertexBytes(&u, length: MemoryLayout<RobotU>.stride, index: 0)
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<RobotU>.stride, index: 0)
            e.setFragmentTexture(logoTex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        } else {
            drawDock(sim, e, &g)
        }
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    func stampTrack(sim: Sim, cb: MTLCommandBuffer, dt: Float) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = track
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var g = Globals(viewport: sizePts, time: sim.t)
        // Very slow fade of the nap, so a run stays visible and then relaxes.
        fadeAcc += dt
        if fadeAcc > 0.28 {
            fadeAcc = 0
            var amt: Float = 1 / 255
            e.setRenderPipelineState(pFade)
            e.setFragmentBytes(&amt, length: 4, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        if sim.suctionOn && abs(sim.v) > 8 && !sim.picked {
            // Pattern follows travel direction so opposite passes read as lighter and darker lanes.
            let dirv = sim.fwd
            let dir = 0.5 + 0.5 * (abs(dirv.x) > abs(dirv.y) ? (dirv.x > 0 ? 1 : -1) : (dirv.y > 0 ? 0.5 : -0.5)) as Float
            let from = lastStamp ?? sim.pos
            let segLen = (sim.pos - from).len
            var u = StampU(center: (from + sim.pos) * 0.5 - sim.fwd * (sim.R * 0.2), half_: V2(segLen * 0.5 + 8, sim.R * 0.86), angle: sim.heading, dir: dir)
            e.setRenderPipelineState(pStamp)
            e.setVertexBytes(&u, length: MemoryLayout<StampU>.stride, index: 0)
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        lastStamp = sim.pos
        e.endEncoding()
    }
}
