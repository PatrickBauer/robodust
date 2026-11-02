import AppKit
import SwiftUI

private let accent = Color(red: 0.36, green: 0.84, blue: 0.98)

func fmtBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; f.includesActualByteCount = false
    return f.string(fromByteCount: b)
}

/// Colours are set here rather than by the system, so a label can never blend into its button.
struct PanelButton: ButtonStyle {
    enum Kind { case primary, danger, quiet }
    var kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
    var foreground: Color {
        switch kind {
        case .primary: return .black
        case .danger: return Color(red: 1, green: 0.55, blue: 0.52)
        case .quiet: return .white
        }
    }
    var background: Color {
        switch kind {
        case .primary: return accent
        case .danger: return Color(red: 1, green: 0.27, blue: 0.23).opacity(0.14)
        case .quiet: return Color.white.opacity(0.1)
        }
    }
    var border: Color { kind == .danger ? Color(red: 1, green: 0.4, blue: 0.36).opacity(0.5) : .clear }
}

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch model.stage {
                case .ready, .finished: setup
                case .preparing: preparing
                case .running: running
                }
            }
            .padding(.top, 16)
        }
        .padding(20)
        .padding(.top, 10)
        .frame(width: 372)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.09))
    }

    var header: some View {
        HStack(alignment: .center, spacing: 10) {
            RobotGlyph().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("RoboDust").font(.system(size: 17, weight: .semibold))
                Text(model.stage == .running ? model.status : "Robot vacuum for your desktop")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            if model.stage != .running {
                Button(action: model.about) {
                    Image(systemName: "info.circle").font(.system(size: 14)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("About RoboDust")
            }
            if model.stage == .running {
                Button { model.muted.toggle() } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 13)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Sound")
            }
        }
    }

    // MARK: Setup

    var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let r = model.result { resultCard(r) }
            field("Clean") {
                Picker("", selection: $model.source) {
                    Text("Sample mess").tag(Source.sample)
                    Text("My real desktop").tag(Source.real)
                }.pickerStyle(.segmented).labelsHidden()
            }
            field("After cleaning") {
                Picker("", selection: $model.mode) {
                    ForEach(CleanMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(modeBlurb).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.mode != .tidy {
                    Toggle(isOn: $model.skipFinalClick) {
                        Text("Don't ask me, just clean up").font(.system(size: 13))
                    }.toggleStyle(.switch).controlSize(.small).padding(.top, 3)
                    if model.mode == .delete && model.skipFinalClick {
                        Text("With no final click, RoboDust will permanently delete everything it collects after a 10-second countdown.")
                            .font(.system(size: 12)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Toggle(isOn: $model.clearWindows) {
                Text("Clear my windows so I can watch").font(.system(size: 13))
            }.toggleStyle(.switch).controlSize(.small)

            if let n = model.note {
                Text(n).font(.system(size: 12)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            Button("Start cleaning", action: model.start)
                .buttonStyle(PanelButton(kind: .primary))
                .keyboardShortcut(.defaultAction)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.source == .real ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                    .foregroundStyle(model.source == .real ? Color.orange : accent).font(.system(size: 13))
                Text(footnote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var footnote: String {
        guard model.source == .real else { return "The sample mess is made up, so nothing real is touched." }
        switch model.mode {
        case .tidy: return "RoboDust will rearrange your real desktop icons. Your files don't move."
        case .trash: return "RoboDust will move your real files to the Trash. It leaves anything locked, just changed, or a code project alone."
        case .delete: return "RoboDust will permanently delete your real files. It leaves anything locked, just changed, or a code project alone."
        }
    }

    func resultCard(_ r: RunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(r.isError ? Color.orange : Color.primary)
            if let d = r.detail {
                Text(d).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if r.canUndo { Button("Undo", action: model.undo).buttonStyle(PanelButton(kind: .quiet)) }
                Button("Done", action: model.dismissResult).buttonStyle(PanelButton(kind: .quiet))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    var modeBlurb: String {
        let ask = model.skipFinalClick ? "" : " RoboDust asks for a final click first."
        switch model.mode {
        case .tidy: return "Sorts everything into neat columns by type, automatically."
        case .trash: return "Moves everything to the Trash, where you can still get it back." + ask
        case .delete: return "Permanently deletes everything." + ask
        }
    }

    func field<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            c()
        }
    }

    var preparing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copying your icons…").font(.system(size: 13))
            ProgressView(value: Double(model.prepared), total: Double(max(model.prepareTotal, 1))).tint(accent)
            Text("\(model.prepared) of \(model.prepareTotal)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: Running

    var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            MapView(model: model).frame(height: 190)
            HStack(spacing: 18) {
                meter("Battery", value: model.battery, text: "\(Int(model.battery * 100))%", tint: Color(red: 0.42, green: 0.9, blue: 0.55))
                meter("Bin", value: model.bin, text: "\(Int(min(model.bin, 1) * 100))%", tint: model.bin > 0.85 ? .orange : accent)
            }
            HStack(spacing: 0) {
                stat("\(model.collected)", "of \(model.total) items")
                Spacer()
                stat(fmtBytes(model.collectedBytes), "collected")
                Spacer()
                stat(timeString, "elapsed")
            }
            controls
        }
    }

    var timeString: String { let s = Int(model.runTime); return String(format: "%d:%02d", s / 60, s % 60) }

    var awaitingChoice: Bool { model.phase == .done && model.mode != .tidy && !model.skipFinalClick && model.outcome == nil && !model.applying }

    var selectedCount: Int { model.total - model.excluded.count }

    var sizeLine: String {
        var parts: [String] = []
        if model.fileBytes > 0 { parts.append("\(fmtBytes(model.fileBytes)) in files") }
        if model.folderCount > 0 { parts.append("\(model.folderCount) \(model.folderCount == 1 ? "folder" : "folders")") }
        return parts.joined(separator: ", plus ")
    }

    var decision: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.mode == .delete ? "Permanently delete \(selectedCount) items?" : "Move \(selectedCount) items to the Trash?")
                    .font(.system(size: 13, weight: .semibold))
                Text(decisionBody).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.realRun && model.usesICloud {
                    Text("Your Desktop syncs with iCloud, so these will also go from your other devices.")
                        .font(.system(size: 12)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.realRun {
                DisclosureGroup(isExpanded: $model.reviewOpen) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.reviewRows, id: \.index) { row in
                                Toggle(isOn: Binding(
                                    get: { !model.excluded.contains(row.index) },
                                    set: { on in if on { model.excluded.remove(row.index) } else { model.excluded.insert(row.index) } }
                                )) {
                                    Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                }.toggleStyle(.checkbox)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 170)
                } label: {
                    Text("Review items").font(.system(size: 12, weight: .medium))
                }
            }
            VStack(spacing: 8) {
                if model.mode == .delete {
                    Button("Delete permanently") { model.choose(.delete) }.buttonStyle(PanelButton(kind: .danger)).disabled(selectedCount == 0)
                } else {
                    Button("Move to Trash") { model.choose(.trash) }.buttonStyle(PanelButton(kind: .primary)).disabled(selectedCount == 0)
                }
                Button("Put everything back", action: model.putBack).buttonStyle(PanelButton(kind: .quiet))
            }
        }
    }

    var decisionBody: String {
        guard model.realRun else { return "This is the sample mess, so nothing real will change." }
        var text = sizeLine.isEmpty ? "" : sizeLine + ". "
        text += model.mode == .delete ? "This can't be undone." : "You can get them back from the Trash."
        if model.leftAlone > 0 { text += " \(model.leftAlone) left alone for safety." }
        return text
    }

    var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summaryTitle).font(.system(size: 13, weight: .semibold))
            Text(summaryBody).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var summaryTitle: String {
        switch model.outcome {
        case .trash: return "\(model.total) items moved to the Trash"
        case .delete: return "\(model.total) items deleted"
        default: return "Sorted into columns"
        }
    }
    var summaryBody: String {
        "That was the sample mess, so nothing real changed. Put everything back to finish."
    }

    @ViewBuilder var controls: some View {
        if let left = model.deleteCountdown {
            VStack(alignment: .leading, spacing: 4) {
                Text("Deleting \(selectedCount) items in \(left)…").font(.system(size: 13, weight: .semibold))
                Text("This can't be undone once it starts.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Stop and put everything back", action: model.cancelCountdown).buttonStyle(PanelButton(kind: .primary))
        } else if model.applying {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.outcome == .delete ? "Deleting…" : model.outcome == .trash ? "Moving to the Trash…" : "Arranging your icons…").font(.system(size: 13))
            }
        } else if awaitingChoice {
            decision
        } else if model.realRun && [.done, .tidying, .tidied].contains(model.phase) {
            if model.phase != .done {
                Text("Sorting your icons into columns…").font(.system(size: 13))
            } else if model.outcome == nil && model.mode == .tidy {
                Text("Sorting your icons into columns…").font(.system(size: 13))
            }
        } else if [.done, .tidying, .tidied].contains(model.phase) {
            summary
            Button("Put everything back", action: model.putBack).buttonStyle(PanelButton(kind: .primary))
        } else if [.puttingBack, .leaving, .finished].contains(model.phase) {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Button(action: model.togglePause) {
                    Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
                }.buttonStyle(PanelButton(kind: .quiet))
                Button(action: model.stop) {
                    Label("Stop", systemImage: "xmark")
                }.buttonStyle(PanelButton(kind: .quiet))
            }
            Text(model.realRun ? "Stopping before the end changes nothing. Esc works too." : "Esc stops and brings your desktop back. Try dragging the robot, or throwing an icon at it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func meter(_ title: String, value: Float, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.system(size: 12).monospacedDigit())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(tint).frame(width: g.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }.frame(height: 5)
        }
    }

    func stat(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(big).font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(small).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Top-down glyph of the robot, for the header.
struct RobotGlyph: View {
    var body: some View {
        Canvas { c, s in
            let r = CGRect(origin: .zero, size: s)
            c.fill(Path(ellipseIn: r), with: .color(Color(white: 0.9)))
            c.fill(Path(ellipseIn: r.insetBy(dx: s.width * 0.15, dy: s.width * 0.15)), with: .color(Color(white: 0.12)))
            let t = CGRect(x: s.width * 0.34, y: s.height * 0.2, width: s.width * 0.32, height: s.width * 0.32)
            c.fill(Path(ellipseIn: t), with: .color(accent))
        }
    }
}

/// The floor plan, like the one in a real robot's phone app. Draws only what lidar has "seen".
struct MapView: View {
    @ObservedObject var model: Model

    var body: some View {
        Canvas { c, sz in
            guard let s = model.sim else { return }
            _ = model.mapTick
            let k = min(sz.width / CGFloat(s.size.x), sz.height / CGFloat(s.size.y))
            let w = CGFloat(s.size.x) * k, h = CGFloat(s.size.y) * k
            let ox = (sz.width - w) / 2, oy = (sz.height - h) / 2
            func P(_ v: V2) -> CGPoint { CGPoint(x: ox + CGFloat(v.x) * k, y: oy + CGFloat(v.y) * k) }
            let frame = CGRect(x: ox, y: oy, width: w, height: h)
            let shape = Path(roundedRect: frame, cornerRadius: 8)
            c.fill(shape, with: .color(Color.white.opacity(0.05)))
            c.clip(to: shape)

            // Cleaned area: the path, stroked at robot width.
            if s.trail.count > 1 {
                var p = Path()
                p.move(to: P(s.trail[0]))
                for t in s.trail.dropFirst() { p.addLine(to: P(t)) }
                c.stroke(p, with: .color(accent.opacity(0.16)), style: StrokeStyle(lineWidth: CGFloat(s.R) * 1.7 * k, lineCap: .round, lineJoin: .round))
                c.stroke(p, with: .color(accent.opacity(0.65)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
            // Dock.
            let dock = P(s.dockPos + V2(0, s.R * 1.2))
            c.fill(Path(roundedRect: CGRect(x: dock.x - 10, y: dock.y - 6, width: 20, height: 12), cornerRadius: 3), with: .color(.white.opacity(0.75)))
            // Items.
            for it in s.items where it.seen && it.onFloor {
                let q = P(it.icon.pos)
                c.fill(Path(ellipseIn: CGRect(x: q.x - 1.6, y: q.y - 1.6, width: 3.2, height: 3.2)), with: .color(color(it.entry.kind)))
            }
            // Robot.
            let rp = P(s.pos), rr = max(CGFloat(s.R) * k, 4)
            c.fill(Path(ellipseIn: CGRect(x: rp.x - rr, y: rp.y - rr, width: rr * 2, height: rr * 2)), with: .color(.white))
            var nose = Path()
            nose.move(to: rp)
            nose.addLine(to: CGPoint(x: rp.x + CGFloat(cos(s.heading)) * rr, y: rp.y + CGFloat(sin(s.heading)) * rr))
            c.stroke(nose, with: .color(.black), lineWidth: 1.5)
        }
        .overlay(alignment: .topLeading) {
            if model.phase == .scanning {
                Text("Mapping").font(.system(size: 11, weight: .medium)).foregroundStyle(accent).padding(8)
            }
        }
    }

    func color(_ k: Kind) -> Color {
        switch k {
        case .folder: return Color(red: 0.4, green: 0.7, blue: 1)
        case .image: return Color(red: 1, green: 0.72, blue: 0.4)
        case .video: return Color(red: 1, green: 0.45, blue: 0.5)
        case .document: return Color(white: 0.9)
        case .archive: return Color(red: 0.8, green: 0.6, blue: 1)
        case .audio: return Color(red: 0.5, green: 0.95, blue: 0.7)
        case .other: return Color(white: 0.6)
        }
    }
}

/// Renders the panel's states to PNGs, to review layout without touching the screen.
enum PanelShot {
    @MainActor static func one(_ m: Model, _ path: String) {
        let r = ImageRenderer(content: PanelView(model: m).environment(\.colorScheme, .dark))
        r.scale = 2
        if let img = r.cgImage { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
    }
    static func render(to dir: String) {
        MainActor.assumeIsolated {
            Model.persists = false
            let a = Model(); a.mode = .delete; a.skipFinalClick = true; one(a, dir + "/panel_ready.png")
            let e = DesktopReader.sample(screen: CGSize(width: 2560, height: 1440))
            let s = Sim(size: V2(2560, 1440), visibleMin: V2(0, 38), visibleMax: V2(2560, 1376), entries: e)
            for it in s.items.prefix(30) { it.seen = true }
            let b = Model(); b.stage = .running; b.sim = s; b.status = "Cleaning"; b.phase = .cleaning; b.total = 42; b.collected = 17; b.collectedBytes = 4_300_000_000; b.bin = 0.7; b.battery = 0.92; b.runTime = 74
            one(b, dir + "/panel_running.png")
            let c = Model(); c.stage = .running; c.sim = s; c.status = "All clean"; c.phase = .done; c.total = 42; c.collected = 42; c.totalBytes = 15_000_000_000; c.collectedBytes = 15_000_000_000; c.battery = 0.9; c.runTime = 63; c.mode = .delete; c.skipFinalClick = false
            one(c, dir + "/panel_done.png")
            let d = Model(); d.stage = .running; d.sim = s; d.status = "All clean"; d.phase = .done; d.total = 281; d.collected = 281; d.fileBytes = 2_600_000_000; d.folderCount = 3; d.leftAlone = 4; d.realRun = true; d.usesICloud = true; d.mode = .delete; d.skipFinalClick = false; d.battery = 0.9; d.runTime = 196; d.reviewOpen = true
            d.reviewRows = (0..<12).map { ($0, "Screenshot 2026-10-\(10 + $0) at 09.14.22.png") }
            one(d, dir + "/panel_real.png")
            let f = Model(); f.result = RunResult(title: "Moved 277 items to the Trash", detail: "4 left alone for safety.", canUndo: true); f.source = .real
            one(f, dir + "/panel_result.png")
            let g = Model(); g.stage = .running; g.sim = s; g.phase = .done; g.total = 42; g.realRun = true; g.mode = .delete; g.skipFinalClick = true; g.deleteCountdown = 7; g.battery = 0.9; g.status = "All clean"
            one(g, dir + "/panel_countdown.png")
        }
    }
}
