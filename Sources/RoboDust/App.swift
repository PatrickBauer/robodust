import AppKit
import MetalKit
import SwiftUI
import Combine
import Sparkle

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Runs the floor. Takes the pointer so stray clicks can't land on the invisible real icons below.
final class StageView: MTKView, MTKViewDelegate {
    var sim: Sim!
    var renderer: Renderer!
    var last: CFTimeInterval = CACurrentMediaTime()
    var acc: Float = 0
    var grabbed: Item?
    var lastDrag: V2 = .zero, dragVel: V2 = .zero
    var onFinished: (() -> Void)?
    var finishedFired = false
    var telemetry: Telemetry?

    func point(_ e: NSEvent) -> V2 {
        let p = convert(e.locationInWindow, from: nil)
        return V2(Float(p.x), Float(bounds.height - p.y))
    }
    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        if sim.hitRobot(p) { sim.pickUp(); sim.picked = true; return }
        if let it = sim.hitItem(p), !it.icon.ingesting {
            grabbed = it; it.grabbed = true; lastDrag = p; dragVel = .zero
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        if sim.picked { sim.drag(robotTo: p); return }
        if let g = grabbed {
            g.icon.pos = p
            dragVel = dragVel * 0.6 + (p - lastDrag) * 60 * 0.4
            lastDrag = p
        }
    }
    override func mouseUp(with e: NSEvent) {
        if sim.picked { sim.dropRobot() }
        if let g = grabbed { g.grabbed = false; g.icon.vel = dragVel; g.icon.angV = dragVel.x * 0.006; grabbed = nil }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = Float(now - last); last = now
        if dt > 0.05 { dt = 0.05 }
        acc += dt
        let h: Float = 1 / 120
        if let w = window {
            let m = w.mouseLocationOutsideOfEventStream
            let onTop = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == w.windowNumber
            sim.mouse = onTop && !sim.picked ? V2(Float(m.x), Float(bounds.height - m.y)) : nil
        }
        sim.lift += ((sim.picked ? 1 : 0) - sim.lift) * min(1, dt * 11)
        var steps = 0
        while acc >= h && steps < 8 { sim.step(h); acc -= h; steps += 1 }
        if steps == 8 { acc = 0 }
        guard let cb = renderer.queue.makeCommandBuffer(), let d = currentDrawable else { return }
        renderer.encode(sim: sim, target: d.texture, cb: cb, dt: dt)
        cb.present(d)
        cb.commit()
        if sim.phase == .finished && !finishedFired { finishedFired = true; onFinished?() }
        if let tl = telemetry { tl.frame(dt: dt, sim: sim) }
    }
}

enum Source: Int, CaseIterable, Identifiable { case sample, real; var id: Int { rawValue } }

final class Model: ObservableObject {
    enum Stage { case ready, preparing, running, finished }
    @Published var stage = Stage.ready
    @Published var source = Source.sample
    /// Remembered between launches, along with the skip switch below.
    static var persists = true
    @Published var mode: CleanMode = {
        if let raw = UserDefaults.standard.object(forKey: "afterClean") as? Int, let m = CleanMode(rawValue: raw) { return m }
        return .trash
    }() {
        didSet { if Model.persists { UserDefaults.standard.set(mode.rawValue, forKey: "afterClean") } }
    }
    /// Off by default: Trash and Delete wait for one final click once everything is collected.
    @Published var skipFinalClick = UserDefaults.standard.bool(forKey: "skipFinalClick") {
        didSet { if Model.persists { UserDefaults.standard.set(skipFinalClick, forKey: "skipFinalClick") } }
    }
    @Published var outcome: CleanMode?
    @Published var realRun = false
    @Published var applying = false
    @Published var deleteCountdown: Int?
    @Published var result: RunResult?
    @Published var excluded = Set<Int>()
    @Published var reviewOpen = false
    @Published var fileBytes: Int64 = 0
    @Published var folderCount = 0
    @Published var leftAlone = 0
    @Published var usesICloud = false
    var reviewRows: [(index: Int, name: String)] = []
    @Published var clearWindows = true
    @Published var muted = false
    @Published var prepared = 0
    @Published var prepareTotal = 0
    @Published var note: String?
    @Published var realCount: Int?
    // Live.
    @Published var status = ""
    @Published var phase = Phase.dropping
    @Published var paused = false
    @Published var battery: Float = 1
    @Published var bin: Float = 0
    @Published var collected = 0
    @Published var collectedBytes: Int64 = 0
    @Published var total = 0
    @Published var totalBytes: Int64 = 0
    @Published var runTime: Float = 0
    @Published var mapTick = 0
    weak var sim: Sim?
    var start: () -> Void = {}
    var togglePause: () -> Void = {}
    var stop: () -> Void = {}
    var putBack: () -> Void = {}
    var choose: (CleanMode) -> Void = { _ in }
    var cancelCountdown: () -> Void = {}
    var about: () -> Void = {}
    var undo: () -> Void = {}
    var dismissResult: () -> Void = {}
    var sendHome: () -> Void = {}
}

struct RunResult {
    var title: String
    var detail: String?
    var canUndo = false
    var isError = false
}

final class AppController: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: NSPanel!
    var panelHost: NSView?
    var bag = Set<AnyCancellable>()
    var overlay: OverlayWindow?
    var stage: StageView?
    var sim: Sim?
    let synth = Synth()
    var hidden: [NSRunningApplication] = []
    var uiTimer: Timer?
    var status: NSStatusItem?
    var keyMonitor: Any?
    var autoDemo = false
    var telemetryPath: String?
    var autoPutBack = false
    var testRoot: URL?
    var updateTestLog: String?
    let updates = Updates()
    var autoUpdateItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        if let log = updateTestLog {
            NSApp.setActivationPolicy(.accessory)
            updates.testLog = log
            updates.start()
            updates.updater.checkForUpdatesInBackground()
            return
        }
        updates.isBusy = { [weak self] in self?.model.stage == .running || self?.model.stage == .preparing }
        updates.start()
        NSApp.setActivationPolicy(.regular)
        model.start = { [weak self] in self?.begin() }
        model.togglePause = { [weak self] in self?.togglePause() }
        model.stop = { [weak self] in self?.stopAndRestore() }
        model.putBack = { [weak self] in self?.sim?.putBack() }
        model.choose = { [weak self] choice in
            self?.perform(choice)
        }
        model.cancelCountdown = { [weak self] in
            self?.countdown?.invalidate(); self?.countdown = nil
            self?.model.deleteCountdown = nil
            self?.actionStarted = true
            self?.sim?.putBack()
        }
        model.about = { [weak self] in self?.showAbout() }
        model.undo = { [weak self] in self?.runUndo() }
        model.dismissResult = { [weak self] in self?.model.result = nil; self?.undoAction = nil }
        model.sendHome = { [weak self] in
            guard let s = self?.sim, [.cleaning, .hunting].contains(s.phase) else { return }
            s.goDock(mid: false)
        }
        buildMainMenu()
        buildPanel()
        buildStatusItem()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.overlay != nil else { return e }
            if self.model.applying { return nil }                          // nothing interrupts a file action
            if e.keyCode == 53 { self.stopAndRestore(); return nil }       // esc
            if e.keyCode == 49 { self.togglePause(); return nil }          // space
            return e
        }
        NSApp.activate(ignoringOtherApps: true)
        if autoDemo { begin() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { restoreApps() }

    func buildStatusItem() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "RoboDust")
        let m = NSMenu()
        m.addItem(withTitle: "About RoboDust", action: #selector(aboutAction), keyEquivalent: "").target = self
        addUpdateItems(to: m)
        m.addItem(withTitle: "Show RoboDust", action: #selector(showPanel), keyEquivalent: "").target = self
        m.addItem(withTitle: "Stop and restore desktop", action: #selector(stopAction), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        it.menu = m
        status = it
    }
    @objc func showPanel() { panel.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true) }
    @objc func stopAction() { if !model.applying { stopAndRestore() } }
    @objc func aboutAction() { showAbout() }

    func addUpdateItems(to m: NSMenu) {
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updates.controller
        m.addItem(check)
        let auto = NSMenuItem(title: "Install Updates Automatically", action: #selector(toggleAutoUpdates(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = updates.updater.automaticallyDownloadsUpdates ? .on : .off
        m.addItem(auto)
        autoUpdateItems.append(auto)
    }

    /// Off means RoboDust asks before installing an update, rather than never checking.
    @objc func toggleAutoUpdates(_ sender: NSMenuItem) {
        let on = !updates.updater.automaticallyDownloadsUpdates
        updates.updater.automaticallyDownloadsUpdates = on
        autoUpdateItems.forEach { $0.state = on ? .on : .off }
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "About RoboDust", action: #selector(aboutAction), keyEquivalent: "").target = self
        addUpdateItems(to: m)
        m.addItem(.separator())
        m.addItem(withTitle: "Hide RoboDust", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit RoboDust", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    func showAbout() {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let credits = NSMutableAttributedString(string: "Developed by Muhammad Raufan Yusup\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        credits.append(NSAttributedString(string: "muhraufan.com", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .link: URL(string: "https://muhraufan.com")!, .paragraphStyle: para]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "RoboDust",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Muhammad Raufan Yusup",
        ])
        // The floating control panel would otherwise cover it.
        for w in NSApp.windows where w !== panel && w !== overlay && w.isVisible { w.level = .modalPanel }
    }

    func buildPanel() {
        let host = NSHostingView(rootView: PanelView(model: model))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 560),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        host.layoutSubtreeIfNeeded()
        p.setContentSize(host.fittingSize)
        p.setFrameOrigin(NSPoint(x: v.maxX - p.frame.width - 28, y: v.minY + 28))
        p.makeKeyAndOrderFront(nil)
        panel = p
        panelHost = host
        // Grow and shrink with the content, keeping the bottom edge where it is.
        Publishers.MergeMany(model.$stage.map { _ in () }.eraseToAnyPublisher(), model.$phase.map { _ in () }.eraseToAnyPublisher(), model.$note.map { _ in () }.eraseToAnyPublisher(), model.$outcome.map { _ in () }.eraseToAnyPublisher(), model.$mode.map { _ in () }.eraseToAnyPublisher(), model.$reviewOpen.map { _ in () }.eraseToAnyPublisher(), model.$result.map { _ in () }.eraseToAnyPublisher(), model.$deleteCountdown.map { _ in () }.eraseToAnyPublisher(), model.$applying.map { _ in () }.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.fitPanel() }
            .store(in: &bag)
    }

    func fitPanel() {
        guard let host = panelHost, let p = panel else { return }
        host.layoutSubtreeIfNeeded()
        let h = host.fittingSize.height
        guard abs(h - p.frame.height) > 1 else { return }
        var f = p.frame
        f.size.height = h
        p.setFrame(f, display: true, animate: false)
    }

    // MARK: - Run

    func begin() {
        guard model.stage == .ready || model.stage == .finished else { return }
        let screen = NSScreen.screens.first ?? NSScreen.main!
        var entries: [DesktopEntry]
        model.note = nil
        model.result = nil
        undoAction = nil
        if let root = testRoot {
            entries = DesktopReader.sandbox(root, size: screen.frame.size)
        } else if model.source == .real {
            do { entries = try DesktopReader.read(on: screen) }
            catch DesktopError.noItems {
                model.note = "Your desktop is already empty, so here's the sample mess instead."
                entries = DesktopReader.sample(screen: screen.frame.size)
            } catch {
                model.note = "RoboDust can't read your desktop without Finder access, so here's the sample mess. To allow it: System Settings › Privacy & Security › Automation › RoboDust."
                model.source = .sample
                entries = DesktopReader.sample(screen: screen.frame.size)
            }
        } else {
            entries = DesktopReader.sample(screen: screen.frame.size)
        }
        model.stage = .preparing
        model.prepared = 0
        model.prepareTotal = entries.count
        let space = screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        SpriteFactory.build(entries, space: space, progress: { [weak self] n in self?.model.prepared = max(self?.model.prepared ?? 0, n) }) { [weak self] sprites in
            self?.launch(entries: entries, sprites: sprites, screen: screen, space: space)
        }
    }

    func launch(entries: [DesktopEntry], sprites: [SpriteFactory.Sprite], screen: NSScreen, space: CGColorSpace) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = V2(Float(screen.frame.width), Float(screen.frame.height))
        do {
            let r = try Renderer(device: device, sizePts: size)
            let wall = Wallpaper.capture(screen: screen) ?? Wallpaper.fallback(size: screen.frame.size)
            r.setWallpaper(wall, space: space)
            r.setSprites(sprites, space: space)
            let top = Float(screen.frame.maxY - screen.visibleFrame.maxY)
            let bottom = Float(screen.visibleFrame.minY - screen.frame.minY)
            let s = Sim(size: size, visibleMin: V2(0, top), visibleMax: V2(size.x, size.y - bottom), entries: entries)
            for (i, sp) in sprites.enumerated() { s.items[i].color = sp.average }
            s.mode = model.mode
            model.outcome = nil
            s.skipFinalClick = false   // handled here, so that it goes through the real file action
            actionStarted = false
            // Entries with no file behind them (the sample mess) can never reach FileOps.
            let real = entries.contains { $0.url != nil }
            s.realRun = real
            model.realRun = real
            for it in s.items {
                it.protected = it.entry.missing || (s.mode != .tidy && it.entry.protectedReason != nil)
            }
            let collectable = s.items.filter { !$0.protected }
            model.excluded = []
            model.reviewOpen = false
            model.reviewRows = collectable.map { ($0.index, $0.entry.name) }
            model.fileBytes = collectable.filter { $0.entry.kind != .folder }.reduce(0) { $0 + $1.entry.bytes }
            model.folderCount = collectable.filter { $0.entry.kind == .folder }.count
            model.leftAlone = s.items.count - collectable.count
            model.usesICloud = collectable.contains { $0.entry.iCloud }
            s.audio = synth
            synth.muted = model.muted
            synth.startLive()
            sim = s

            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.hasShadow = false
            w.isOpaque = true
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = false
            let v = StageView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
            v.colorPixelFormat = .bgra8Unorm
            v.framebufferOnly = true
            v.preferredFramesPerSecond = screen.maximumFramesPerSecond
            v.sim = s; v.renderer = r
            v.delegate = v
            (v.layer as? CAMetalLayer)?.colorspace = space
            w.contentView = v
            v.onFinished = { [weak self] in self?.finishRun() }
            v.telemetry = telemetryPath.map { Telemetry(path: $0) }
            stage = v
            overlay = w
            if model.clearWindows { hideApps() }
            w.orderFront(nil)
            model.total = collectable.count
            model.totalBytes = collectable.reduce(0) { $0 + $1.entry.bytes }
            model.sim = s
            model.stage = .running
            model.phase = s.phase
            uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.syncUI() }
            s.onDoneOnce = { [weak self] in
                self?.model.objectWillChange.send()
                if self?.autoPutBack == true { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.sim?.putBack() } }
            }
        } catch {
            model.note = "Couldn't start: \(error.localizedDescription)"
            model.stage = .ready
        }
    }

    func syncUI() {
        guard let s = sim else { return }
        let m = model
        if m.status != s.status { m.status = s.status }
        if m.phase != s.phase { m.phase = s.phase }
        if let d = s.discarded, m.outcome != d { m.outcome = d }
        if m.paused != s.paused { m.paused = s.paused }
        m.battery = s.battery
        m.bin = Float(s.binCount) / Float(max(s.binCapacity, 1))
        m.collected = s.collected
        m.collectedBytes = s.collectedBytes
        m.runTime = s.runTime
        m.mapTick &+= 1
        synth.muted = m.muted
        // Skip-the-question path.
        if s.phase == .done && !actionStarted && m.skipFinalClick && s.mode != .tidy && countdown == nil {
            if s.mode == .trash { perform(.trash) } else { startDeleteCountdown() }
        }
        if s.phase == .tidied && s.realRun && !actionStarted { actionStarted = true; applyTidy(s) }
    }

    func togglePause() { sim?.paused.toggle() }

    // MARK: - Real actions

    var actionStarted = false
    var countdown: Timer?
    var undoAction: (() -> Void)?

    /// Permanent, so even with the question skipped there's a moment to change your mind.
    func startDeleteCountdown() {
        var left = 10
        model.deleteCountdown = left
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            left -= 1
            self?.model.deleteCountdown = left
            if left <= 0 {
                t.invalidate(); self?.countdown = nil; self?.model.deleteCountdown = nil
                self?.perform(.delete)
            }
        }
    }

    func perform(_ choice: CleanMode) {
        guard let s = sim, !actionStarted, s.phase == .done, choice != .tidy else { return }
        actionStarted = true
        model.outcome = choice
        s.discard(choice)
        guard s.realRun else { return }

        let root = testRoot ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let excluded = model.excluded
        let chosen = s.items.filter { $0.inDock && !$0.protected && !excluded.contains($0.index) && $0.entry.url != nil }
        let targets = chosen.map { FileOps.Target(index: $0.index, url: $0.entry.url!, modified: $0.entry.modified, position: $0.home) }
        // Global position, which is what Finder expects when restoring.
        let origin = screenOrigin
        let globalTargets = targets.map { t -> FileOps.Target in var g = t; g.position = t.position + origin; return g }
        model.applying = true
        let started = CACurrentMediaTime()
        let finish: (FileOps.Outcome) -> Void = { [weak self] o in
            guard let self, let s = self.sim else { return }
            self.report(choice, o, excludedCount: excluded.count)
            let failed = Set(o.failed.map(\.index))
            let back = s.items.filter { $0.inDock && (failed.contains($0.index) || excluded.contains($0.index)) }
            // Let the bag finish draining, and give Finder time to redraw beneath the overlay.
            let wait = max(0, 1.5 - (CACurrentMediaTime() - started)) + 0.7
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.model.applying = false
                s.finishAfterAction(returning: back)
            }
        }
        if choice == .delete { FileOps.delete(globalTargets, root: root, done: finish) }
        else { FileOps.trash(globalTargets, root: root, done: finish) }
    }

    var screenOrigin: V2 {
        let screen = NSScreen.screens.first!
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return V2(Float(screen.frame.minX), Float(mainH - screen.frame.maxY))
    }

    func report(_ choice: CleanMode, _ o: FileOps.Outcome, excludedCount: Int) {
        let n = o.done.count
        let noun = n == 1 ? "item" : "items"
        var title = choice == .delete ? "Permanently deleted \(n) \(noun)" : "Moved \(n) \(noun) to the Trash"
        var notes: [String] = []
        if !o.failed.isEmpty { notes.append("\(o.failed.count) couldn't be \(choice == .delete ? "deleted" : "moved") and stayed on your desktop.") }
        if excludedCount > 0 { notes.append("\(excludedCount) kept, as you chose.") }
        if model.leftAlone > 0 { notes.append("\(model.leftAlone) left alone for safety.") }
        if n == 0 { title = "Nothing was changed" }
        let trashed = o.trashed
        if choice == .trash && !trashed.isEmpty {
            undoAction = { [weak self] in
                self?.model.result = RunResult(title: "Bringing items back…")
                FileOps.undoTrash(trashed) { count in
                    DispatchQueue.main.async {
                        self?.model.result = RunResult(title: "Brought back \(count) \(count == 1 ? "item" : "items")",
                                                       detail: count < trashed.count ? "\(trashed.count - count) are still in the Trash." : nil)
                    }
                }
            }
        }
        model.result = RunResult(title: title, detail: notes.isEmpty ? nil : notes.joined(separator: " "), canUndo: undoAction != nil, isError: n == 0 && !o.failed.isEmpty)
    }

    func runUndo() { let a = undoAction; undoAction = nil; a?() }

    func applyTidy(_ s: Sim) {
        model.applying = true
        let origin = screenOrigin
        let placed = s.items.filter { !$0.protected && $0.entry.url != nil }
        let moves = placed.map { ($0.entry.url!, $0.rest + origin) }
        let old = placed.map { ($0.entry.url!, $0.home + origin) }
        DispatchQueue.global(qos: .userInitiated).async {
            let free = FileOps.desktopIsFreeform()
            let done: (String?) -> Void = { [weak self] err in
                guard let self else { return }
                self.model.applying = false
                if !free {
                    self.model.result = RunResult(title: "Your desktop wasn't sorted", detail: "Finder is keeping your icons sorted. To use Tidy up, right-click the desktop and set Sort By to None.", isError: true)
                } else if err != nil {
                    self.model.result = RunResult(title: "Tidy up didn't finish", detail: "Finder didn't accept every move. No files were changed.", isError: true)
                } else {
                    self.undoAction = { [weak self] in
                        self?.model.result = RunResult(title: "Putting icons back…")
                        FileOps.setPositions(old) { _ in self?.model.result = RunResult(title: "Icons are back where they were") }
                    }
                    self.model.result = RunResult(title: "Sorted \(moves.count) items into columns", detail: "Only the icons moved. Your files are exactly where they were.", canUndo: true)
                    FileOps.appendLog("tidy: arranged \(moves.count) icons")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { s.finishAfterAction(returning: []) }
            }
            if free { FileOps.setPositions(moves, done: done) }
            else { DispatchQueue.main.async { done(nil) } }
        }
    }

    func hideApps() {
        let me = NSRunningApplication.current
        // Finder is included: hiding it clears its windows, and the desktop itself stays.
        hidden = NSWorkspace.shared.runningApplications.filter { $0 != me && $0.activationPolicy == .regular && !$0.isHidden }
        // An app can refuse to hide while it's frontmost, so take the front first and check again.
        NSApp.activate(ignoringOtherApps: true)
        hidden.forEach { $0.hide() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.hidden.filter { !$0.isHidden && !$0.isTerminated }.forEach { $0.hide() }
        }
    }
    func restoreApps() { hidden.forEach { $0.unhide() }; hidden = [] }

    /// The overlay fades to reveal the real desktop, which now matches it.
    func finishRun() {
        guard let w = overlay else { teardown(); model.stage = .ready; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.teardown()
            self?.model.stage = .ready
        })
    }

    func stopAndRestore() {
        countdown?.invalidate(); countdown = nil
        model.deleteCountdown = nil
        teardown(); model.stage = .ready
    }

    /// Removing the overlay is the whole restore: the real desktop was never changed.
    func teardown() {
        uiTimer?.invalidate(); uiTimer = nil
        synth.setMotor(level: 0, load: 0); synth.setRoar(0)
        synth.stopLive()
        stage?.isPaused = true
        stage?.delegate = nil
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay = nil; stage = nil; sim = nil; model.sim = nil
        restoreApps()
    }
}

/// Frame pacing and run state, written once a second. Contains no pixels or file names.
final class Telemetry {
    let h: FileHandle?
    var n = 0, sum: Float = 0, worst: Float = 0, last = CACurrentMediaTime()
    init(path: String) { FileManager.default.createFile(atPath: path, contents: nil); h = FileHandle(forWritingAtPath: path) }
    func frame(dt: Float, sim: Sim) {
        n += 1; sum += dt; worst = max(worst, dt)
        let now = CACurrentMediaTime()
        if now - last >= 1 {
            let line = String(format: "t=%.0f fps=%.1f worst=%.1fms phase=%@ collected=%d/%d\n", sim.t, Double(n) / (now - last), worst * 1000, "\(sim.phase)", sim.collected, sim.items.count)
            h?.write(line.data(using: .utf8)!)
            n = 0; sum = 0; worst = 0; last = now
        }
    }
}
