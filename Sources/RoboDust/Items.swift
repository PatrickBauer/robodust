import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

typealias V2 = SIMD2<Float>

extension SIMD2 where Scalar == Float {
    var len: Float { (x * x + y * y).squareRoot() }
    var unit: V2 { let l = len; return l > 1e-5 ? self / l : V2(0, 0) }
    var perp: V2 { V2(-y, x) }
    func dot(_ o: V2) -> Float { x * o.x + y * o.y }
    func rotated(_ a: Float) -> V2 { let c = cos(a), s = sin(a); return V2(c * x - s * y, s * x + c * y) }
}
func clampf(_ v: Float, _ a: Float, _ b: Float) -> Float { min(max(v, a), b) }
func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = clampf((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t) }
func wrapAngle(_ a: Float) -> Float { var x = a; while x > .pi { x -= 2 * .pi }; while x < -.pi { x += 2 * .pi }; return x }

enum Kind: Int, CaseIterable {
    case folder, image, video, document, archive, audio, other
    var title: String {
        switch self {
        case .folder: return "Folders"; case .image: return "Images"; case .video: return "Videos"
        case .document: return "Documents"; case .archive: return "Archives"; case .audio: return "Audio"; case .other: return "Other"
        }
    }
    static func of(_ type: UTType?, isDirectory: Bool) -> Kind {
        if isDirectory { return .folder }
        guard let t = type else { return .other }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .archive) { return .archive }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) { return .document }
        return .other
    }
}

/// One thing on the desktop, as far as drawing is concerned. Holds nothing that can change a file.
struct DesktopEntry {
    var name: String
    var center: V2          // icon centre, top-left origin, screen-local points
    var bytes: Int64
    var kind: Kind
    var url: URL?           // nil for sample items
    var image: CGImage?     // sample items carry their picture
    var modified: Date? = nil
    var protectedReason: String? = nil   // Trash and Delete leave these alone
    var missing = false     // listed by Finder but not a file on the Desktop, such as a disk
    var iCloud = false
}

enum DesktopError: Error { case finderDenied(String), noItems }

enum DesktopReader {
    struct IconMetrics { var iconSize: CGFloat = 64; var textSize: CGFloat = 12; var labelOnBottom = true; var gridSpacing: CGFloat = 54 }

    static func metrics() -> IconMetrics {
        var m = IconMetrics()
        if let d = UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings"),
           let v = d["IconViewSettings"] as? [String: Any] {
            if let s = v["iconSize"] as? NSNumber { m.iconSize = CGFloat(s.doubleValue) }
            if let s = v["textSize"] as? NSNumber { m.textSize = CGFloat(s.doubleValue) }
            if let s = v["gridSpacing"] as? NSNumber { m.gridSpacing = CGFloat(s.doubleValue) }
            if let s = v["labelOnBottom"] as? NSNumber { m.labelOnBottom = s.boolValue }
        }
        return m
    }

    /// Read-only: asks Finder for names and icon positions.
    static func read(on screen: NSScreen) throws -> [DesktopEntry] {
        let src = """
        tell application "Finder"
            set n to name of every item of desktop
            set d to displayed name of every item of desktop
            set p to desktop position of every item of desktop
            return {n, d, p}
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: src)?.executeAndReturnError(&err), out.numberOfItems == 3,
              let names = out.atIndex(1), let shown = out.atIndex(2), let pos = out.atIndex(3) else {
            throw DesktopError.finderDenied((err?[NSAppleScript.errorMessage] as? String) ?? "Finder did not answer")
        }
        // Finder hands back a bare value when the desktop holds exactly one item.
        let count = names.numberOfItems
        guard count > 0 else { throw DesktopError.noItems }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let frame = screen.frame
        let mainH = NSScreen.screens.first?.frame.height ?? frame.height
        // Finder uses a global top-left origin; convert to this screen's top-left origin.
        let originX = Float(frame.minX), originY = Float(mainH - frame.maxY)
        var result: [DesktopEntry] = []
        for i in 1...count {
            guard let nm = names.atIndex(i)?.stringValue, let pd = pos.atIndex(i), pd.numberOfItems == 2,
                  let px = pd.atIndex(1)?.doubleValue, let py = pd.atIndex(2)?.doubleValue else { continue }
            let c = V2(Float(px) - originX, Float(py) - originY)
            if c.x < 0 || c.y < 0 || c.x > Float(frame.width) || c.y > Float(frame.height) { continue }
            let url = desktop.appendingPathComponent(nm)
            result.append(entry(url: url, name: shown.atIndex(i)?.stringValue ?? nm, center: c))
        }
        if result.isEmpty { throw DesktopError.noItems }
        return result
    }

    static func entry(url: URL, name: String, center: V2) -> DesktopEntry {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey, .totalFileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .isUserImmutableKey])
        let isDir = vals?.isDirectory ?? false
        let bytes = Int64(vals?.totalFileSize ?? vals?.fileSize ?? (isDir ? 40_000_000 : 200_000))
        var e = DesktopEntry(name: name, center: center, bytes: bytes, kind: Kind.of(vals?.contentType, isDirectory: isDir), url: url, image: nil)
        e.modified = vals?.contentModificationDate
        e.iCloud = vals?.isUbiquitousItem ?? false
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: url.path)) == nil {
            // Disks and the like appear on the desktop without being files in the Desktop folder.
            e.missing = true; e.protectedReason = "Not a file on the desktop"
        } else if vals?.isUserImmutable == true {
            e.protectedReason = "Locked"
        } else if let m = e.modified, Date().timeIntervalSince(m) < 600 {
            e.protectedReason = "Changed in the last 10 minutes"
        } else if isDir && fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
            e.protectedReason = "Code project"
        } else if url.pathExtension.lowercased() == "app" {
            e.protectedReason = "App"
        }
        return e
    }

    /// Dev only: treats a throwaway folder as if it were the desktop.
    static func sandbox(_ root: URL, size: CGSize) -> [DesktopEntry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.enumerated().map { i, n in
            entry(url: root.appendingPathComponent(n), name: n, center: V2(Float(size.width) * 0.3 + Float(i % 8) * 130, 160 + Float(i / 8) * 120))
        }
    }

    /// A believable mess that contains nothing of the user's. Same code path after this point.
    static func sample(screen size: CGSize) -> [DesktopEntry] {
        var rng = SeededRNG(seed: 20261101)
        func r(_ a: Float, _ b: Float) -> Float { a + (b - a) * Float.random(in: 0...1, using: &rng) }
        let W = Float(size.width), H = Float(size.height)
        let specs: [(String, Kind, Int64)] = [
            ("final-final-v2.pdf", .document, 2_400_000), ("meeting-that-could-be-an-email.txt", .document, 3_000),
            ("Screenshot 2026-10-12 at 09.14.22.png", .image, 900_000), ("Screenshot 2026-10-12 at 09.14.31.png", .image, 880_000),
            ("Screenshot 2026-10-14 at 17.02.11.png", .image, 1_400_000), ("Screenshot 2026-10-19 at 11.47.08.png", .image, 760_000),
            ("Screenshot 2026-10-21 at 22.30.51.png", .image, 1_100_000), ("Screenshot 2026-10-28 at 08.05.40.png", .image, 650_000),
            ("Screen Recording 2026-10-30 at 14.50.30.mov", .video, 4_200_000_000), ("weekend-take-12.mov", .video, 2_100_000_000),
            ("demo-for-nobody.mp4", .video, 880_000_000), ("backup-of-the-backup.zip", .archive, 6_300_000_000),
            ("old-site.zip", .archive, 310_000_000), ("taxes-2023.zip", .archive, 44_000_000),
            ("budget-snacks.xlsx", .document, 90_000), ("q3-slides-actually-final.pptx", .document, 38_000_000),
            ("do-not-delete", .folder, 900_000_000), ("to-delete-later", .folder, 120_000_000), ("desktop-cleaning", .folder, 40_000_000),
            ("icons", .folder, 15_000_000), ("misc", .folder, 80_000_000), ("misc 2", .folder, 60_000_000), ("New Folder", .folder, 0),
            ("three-dollar-song.m4a", .audio, 7_000_000), ("voice-memo-idea.m4a", .audio, 3_000_000),
            ("IMG_2041.jpeg", .image, 3_800_000), ("IMG_2042.jpeg", .image, 3_600_000), ("IMG_2043.jpeg", .image, 4_100_000),
            ("blurry-pigeon.heic", .image, 2_200_000), ("coffee-receipt.jpg", .image, 400_000), ("logo-new-NEW.png", .image, 300_000),
            ("logo-old.png", .image, 220_000), ("notes.txt", .document, 1_000), ("notes copy.txt", .document, 1_000),
            ("notes copy 2.txt", .document, 1_000), ("invoice-sample.pdf", .document, 120_000), ("resume_v14.pdf", .document, 210_000),
            ("ergonomic-chair.pdf", .document, 3_100_000), ("Untitled.txt", .document, 12), ("Untitled 2.txt", .document, 40),
            ("wallpaper-idea.png", .image, 5_400_000), ("mood-board.png", .image, 8_100_000),
        ]
        var out: [DesktopEntry] = []
        // A tidy Finder column on the right, a dense pile in the middle, stragglers everywhere else.
        for (i, s) in specs.enumerated() {
            var c: V2
            let bucket = i % 5
            if bucket == 0 {
                let col = Float((i / 5) / 6), row = Float((i / 5) % 6)
                c = V2(W - 58 - col * 110, 90 + row * 104)
            } else if bucket == 4 {
                c = V2(r(120, W - 120), r(110, H - 300))
            } else {
                let a = r(0, 6.283), d = r(0.25, 1) * r(170, 420)
                c = V2(W * 0.52 + cos(a) * d * 1.5, H * 0.42 + sin(a) * d)
            }
            c.x = clampf(c.x, 60, W - 60); c.y = clampf(c.y, 70, H - 170)
            let t = s.0
            let img: CGImage? = s.1 == .image ? SpriteFactory.sampleThumbnail(seed: i, tall: t.hasPrefix("Screenshot")) : nil
            out.append(DesktopEntry(name: t, center: c, bytes: s.2, kind: s.1, url: nil, image: img))
        }
        return out
    }
}

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return s
    }
}

/// Turns entries into two premultiplied bitmaps (icon + label), drawn to match Finder.
enum SpriteFactory {
    struct Sprite { var icon: CGImage; var label: CGImage; var average: SIMD3<Float> }
    static let iconPts: CGFloat = 64
    static let labelSize = CGSize(width: 124, height: 34)
    static let scale: CGFloat = 2

    static func context(w: Int, h: Int, space: CGColorSpace) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    static func sampleThumbnail(seed: Int, tall: Bool) -> CGImage {
        var rng = SeededRNG(seed: UInt64(seed + 91))
        let w = 256, h = tall ? 170 : 200
        let ctx = context(w: w, h: h, space: CGColorSpace(name: CGColorSpace.sRGB)!)
        func c() -> CGColor { CGColor(srgbRed: .random(in: 0.15...0.95, using: &rng), green: .random(in: 0.2...0.9, using: &rng), blue: .random(in: 0.2...0.95, using: &rng), alpha: 1) }
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [c(), c(), c()] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        if tall {
            ctx.setFillColor(CGColor(gray: 0.98, alpha: 1)); ctx.fill(CGRect(x: 18, y: 18, width: w - 36, height: h - 36))
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1)); ctx.fill(CGRect(x: 18, y: h - 42, width: w - 36, height: 24))
            for i in 0..<5 { ctx.setFillColor(CGColor(gray: 0.72, alpha: 1)); ctx.fill(CGRect(x: 34, y: 34 + i * 18, width: Int.random(in: 80...170, using: &rng), height: 8)) }
        } else {
            for _ in 0..<6 {
                ctx.setFillColor(c().copy(alpha: 0.5)!)
                let d = CGFloat.random(in: 40...120, using: &rng)
                ctx.fillEllipse(in: CGRect(x: .random(in: -20...220, using: &rng), y: .random(in: -20...170, using: &rng), width: d, height: d))
            }
        }
        return ctx.makeImage()!
    }

    static func make(_ e: DesktopEntry, thumbnail: CGImage?, space: CGColorSpace) -> Sprite {
        let px = Int(iconPts * scale)
        let ctx = context(w: px, h: px, space: space)
        let box = CGRect(x: 0, y: 0, width: px, height: px)
        if let img = e.image {
            // Sample pictures get Finder's white preview border.
            let f = fit(CGSize(width: img.width, height: img.height), in: box.insetBy(dx: 5, dy: 5))
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(f.insetBy(dx: -3, dy: -3))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.draw(img, in: f)
        } else if let t = thumbnail {
            ctx.interpolationQuality = .high
            ctx.draw(t, in: fit(CGSize(width: t.width, height: t.height), in: box))
        } else {
            let icon: NSImage
            if let u = e.url { icon = NSWorkspace.shared.icon(forFile: u.path) }
            else { icon = NSWorkspace.shared.icon(for: e.kind == .folder ? .folder : (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data)) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
        let iconImage = ctx.makeImage()!
        return Sprite(icon: iconImage, label: label(e.name, space: space), average: average(iconImage))
    }

    static func fit(_ s: CGSize, in box: CGRect) -> CGRect {
        let k = min(box.width / s.width, box.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h).integral
    }

    /// Two lines at most, word-wrapped, second line middle-truncated: how Finder labels work.
    static func label(_ name: String, space: CGColorSpace) -> CGImage {
        let w = Int(labelSize.width * scale), h = Int(labelSize.height * scale)
        let ctx = context(w: w, h: h, space: space)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor(white: 0, alpha: 0.75)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .shadow: shadow]
        let maxW = labelSize.width - 6
        let lines = wrap(name, width: maxW, attrs: attrs)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)
        var y = labelSize.height - 16
        for l in lines {
            let s = NSAttributedString(string: l, attributes: attrs)
            let sw = s.size().width
            s.draw(at: NSPoint(x: (labelSize.width - sw) / 2, y: y))
            y -= 15
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func wrap(_ text: String, width: CGFloat, attrs: [NSAttributedString.Key: Any]) -> [String] {
        func w(_ s: String) -> CGFloat { NSAttributedString(string: s, attributes: attrs).size().width }
        if w(text) <= width { return [text] }
        // First line: longest prefix that fits, preferring a break after a separator.
        let chars = Array(text)
        var fit = 0
        while fit < chars.count, w(String(chars[0...fit])) <= width { fit += 1 }
        var cut = fit
        if let br = (1..<max(fit, 2)).reversed().first(where: { " -_".contains(chars[$0 - 1]) }), br > fit / 3 { cut = br }
        let first = String(chars[0..<cut]).trimmingCharacters(in: .whitespaces)
        let rest = String(chars[cut...])
        if w(rest) <= width { return [first, rest] }
        // Second line: keep head and tail around an ellipsis.
        let r = Array(rest)
        var keep = r.count - 1
        while keep > 2 {
            let head = keep / 2, tail = keep - head
            let s = String(r[0..<head]) + "…" + String(r[(r.count - tail)...])
            if w(s) <= width { return [first, s] }
            keep -= 1
        }
        return [first, "…"]
    }

    static func average(_ img: CGImage) -> SIMD3<Float> {
        var b = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &b, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let a = max(Float(b[3]), 1)
        return SIMD3(Float(b[0]) / a, Float(b[1]) / a, Float(b[2]) / a)
    }

    /// Builds sprites concurrently; reports progress on the main thread.
    static func build(_ entries: [DesktopEntry], space: CGColorSpace, progress: @escaping (Int) -> Void, done: @escaping ([Sprite]) -> Void) {
        var sprites = [Sprite?](repeating: nil, count: entries.count)
        let lock = NSLock()
        var finished = 0
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 6)
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, e) in entries.enumerated() {
                group.enter(); gate.wait()
                let finish: (CGImage?) -> Void = { thumb in
                    let s = make(e, thumbnail: thumb, space: space)
                    lock.lock(); sprites[i] = s; finished += 1; let f = finished; lock.unlock()
                    DispatchQueue.main.async { progress(f) }
                    gate.signal(); group.leave()
                }
                if let u = e.url {
                    let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: iconPts, height: iconPts), scale: scale, representationTypes: [.icon, .thumbnail])
                    req.iconMode = true
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in finish(rep?.cgImage) }
                } else {
                    DispatchQueue.global(qos: .userInitiated).async { finish(nil) }
                }
            }
            group.notify(queue: .main) { done(sprites.map { $0! }) }
        }
    }
}

enum Wallpaper {
    /// The Dock owns one "Wallpaper-" window per display, and macOS lets any app read it without
    /// Screen Recording. Gives the true pixels, even for dynamic wallpapers.
    static func capture(screen: NSScreen) -> CGImage? {
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let target = CGRect(x: screen.frame.minX, y: mainH - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
            guard let name = w[kCGWindowName as String] as? String, name.hasPrefix("Wallpaper"),
                  let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.equalTo(target), let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.bestResolution]) { return img }
        }
        // Fallback: read the configured file and scale-to-fill.
        if let u = NSWorkspace.shared.desktopImageURL(for: screen), let src = CGImageSourceCreateWithURL(u as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        return nil
    }

    /// Procedural floor for when no wallpaper can be read, and for the headless renderer.
    static func fallback(size: CGSize) -> CGImage {
        let ctx = SpriteFactory.context(w: Int(size.width), h: Int(size.height), space: CGColorSpace(name: CGColorSpace.sRGB)!)
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(srgbRed: 0.13, green: 0.22, blue: 0.42, alpha: 1), CGColor(srgbRed: 0.42, green: 0.32, blue: 0.5, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        return ctx.makeImage()!
    }
}
