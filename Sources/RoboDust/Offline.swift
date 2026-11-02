import AppKit
import AVFoundation
import Metal
import CoreVideo

/// Renders a run without any window: same sim and shaders, fixed timestep. Sample items only,
/// so nothing from the real desktop can end up in a frame or a video.
enum Offline {
    struct Options {
        var dumpTimes: [Float] = []
        var dumpDir = "."
        var videoPath: String?
        var maxSeconds: Float = 240
        var mode = CleanMode.trash
        var skip = false
        var choose: CleanMode?
        var count = 0
        var crop: CGRect?
        var pixelScale: Float = 1
        var follow: Int = 0
        var farPullAt: Float?
        var plainFloor = false
    }

    static func makeSim(_ o: Options, size: V2, r: Renderer, space: CGColorSpace, audio: SimAudio?) -> Sim {
        var entries = DesktopReader.sample(screen: CGSize(width: CGFloat(size.x), height: CGFloat(size.y)))
        if o.count > entries.count {
            // Stress case: spread copies across the whole screen, like a very full desktop.
            var rng = SeededRNG(seed: 5)
            let base = entries
            while entries.count < o.count {
                var e = base[Int.random(in: 0..<base.count, using: &rng)]
                e.center = V2(Float.random(in: 60...(size.x - 60), using: &rng), Float.random(in: 70...(size.y - 170), using: &rng))
                entries.append(e)
            }
        }
        let sem = DispatchSemaphore(value: 0)
        var sprites: [SpriteFactory.Sprite] = []
        SpriteFactory.build(entries, space: space, progress: { _ in }) { sprites = $0; sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        r.setSprites(sprites, space: space)
        let s = Sim(size: size, visibleMin: V2(0, 38), visibleMax: V2(size.x, size.y - 64), entries: entries)
        for (i, sp) in sprites.enumerated() { s.items[i].color = sp.average }
        s.mode = o.mode
        s.skipFinalClick = o.skip
        s.audio = audio
        return s
    }

    static func run(_ options: Options) throws {
        var o = options
        let device = MTLCreateSystemDefaultDevice()!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let screen = NSScreen.screens.first!
        let size = V2(Float(screen.frame.width), Float(screen.frame.height))
        let r = try Renderer(device: device, sizePts: size)
        r.setWallpaper((o.plainFloor ? nil : Wallpaper.capture(screen: screen)) ?? Wallpaper.fallback(size: screen.frame.size), space: space)
        let synth = Synth()
        let s = makeSim(o, size: size, r: r, space: space, audio: synth)

        let W = Int(size.x * o.pixelScale), H = Int(size.y * o.pixelScale)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let tex = device.makeTexture(descriptor: td)!

        var writer: AVAssetWriter?, vIn: AVAssetWriterInput?, aIn: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if let path = o.videoPath {
            try? FileManager.default.removeItem(atPath: path)
            let w = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 11_000_000],
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            ])
            vi.expectsMediaDataInRealTime = false
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
            ai.expectsMediaDataInRealTime = false
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
            w.add(vi); w.add(ai)
            w.startWriting(); w.startSession(atSourceTime: .zero)
            writer = w; vIn = vi; aIn = ai; adaptor = ad
        }

        // Fixed 120 Hz physics, 60 Hz frames.
        let fps = 60
        var frame = 0
        var nextDump = o.dumpTimes.sorted()
        var lastPhase = s.phase
        var doneAt: Float? = nil
        var sampleCursor: Int64 = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        var fmtDesc: CMAudioFormatDescription?
        var pendingV: [(CVPixelBuffer, CMTime)] = []
        var pendingA: [CMSampleBuffer] = []
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtDesc)

        while s.t < o.maxSeconds {
            s.step(1 / 120); s.step(1 / 120)
            // Test case: a label and an icon get pulled in from the far side of the screen.
            if let at = o.farPullAt, s.t >= at {
                let far = s.items.filter(\.onFloor).sorted { ($0.icon.pos - s.pos).len > ($1.icon.pos - s.pos).len }
                if far.count > 1 {
                    s.detachLabel(far[0]); s.startIngest(far[0], body: \.label)
                    s.startIngest(far[1], body: \.icon)
                    print("far pull from", Int((far[0].label.pos - s.pos).len), "and", Int((far[1].icon.pos - s.pos).len), "points")
                }
                o.farPullAt = nil
            }
            if s.phase != lastPhase {
                print(String(format: "%6.1fs  %@  left=%d bin=%d collected=%d", s.t, "\(s.phase)", s.remaining, s.binCount, s.collected))
                lastPhase = s.phase
            }
            if s.phase == .done || s.phase == .tidied {
                if doneAt == nil { doneAt = s.t }
                if let c = o.choose, s.t - doneAt! > 0.5, s.discarded == nil { s.discard(c); print("chose", c, "bag", s.bagFill) }
                if s.t - doneAt! > 2.6 { print("before putback: discarded", s.discarded.map { "\($0)" } ?? "none", "bag", s.bagFill, "draining", s.draining); s.putBack() }
            }
            let cb = r.queue.makeCommandBuffer()!
            r.encode(sim: s, target: tex, cb: cb, dt: 1 / 60)
            cb.commit()
            let wantDump = nextDump.first.map { s.t >= $0 } ?? false
            if wantDump || writer != nil { cb.waitUntilCompleted() }
            if wantDump {
                let t = nextDump.removeFirst()
                var crop = o.crop
                if o.follow > 0 {
                    let c = (s.pos + s.fwd * 60) * o.pixelScale
                    let f = Float(o.follow)
                    crop = CGRect(x: CGFloat(clampf(c.x - f / 2, 0, Float(W) - f)), y: CGFloat(clampf(c.y - f * 0.36, 0, Float(H) - f * 0.72)), width: CGFloat(f), height: CGFloat(f * 0.72))
                }
                try savePNG(tex, to: "\(o.dumpDir)/f_\(String(format: "%06.2f", t)).png", space: space, crop: crop)
            }
            if let ad = adaptor, let vi = vIn, let ai = aIn, let pool = ad.pixelBufferPool {
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                if let pb {
                    CVPixelBufferLockBaseAddress(pb, [])
                    tex.getBytes(CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    pendingV.append((pb, CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
                }
                let n = 800
                var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
                synth.render(n, &L, &R)
                var inter = [Float](repeating: 0, count: n * 2)
                for i in 0..<n { inter[i * 2] = L[i]; inter[i * 2 + 1] = R[i] }
                var bb: CMBlockBuffer?
                let bytes = n * 8
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
                inter.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes) }
                var sb: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fmtDesc!, sampleCount: n, presentationTimeStamp: CMTime(value: sampleCursor, timescale: 48000), packetDescriptions: nil, sampleBufferOut: &sb)
                sampleCursor += Int64(n)
                if let sb { pendingA.append(sb) }
                // The writer interleaves, so either track can be the one holding the other up.
                func drain() {
                    while let v = pendingV.first, vi.isReadyForMoreMediaData { ad.append(v.0, withPresentationTime: v.1); pendingV.removeFirst() }
                    while let a = pendingA.first, ai.isReadyForMoreMediaData { ai.append(a); pendingA.removeFirst() }
                }
                drain()
                while pendingV.count > 30 { Thread.sleep(forTimeInterval: 0.002); drain() }
            }
            frame += 1
            if s.phase == .finished { break }
            if o.videoPath == nil && o.dumpTimes.isEmpty == false && nextDump.isEmpty { break }
        }
        print(String(format: "end t=%.1fs phase=%@ collected=%d/%d wall=%.1fs", s.t, "\(s.phase)", s.collected, s.items.count, CFAbsoluteTimeGetCurrent() - t0))
        if let w = writer {
            while !pendingV.isEmpty || !pendingA.isEmpty {
                while let v = pendingV.first, vIn!.isReadyForMoreMediaData { adaptor!.append(v.0, withPresentationTime: v.1); pendingV.removeFirst() }
                while let a = pendingA.first, aIn!.isReadyForMoreMediaData { aIn!.append(a); pendingA.removeFirst() }
                Thread.sleep(forTimeInterval: 0.002)
            }
            vIn?.markAsFinished(); aIn?.markAsFinished()
            let sem = DispatchSemaphore(value: 0)
            w.finishWriting { sem.signal() }
            sem.wait()
            print("video", w.status.rawValue, w.error?.localizedDescription ?? "ok")
        }
    }

    /// Website artwork from the real shaders: a sprite sheet of the robot at every heading, so the
    /// light stays put as it turns, plus the dock with an empty and a full bag.
    static func exportArt(to dir: String) throws {
        let device = MTLCreateSystemDefaultDevice()!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let cell = 300, cols = 8, frames = 64
        let robotView = V2(200, 200)
        let r = try Renderer(device: device, sizePts: robotView)
        let s = Sim(size: robotView, visibleMin: V2(0, 0), visibleMax: robotView, entries: [])
        s.pos = robotView / 2; s.dockDrop = 1
        // 300 px for the robot's 184 pt diameter.
        let px = Int((robotView.x * 300 / 184).rounded())
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: px, height: px, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let tex = device.makeTexture(descriptor: td)!
        let sheet = SpriteFactory.context(w: cell * cols, h: cell * (frames / cols), space: space)
        sheet.setFillColor(CGColor(gray: 0.55, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: cell * cols, height: cell * frames / cols))
        for f in 0..<frames {
            s.heading = Float(f) / Float(frames) * 2 * .pi
            r.renderPart(robot: true, sim: s, target: tex, clear: MTLClearColorMake(0.55, 0.55, 0.55, 1))
            let ctx = SpriteFactory.context(w: px, h: px, space: space)
            tex.getBytes(ctx.data!, bytesPerRow: ctx.bytesPerRow, from: MTLRegionMake2D(0, 0, px, px), mipmapLevel: 0)
            let inset = (px - cell) / 2
            let img = ctx.makeImage()!.cropping(to: CGRect(x: inset, y: inset, width: cell, height: cell))!
            let c = f % cols, row = f / cols
            sheet.draw(img, in: CGRect(x: c * cell, y: (frames / cols - 1 - row) * cell, width: cell, height: cell))
        }
        let rep = NSBitmapImageRep(cgImage: sheet.makeImage()!)
        try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!.write(to: URL(fileURLWithPath: dir + "/robot-sheet.jpg"))

        let dockView = V2(330, 480)
        let rd = try Renderer(device: device, sizePts: dockView)
        let d = Sim(size: dockView, visibleMin: V2(0, 0), visibleMax: V2(330, 440), entries: [])
        d.dockDrop = 1; d.led = SIMD3(0.35, 1, 0.5)
        let td2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 660, height: 960, mipmapped: false)
        td2.usage = [.renderTarget, .shaderRead]; td2.storageMode = .shared
        let tex2 = device.makeTexture(descriptor: td2)!
        for (name, bag) in [("dock-empty", Float(0)), ("dock-full", Float(1))] {
            d.bagFill = bag
            rd.renderPart(robot: false, sim: d, target: tex2, clear: MTLClearColorMake(0, 0, 0, 0))
            try savePNG(tex2, to: dir + "/\(name).png", space: space, crop: nil)
        }
        print("dock centre in points:", d.dockPos, "of", dockView, "robot radius:", d.R)
    }

    static func savePNG(_ t: MTLTexture, to path: String, space: CGColorSpace, crop: CGRect?) throws {
        let ctx = SpriteFactory.context(w: t.width, h: t.height, space: space)
        t.getBytes(ctx.data!, bytesPerRow: ctx.bytesPerRow, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        var img = ctx.makeImage()!
        if let c = crop, let cropped = img.cropping(to: c) { img = cropped }
        let rep = NSBitmapImageRep(cgImage: img)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
