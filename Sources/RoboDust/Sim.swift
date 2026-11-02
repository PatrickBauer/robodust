import Foundation
import simd

enum CleanMode: Int, CaseIterable, Identifiable {
    case tidy, trash, delete
    var id: Int { rawValue }
    var title: String { switch self { case .tidy: return "Tidy up"; case .trash: return "Trash"; case .delete: return "Delete" } }
}

enum Phase: Equatable {
    case dropping, undocking, scanning, cleaning, hunting, returning, docking, emptying, done, tidying, tidied, puttingBack, leaving, finished
}

/// One moving sheet of paper: an icon, or the label that tears off it.
struct Body {
    var pos: V2
    var vel = V2(0, 0)
    var ang: Float = 0
    var angV: Float = 0
    var agit: Float = 0      // 0 calm ... 1 being tugged hard
    var pull: Float = 0      // 0...1 through the intake
    var ingesting = false
    var gone = false
    var seed: Float = 0
}

enum Flight { case none, toBag, toHome, toTidy }

final class Item {
    let index: Int
    let entry: DesktopEntry
    let home: V2
    let mass: Float
    let ingestTime: Float
    var color = SIMD3<Float>(0.6, 0.6, 0.6)
    var icon: Body
    var label: Body
    var labelAttached = true
    var labelLost: Float = 0
    var ping: Float = 0
    var seen = false
    var inBin = false
    var inDock = false
    var grabbed = false
    var flight = Flight.none
    var flightFrom = V2(0, 0), flightTo = V2(0, 0)
    var flightT: Float = 0, flightDelay: Float = 0, flightDur: Float = 1
    var flightScale: Float = 1
    var flightSpin: Float = 0
    var land: Float = 0      // squash pulse on landing
    var rest: V2
    var protected = false

    static let labelOffset: Float = 32 + 3 + 17

    init(index: Int, entry: DesktopEntry) {
        self.index = index; self.entry = entry; home = entry.center; rest = entry.center
        let mb = Float(max(entry.bytes, 1)) / 1_000_000
        mass = 1 + 5 * clampf(log10(1 + mb) / 4, 0, 1)
        ingestTime = 0.42 + 0.22 * (mass - 1)
        icon = Body(pos: entry.center, seed: Float(index) * 1.618)
        label = Body(pos: entry.center + V2(0, Item.labelOffset), seed: Float(index) * 2.414)
    }
    var cleared: Bool { icon.gone && (label.gone || labelAttached) }
    var onFloor: Bool { !inBin && !inDock && flight == .none && !icon.gone && !protected }
}

struct Particle {
    var pos: V2, vel: V2
    var life: Float, maxLife: Float
    var size: Float
    var color: SIMD4<Float>
    var chip: Float
    var ang: Float
}

protocol SimAudio: AnyObject {
    func setMotor(level: Float, load: Float)
    func setRoar(_ level: Float)
    func ingest(mass: Float)
    func tick()
    func chirp(_ notes: [(Float, Float)])
    func thud(_ amount: Float)
}

final class Sim {
    // Geometry (points, y down).
    let size: V2
    let wall: (min: V2, max: V2)
    let R: Float = 92
    var speedScale: Float = 1

    // Robot.
    var pos = V2(0, 0), heading: Float = -.pi / 2
    var v: Float = 0, w: Float = 0
    var brushAngle: Float = 0, brushSpeed: Float = 0
    var lidarAngle: Float = 0, lidarSpeed: Float = 0
    var bumper: Float = 0
    var lift: Float = 0, picked = false
    var shake: Float = 0
    var heavy: Float = 0
    var led = SIMD3<Float>(0.2, 0.85, 1.0)
    var ledPulse: Float = 0

    // Dock.
    let dockPos: V2
    let dockOut = V2(0, -1)     // the way the dock faces
    var dockDrop: Float = 0
    var dockAlpha: Float = 1
    var robotAlpha: Float = 1
    var bagFill: Float = 0
    var bagGlow: Float = 0

    // Items and world.
    var items: [Item]
    var particles: [Particle] = []
    var phase = Phase.dropping
    var mode = CleanMode.trash
    var skipFinalClick = false
    var realRun = false
    var discarded: CleanMode?
    var draining = false
    var paused = false
    var t: Float = 0
    var phaseT: Float = 0
    var scanSweep: Float = 0
    var scanActive: Float = 0
    var binCount = 0, binBytes: Int64 = 0
    var collected = 0, collectedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var binCapacity = 0
    var battery: Float = 1
    var distance: Float = 0
    var runTime: Float = 0
    var status = "Warming up"
    var mouse: V2? = nil
    var trail: [V2] = []
    var lastBump: Float = -10
    var maneuver: (reverse: Float, turn: Float, dir: Float)? = nil

    // Path following.
    var path: [V2] = []
    var pathI = 0
    var waypointT: Float = 0
    var huntTarget: Item?
    var huntT: Float = 0
    var finishing = false
    var wasEmptyingMidRun = false
    var firstStop = true
    var clogEvents = 0
    var dockAligned = false
    var swallowing = 0

    weak var audio: SimAudio?
    var rng = SeededRNG(seed: 7)
    var tickBudget: Float = 0
    var onDoneOnce: (() -> Void)?

    init(size: V2, visibleMin: V2, visibleMax: V2, entries: [DesktopEntry]) {
        self.size = size
        wall = (visibleMin, visibleMax)
        items = entries.enumerated().map { Item(index: $0.offset, entry: $0.element) }
        totalBytes = entries.reduce(0) { $0 + $1.bytes }
        // Docked centre: tower's back rests against the bottom wall.
        let dx = Sim.bestDockX(items: items, width: size.x)
        dockPos = V2(dx, visibleMax.y - R * 2.08 - 6)
        pos = dockPos
        heading = -.pi / 2
        binCapacity = items.count > 40 ? Int(ceil(Float(items.count) * 0.55)) : items.count + 1
        particles.reserveCapacity(2500)
        speedScale = 1 + min(Float(items.count) / 300, 0.45)
    }

    /// Puts the dock on the emptiest stretch of the bottom wall, near the middle.
    static func bestDockX(items: [Item], width: Float) -> Float {
        var best = width / 2, bestScore = Float.infinity
        var x: Float = 300
        while x < width - 300 {
            var score = abs(x - width / 2) * 0.002
            for it in items where abs(it.home.x - x) < 170 { score += 1 }
            if score < bestScore { bestScore = score; best = x }
            x += 60
        }
        return best
    }

    var fwd: V2 { V2(cos(heading), sin(heading)) }
    var side: V2 { fwd.perp }
    var intake: V2 { pos + fwd * (R * 0.80) }
    var brushCenters: (V2, V2) {
        let a = fwd * (R * 0.62)
        return (pos + a + side * (R * 0.72), pos + a - side * (R * 0.72))
    }
    var remaining: Int { items.filter { !$0.protected && !$0.icon.gone && !$0.inBin && !$0.inDock }.count }

    func rand(_ a: Float = 0, _ b: Float = 1) -> Float { a + (b - a) * Float.random(in: 0...1, using: &rng) }

    func setPhase(_ p: Phase) { phase = p; phaseT = 0 }

    // MARK: - Step

    func step(_ dt: Float) {
        t += dt
        if paused {
            brushSpeed *= exp(-dt * 6); v = 0; w = 0
            audio?.setMotor(level: 0.04, load: 0)
            status = "Paused"
            return
        }
        phaseT += dt
        if ![.done, .tidied, .finished].contains(phase) { runTime += dt }
        updatePhase(dt)
        integrateRobot(dt)
        updateItems(dt)
        updateParticles(dt)
        heavy *= exp(-dt * 3)
        bumper *= exp(-dt * 7)
        shake *= exp(-dt * 8)
        bagGlow *= exp(-dt * 2)
        if draining {
            bagFill = max(0, bagFill - dt / 1.4)
            bagGlow = 1
            shake = max(shake, 0.08)
            if bagFill <= 0 {
                draining = false
                audio?.setRoar(0)
                if discarded == .delete { audio?.thud(0.7); audio?.chirp([(392, 0.12), (262, 0.22)]) }
                else { audio?.chirp([(659, 0.08), (523, 0.16)]) }
            }
        }
        ledPulse += dt
        let suck = suctionOn
        brushAngle += brushSpeed * dt
        lidarAngle += lidarSpeed * dt
        brushSpeed += ((suck ? 26 : 0) * (1 - heavy * 0.7) - brushSpeed) * min(1, dt * 3)
        lidarSpeed += ((phase == .dropping || phase == .done || phase == .tidied ? 0 : 16) - lidarSpeed) * min(1, dt * 2)
        let level: Float = suck ? 1 : ([.undocking, .scanning, .returning, .docking].contains(phase) ? 0.3 : 0)
        audio?.setMotor(level: picked ? level * 0.6 : level, load: heavy)
        battery = clampf(battery - (suck ? 0.0016 : 0) * dt, 0, 1)
        if phase == .emptying || phase == .done { battery = min(1, battery + dt * 0.01) }
    }

    var suctionOn: Bool { [.cleaning, .hunting].contains(phase) || (phase == .returning && !finishing && remaining > 0) }

    // MARK: - Phases

    func updatePhase(_ dt: Float) {
        switch phase {
        case .dropping:
            status = "Setting down"
            dockDrop = min(1, phaseT / 0.42)
            if phaseT >= 0.42 && phaseT - dt < 0.42 { landDock() }
            if phaseT > 1.3 {
                audio?.chirp([(659, 0.09), (880, 0.09), (1175, 0.16)])
                setPhase(.undocking)
            }
        case .undocking:
            status = wasEmptyingMidRun ? "Back to work" : "Leaving the dock"
            driveRaw(v: 150 * speedScale, w: 0, dt)
            if (pos - dockPos).len > R * 1.9 {
                if wasEmptyingMidRun || !firstStop { wasEmptyingMidRun = false; beginCleaning() }
                else { setPhase(.scanning) }
                firstStop = false
            }
        case .scanning:
            status = "Mapping your desktop"
            scanActive = min(1, scanActive + dt * 3)
            let rate: Float = 2.1
            driveRaw(v: 0, w: rate, dt)
            let prev = scanSweep
            scanSweep += rate * dt
            for it in items where !it.seen {
                let d = it.icon.pos - pos
                var a = atan2(d.y, d.x) - (-.pi / 2)
                while a < 0 { a += 2 * .pi }
                if a <= scanSweep && a > prev - 0.001 {
                    it.seen = true; it.ping = 1
                    tickBudget += 0.3
                }
            }
            if tickBudget > 1 { tickBudget = 0; audio?.tick() }
            if scanSweep > 2 * .pi {
                for it in items where !it.seen { it.seen = true; it.ping = 1 }
                audio?.chirp([(880, 0.08), (1319, 0.14)])
                beginCleaning()
            }
        case .cleaning:
            scanActive = max(0, scanActive - dt * 2)
            status = heavy > 0.35 ? "Big file. Straining…" : "Cleaning"
            followPath(dt)
            if binCount >= binCapacity && remaining > 0 { goDock(mid: true); break }
            if pathI >= path.count {
                if remaining == 0 { goDock(mid: false) } else { setPhase(.hunting); huntTarget = nil }
            }
        case .hunting:
            status = "Picking up stragglers"
            if binCount >= binCapacity && remaining > 0 { goDock(mid: true); break }
            if huntTarget == nil || huntTarget!.icon.gone || huntTarget!.icon.ingesting {
                huntTarget = nearestRemaining()
                huntT = 0
                if let h = huntTarget { path = [clampToWalk(h.icon.pos)]; pathI = 0 }
                else { goDock(mid: false); break }
            }
            huntT += dt
            if let h = huntTarget {
                path = [clampToWalk(h.icon.pos)]; pathI = 0
                // Something wedged out of reach: reel it in from a distance rather than circle forever.
                if huntT > 7 { startIngest(h, body: \.icon) }
            }
            followPath(dt)
        case .returning:
            status = finishing ? "Heading home" : "Bin full, heading to the dock"
            led = SIMD3(1, 0.68, 0.2)
            followPath(dt)
            if pathI >= path.count { setPhase(.docking); audio?.chirp([(740, 0.08), (587, 0.12)]) }
        case .docking:
            status = "Reversing onto the dock"
            let out = atan2(dockOut.y, dockOut.x)
            let along = (pos - dockPos).dot(dockOut)
            // Tail points at the dock while far out, straightens as it arrives.
            let toDock = dockPos - pos
            let aimTail = atan2(-toDock.y, -toDock.x)
            let want = along > R * 0.7 ? aimTail : out
            let err = wrapAngle(want - heading)
            if !dockAligned {
                driveRaw(v: 0, w: clampf(err * 3.0, -2.2, 2.2), dt)
                if abs(err) < 0.06 { dockAligned = true }
            } else {
                driveRaw(v: -clampf(along * 1.5 + 34, 34, 135) * speedScale, w: clampf(err * 2.6, -0.9, 0.9), dt)
                // Last centimetres: the ramp's guide rails centre it.
                if along < R * 0.5 {
                    let lateral = (pos - dockPos).dot(dockOut.perp)
                    pos -= dockOut.perp * (lateral * min(1, dt * 5))
                }
                if along <= 0.5 {
                    pos = dockPos; heading = out; v = 0; w = 0
                    dockAligned = false
                    shake = 0.35; audio?.thud(0.35)
                    audio?.chirp([(523, 0.09), (659, 0.09), (784, 0.09), (1047, 0.2)])
                    led = SIMD3(0.35, 1, 0.5)
                    setPhase(.emptying)
                    prepareEmptying()
                }
            }
        case .emptying:
            status = "Self-emptying"
            let roarOn = phaseT > 0.7 && phaseT < emptyDuration + 0.7
            audio?.setRoar(roarOn ? 1 : 0)
            if roarOn { shake = max(shake, 0.09); bagGlow = 1 }
            if phaseT > 0.7 { flyEmptying(dt) }
            if phaseT > emptyDuration + 1.6 {
                if finishing {
                    audio?.chirp([(784, 0.1), (988, 0.1), (1175, 0.1), (1568, 0.3)])
                    setPhase(.done)
                    onDoneOnce?(); onDoneOnce = nil
                    if mode == .tidy { startTidy() }
                    else if skipFinalClick { discard(mode) }
                } else {
                    led = SIMD3(0.2, 0.85, 1)
                    wasEmptyingMidRun = true
                    audio?.chirp([(659, 0.09), (880, 0.14)])
                    setPhase(.undocking)
                }
            }
        case .done:
            status = discarded == nil ? "All clean" : doneStatus
        case .tidying:
            status = "Sorting into columns"
            if phaseT > 3.8 { setPhase(.tidied) }
        case .tidied:
            status = "Tidy-up preview"
        case .puttingBack:
            status = "Putting everything back"
            if phaseT > 2.4 { audio?.setRoar(0) }
            if phaseT > 3.9 {
                setPhase(.leaving)
                audio?.chirp([(1047, 0.08), (784, 0.08), (523, 0.14)])
            }
        case .leaving:
            status = "Everything's back"
            let k = clampf(phaseT / 0.5, 0, 1)
            dockAlpha = 1 - k; robotAlpha = 1 - k
            if phaseT > 0.6 { setPhase(.finished) }
        case .finished:
            break
        }
    }

    func landDock() {
        audio?.thud(1)
        shake = 1
        // The air it pushes out shoves nearby icons away.
        for it in items {
            let d = it.icon.pos - (dockPos + dockOut * (-R * 0.5))
            let l = d.len
            if l < R * 3.4 {
                let k = 1 - l / (R * 3.4)
                it.icon.vel += d.unit * (520 * k * k) / it.mass
                it.icon.angV += rand(-5, 5) * k
                it.icon.agit = max(it.icon.agit, k)
            }
        }
        for _ in 0..<70 {
            let a = rand(0, 6.283)
            let p = dockPos + V2(cos(a) * R * 1.3, sin(a) * R * 1.0)
            spawn(p, V2(cos(a), sin(a)) * rand(120, 420), life: rand(0.3, 0.8), size: rand(1.5, 4), color: SIMD4(1, 1, 1, 0.3), chip: 0)
        }
    }

    func beginCleaning() {
        led = SIMD3(0.2, 0.85, 1)
        planLanes()
        setPhase(.cleaning)
    }

    func goDock(mid: Bool) {
        finishing = !mid
        if !mid { huntTarget = nil }
        path = [dockPos + dockOut * (R * 3.0)]
        pathI = 0
        setPhase(.returning)
    }

    func nearestRemaining() -> Item? {
        var best: Item?; var bd = Float.infinity
        for it in items where it.onFloor && !it.icon.ingesting && !it.grabbed {
            let d = (it.icon.pos - pos).len
            if d < bd { bd = d; best = it }
        }
        return best
    }

    func clampToWalk(_ p: V2) -> V2 {
        V2(clampf(p.x, wall.min.x + R + 2, wall.max.x - R - 2), clampf(p.y, wall.min.y + R + 2, wall.max.y - R - 2))
    }

    /// Lawn-mower rows over where the mess actually is, starting from the nearest end.
    func planLanes() {
        let live = items.filter { $0.onFloor }.map { $0.icon.pos }
        path = []; pathI = 0
        guard !live.isEmpty else { return }
        let step = R * 1.6
        let minY = max(live.map(\.y).min()!, wall.min.y + R + 2)
        let maxY = min(live.map(\.y).max()!, wall.max.y - R - 2)
        var lanes: [(y: Float, a: Float, b: Float)] = []
        var y = minY
        while y <= maxY + step * 0.5 {
            let yy = min(y, maxY)
            let band = live.filter { abs($0.y - yy) < step * 0.62 }.map(\.x)
            if let lo = band.min(), let hi = band.max() { lanes.append((yy, lo - R * 0.5, hi + R * 0.5)) }
            y += step
        }
        if abs((lanes.first?.y ?? 0) - pos.y) > abs((lanes.last?.y ?? 0) - pos.y) { lanes.reverse() }
        var x = pos.x
        for l in lanes {
            let near = abs(l.a - x) < abs(l.b - x) ? l.a : l.b
            let far = near == l.a ? l.b : l.a
            for p in [V2(near, l.y), V2(far, l.y)] {
                let q = clampToWalk(p)
                if !insideKeepOut(q) { path.append(q) }
            }
            x = far
        }
        waypointT = 0
    }

    func insideKeepOut(_ p: V2) -> Bool {
        let d = p - dockPos
        let u = d.dot(dockOut), s = abs(d.dot(dockOut.perp))
        return u < R * 2.0 && s < R * 2.3
    }

    /// Slides the robot along the dock's outline so it never drives over it.
    func pushOutOfDock() {
        guard insideKeepOut(pos) else { return }
        let d = pos - dockPos
        let u = d.dot(dockOut), s = d.dot(dockOut.perp)
        let toFront = R * 2.0 - u, toSide = R * 2.3 - abs(s)
        if toFront < toSide { pos += dockOut * toFront }
        else { pos += dockOut.perp * (s < 0 ? -toSide : toSide) }
    }

    // MARK: - Motion

    func followPath(_ dt: Float) {
        guard pathI < path.count else { driveRaw(v: 0, w: 0, dt); return }
        // Mouse in the way: bump, back off, swing round, like a real one meeting a foot.
        if let m = maneuver {
            driveRaw(v: m.reverse > 0 ? -110 : 0, w: m.reverse > 0 ? 0 : m.dir * 2.6, dt)
            var n = m
            if n.reverse > 0 { n.reverse -= dt } else { n.turn -= dt }
            maneuver = n.turn > 0 ? n : nil
            return
        }
        if let mp = mouse {
            let d = mp - pos, l = d.len
            if l < R + 20 && d.dot(fwd) > 0 && t - lastBump > 1.2 {
                lastBump = t
                bumper = 1; audio?.thud(0.3); audio?.chirp([(494, 0.07), (392, 0.09)])
                maneuver = (0.32, 0.45, d.dot(side) > 0 ? -1 : 1)
                return
            }
        }
        var target = path[pathI]
        waypointT += dt
        let reach = pathI == path.count - 1 ? R * 0.28 : R * 0.45
        if (target - pos).len < reach || waypointT > 14 {
            pathI += 1; waypointT = 0
            if pathI >= path.count { return }
            target = path[pathI]
        }
        // Carrot: blend towards the next waypoint when close, which rounds the corners.
        let toT = target - pos
        var aim = target
        if pathI + 1 < path.count, toT.len < R * 1.4 {
            let k = 1 - toT.len / (R * 1.4)
            aim = target + (path[pathI + 1] - target).unit * (R * 0.9 * k)
        }
        let err = wrapAngle(atan2(aim.y - pos.y, aim.x - pos.x) - heading)
        let wCmd = clampf(err * 4.2, -3.1, 3.1)
        let align = clampf(1 - abs(err) / 1.15, 0, 1)
        var vCmd = 360 * align * align
        if swallowing > 0 { vCmd *= max(0.38, 1 - 0.22 * Float(swallowing)) }
        if pathI == path.count - 1 { vCmd = min(vCmd, max(70, toT.len * 2.2)) }
        vCmd *= 1 - 0.68 * clampf(heavy, 0, 1)
        driveRaw(v: vCmd * speedScale, w: wCmd, dt)
    }

    func driveRaw(v vCmd: Float, w wCmd: Float, _ dt: Float) {
        let a: Float = 720 * speedScale
        v += clampf(vCmd - v, -a * dt, a * dt)
        let aw: Float = 12
        w += clampf(wCmd - w, -aw * dt, aw * dt)
    }

    func integrateRobot(_ dt: Float) {
        if picked { v = 0; w = 0; return }
        heading = wrapAngle(heading + w * dt)
        let before = pos
        pos += fwd * (v * dt)
        distance += abs(v * dt)
        // Walls: bumper compresses, a small knock.
        let walled = clampToWalk(pos)
        if phase == .cleaning || phase == .hunting || phase == .returning {
            if (walled - pos).len > 0.3 {
                if t - lastBump > 0.9 && abs(v) > 90 {
                    lastBump = t; bumper = 0.8; audio?.thud(0.16); v *= 0.4
                }
                pos = walled
            }
            pushOutOfDock()
        }
        if trail.isEmpty || (pos - trail.last!).len > 26 { trail.append(pos); if trail.count > 1600 { trail.removeFirst(200) } }
        _ = before
    }

    // MARK: - Items

    func startIngest(_ it: Item, body kp: ReferenceWritableKeyPath<Item, Body>) {
        if it[keyPath: kp].ingesting || it.protected { return }
        it[keyPath: kp].ingesting = true
        it[keyPath: kp].pull = 0.001
        if kp == \Item.icon {
            if it.labelAttached { detachLabel(it) }
            audio?.ingest(mass: it.mass)
            if it.mass > 3.4 { clogEvents += 1 }
            let c = it.color
            for _ in 0..<(6 + Int(it.mass * 4)) {
                let dir = (intake - it.icon.pos).unit.rotated(rand(-1.2, 1.2))
                spawn(it.icon.pos + V2(rand(-24, 24), rand(-24, 24)), dir * rand(80, 300), life: rand(0.2, 0.5), size: rand(2, 5),
                      color: SIMD4(c.x, c.y, c.z, 0.95), chip: 1)
            }
        }
    }

    func detachLabel(_ it: Item) {
        it.labelAttached = false
        it.label.pos = it.icon.pos + V2(0, Item.labelOffset).rotated(it.icon.ang)
        it.label.vel = it.icon.vel
        it.label.ang = it.icon.ang
        it.label.angV = rand(-5, 5)
    }

    func applyField(_ b: inout Body, mass: Float, on: Bool, dt: Float) -> Bool {
        let rel = b.pos - pos
        let f = rel.dot(fwd), s = rel.dot(side)
        let toIntake = intake - b.pos
        let d = toIntake.len
        var touched = false
        if on {
            // Suction: only reaches forward, and falls off fast.
            let reach = R * 2.5
            if d < reach {
                let k = 1 - d / reach
                let front = smooth(-R * 0.3, R * 0.5, f)
                let accel = 3300 * k * k * (0.2 + 0.8 * front) / mass
                b.vel += toIntake.unit * accel * dt
                b.agit = max(b.agit, k * front * 1.15)
                touched = k * front > 0.04
            }
            // Side brushes whirl things across the front of the robot and inwards.
            let (l, r) = brushCenters
            for (c, sign) in [(l, Float(-1)), (r, Float(1))] {
                let e = b.pos - c, el = e.len
                let br = R * 0.62
                if el < br {
                    let k = 1 - el / br
                    let tangent = e.unit.perp * sign
                    b.vel += (tangent * 1300 + (intake - b.pos).unit * 800) * k * dt / mass
                    b.angV += sign * 14 * k * dt / mass * 6
                    b.agit = max(b.agit, 0.5 + k * 0.5)
                    touched = true
                }
            }
        }
        // Robot body: shoves what it doesn't swallow.
        if !picked {
            let l = rel.len
            let keep = R + 16
            if on && f > R * 0.1 && abs(s) < R * 0.98 && l < R + 44 { return true }  // into the intake
            if l < keep {
                let n = rel.unit
                b.pos = pos + n * keep
                let vr = (fwd * v).dot(n)
                if vr > 0 { b.vel += n * vr * 1.1 }
                b.angV += n.perp.dot(fwd) * v * 0.012
                b.agit = max(b.agit, 0.5)
            }
        }
        _ = touched
        return false
    }

    func updateItems(_ dt: Float) {
        let on = suctionOn
        var awake: [Int] = []
        swallowing = items.reduce(0) { $0 + ($1.icon.ingesting ? 1 : 0) }
        for it in items {
            it.ping = max(0, it.ping - dt * 1.3)
            it.land = max(0, it.land - dt * 4)
            if it.flight != .none { updateFlight(it, dt); continue }
            if it.inBin || it.inDock { continue }
            if it.protected {
                // Not for collecting: can be nudged by the robot, but always settles back on its spot.
                _ = applyField(&it.icon, mass: it.mass, on: false, dt: dt)
                it.icon.vel += (it.home - it.icon.pos) * 26 * dt
                integrate(&it.icon, dt, damping: 7, mass: it.mass)
                continue
            }
            // ICON
            if !it.icon.gone {
                if it.grabbed {
                    it.icon.agit = max(it.icon.agit, 0.25)
                } else if it.icon.ingesting {
                    advanceIngest(it, body: \.icon, duration: it.ingestTime, dt)
                    heavy = max(heavy, clampf((it.mass - 1.8) / 3.2, 0, 1))
                    if it.mass > 3 { shake = max(shake, 0.28 * it.mass / 6) }
                    if it.icon.gone {
                        it.inBin = true; binCount += 1; binBytes += it.entry.bytes
                        collected += 1; collectedBytes += it.entry.bytes
                        if it.mass > 3 { audio?.chirp([(392, 0.05)]) }
                    }
                } else {
                    if applyField(&it.icon, mass: it.mass, on: on, dt: dt) { startIngest(it, body: \.icon) }
                    integrate(&it.icon, dt, damping: 5.5, mass: it.mass)
                    pushOutOfDockItem(&it.icon)
                    clampItem(&it.icon, pad: 26)
                }
                if it.icon.agit > 0.02 { awake.append(it.index) }
            }
            // LABEL
            if it.labelAttached {
                if it.icon.agit > 0.62 + 0.25 * sin(it.icon.seed * 13) { detachLabel(it) }
            }
            if !it.labelAttached && !it.label.gone {
                if it.label.ingesting {
                    advanceIngest(it, body: \.label, duration: 0.3, dt)
                } else {
                    if applyField(&it.label, mass: 0.32, on: on, dt: dt) { startIngest(it, body: \.label) }
                    if it.icon.gone {
                        // Its icon is gone: a label left behind flutters a bit, then gets taken.
                        it.labelLost += dt
                        if it.labelLost > 0.8 || (intake - it.label.pos).len < R * 2.6 { startIngest(it, body: \.label) }
                    }
                    integrate(&it.label, dt, damping: 3.6, mass: 0.32)
                    it.label.vel += V2(sin(t * 7 + it.label.seed), cos(t * 5.3 + it.label.seed * 2)) * 60 * it.label.agit * dt
                    clampItem(&it.label, pad: 30)
                }
            }
        }
        // Stirred-up icons shoulder each other aside; calm ones keep their exact spot.
        if awake.count > 1 && awake.count < 120 {
            for ii in 0..<awake.count {
                for jj in (ii + 1)..<awake.count {
                    let a = items[awake[ii]], b = items[awake[jj]]
                    if a.icon.ingesting || b.icon.ingesting || a.grabbed || b.grabbed { continue }
                    let d = b.icon.pos - a.icon.pos, l = d.len
                    if l < 54 && l > 0.01 {
                        let p = d.unit * ((54 - l) * 7 * dt)
                        a.icon.pos -= p / a.mass; b.icon.pos += p / b.mass
                    }
                }
            }
        }
    }

    func advanceIngest(_ it: Item, body kp: ReferenceWritableKeyPath<Item, Body>, duration: Float, _ dt: Float) {
        var b = it[keyPath: kp]
        b.pull = min(1, b.pull + dt / duration)
        let k = 1 - exp(-dt * (2.5 + 9 * b.pull * b.pull))
        b.pos += (intake - b.pos) * k
        b.agit = 1
        b.ang += b.angV * dt
        if b.pull >= 1 { b.gone = true; b.ingesting = false }
        it[keyPath: kp] = b
    }

    func integrate(_ b: inout Body, _ dt: Float, damping: Float, mass: Float) {
        b.pos += b.vel * dt
        b.vel *= exp(-dt * damping)
        b.ang += b.angV * dt
        b.angV *= exp(-dt * 3.2)
        // Paper settles flat again, keeping any new position.
        b.ang += (0 - b.ang) * (1 - exp(-dt * 0.6 * (1 - b.agit)))
        b.agit = max(0, b.agit - dt * 1.7)
    }

    func clampItem(_ b: inout Body, pad: Float) {
        if b.pos.x < pad { b.pos.x = pad; b.vel.x = abs(b.vel.x) * 0.4 }
        if b.pos.x > size.x - pad { b.pos.x = size.x - pad; b.vel.x = -abs(b.vel.x) * 0.4 }
        if b.pos.y < wall.min.y + pad { b.pos.y = wall.min.y + pad; b.vel.y = abs(b.vel.y) * 0.4 }
        if b.pos.y > wall.max.y - pad { b.pos.y = wall.max.y - pad; b.vel.y = -abs(b.vel.y) * 0.4 }
    }

    func pushOutOfDockItem(_ b: inout Body) {
        // Keep icons off the tower so nothing gets lost behind it.
        let d = b.pos - dockPos
        let u = d.dot(dockOut), s = d.dot(dockOut.perp)
        if u < R * 1.0 && u > -R * 2.3 && abs(s) < R * 1.45 {
            b.pos += dockOut * (R * 1.0 - u)
            b.vel += dockOut * 60
        }
    }

    // MARK: - Emptying and putting back

    var emptyDuration: Float = 3.6
    var bagPos: V2 { dockPos - dockOut * (R * 1.5) }
    var emptyQueue: [Item] = []
    var emptyAcc: Float = 0
    var emptyRate: Float = 1

    func prepareEmptying() {
        emptyQueue = items.filter { $0.inBin }
        emptyDuration = clampf(Float(emptyQueue.count) * 0.09, 2.2, 5)
        emptyRate = Float(emptyQueue.count) / (emptyDuration * 0.9)
        emptyAcc = 0
    }

    func flyEmptying(_ dt: Float) {
        guard !emptyQueue.isEmpty else { return }
        emptyAcc += dt * emptyRate
        while emptyAcc >= 1, let it = emptyQueue.popLast() {
            emptyAcc -= 1
            it.inBin = false
            it.flight = .toBag
            it.flightFrom = pos + V2(rand(-18, 18), rand(-18, 18))
            it.flightTo = bagPos + V2(rand(-R * 0.5, R * 0.5), rand(-R * 0.16, R * 0.16))
            it.flightT = 0; it.flightDelay = 0; it.flightDur = 0.42
            it.flightSpin = rand(-9, 9)
            it.flightScale = 0.34
            it.icon.gone = false; it.icon.pos = it.flightFrom; it.icon.pull = 0; it.icon.agit = 0; it.icon.ang = rand(-1, 1); it.icon.ingesting = false
        }
    }

    func updateFlight(_ it: Item, _ dt: Float) {
        if it.flightDelay > 0 { it.flightDelay -= dt; return }
        it.flightT = min(1, it.flightT + dt / it.flightDur)
        let k = it.flightT
        let e = it.flight == .toBag ? k * k : 1 - pow(1 - k, 3)
        var p = it.flightFrom + (it.flightTo - it.flightFrom) * e
        // Airborne arc, seen from above as a slight sideways bow.
        let bow = (it.flightTo - it.flightFrom).perp.unit * (sin(k * .pi) * min((it.flightTo - it.flightFrom).len * 0.12, 90) * (it.index % 2 == 0 ? 1 : -1))
        p += bow * (it.flight == .toBag ? 0 : 1)
        it.icon.pos = p
        switch it.flight {
        case .toBag:
            it.flightScale = 0.34 * (1 - k * 0.65)
            it.icon.ang += it.flightSpin * dt
            if k >= 1 {
                it.flight = .none; it.inDock = true; it.icon.gone = true
                binCount -= 1; binBytes -= it.entry.bytes
                bagFill = clampf(bagFill + 1 / Float(max(items.count, 1)), 0, 1)
                tickBudget += 0.45
                if tickBudget > 1 { tickBudget = 0; audio?.tick() }
            }
        case .toHome, .toTidy:
            it.flightScale = 0.18 + (1 - 0.18) * smooth(0, 0.8, k)
            it.icon.ang = it.flightSpin * (1 - e)
            if k >= 1 {
                it.flight = .none; it.inDock = false; it.inBin = false
                it.icon.pos = it.flightTo; it.icon.ang = 0; it.icon.vel = V2(0, 0); it.icon.gone = false; it.icon.agit = 0; it.icon.angV = 0
                it.labelAttached = true; it.label.gone = false; it.label.ingesting = false; it.label.pull = 0; it.labelLost = 0
                it.flightScale = 1; it.land = 1
                it.rest = it.flightTo
                tickBudget += 0.35
                if tickBudget > 1 { tickBudget = 0; audio?.tick() }
            }
        case .none: break
        }
    }

    /// Fans the same sprites out into columns by kind, against the right edge.
    func startTidy() {
        setPhase(.tidying)
        var slots: [(Item, V2)] = []
        let grouped = Kind.allCases.flatMap { k in items.filter { $0.entry.kind == k && !$0.protected } }
        let rows = max(1, Int((wall.max.y - wall.min.y - 60) / 104))
        let cols = (grouped.count + rows - 1) / rows
        // A very full desktop tightens the columns so that everything stays on screen.
        let pitch = min(126, (size.x - 144) / Float(max(cols - 1, 1)))
        for (i, it) in grouped.enumerated() {
            let col = i / rows, row = i % rows
            slots.append((it, V2(size.x - 72 - Float(col) * pitch, wall.min.y + 54 + Float(row) * 104)))
        }
        launch(slots, from: { _ in self.bagPos }, flight: .toTidy, spread: 3.0)
        audio?.setRoar(0)
    }

    var doneStatus: String {
        let tail = realRun ? "" : " (preview)"
        return (discarded == .delete ? "Deleted" : "Moved to Trash") + tail
    }

    /// The real action finished: anything left alone flies home, then the dock leaves.
    func finishAfterAction(returning list: [Item]) {
        draining = false
        bagFill = 0
        audio?.setRoar(0)
        if list.isEmpty { setPhase(.leaving); return }
        launch(list.map { ($0, $0.home) }, from: { _ in self.bagPos }, flight: .toHome, spread: 1.4)
        setPhase(.puttingBack)
    }

    /// Drains the bag for the chosen outcome. Only a picture of it: no file is touched.
    func discard(_ choice: CleanMode) {
        guard phase == .done, discarded == nil, choice == .trash || choice == .delete else { return }
        discarded = choice
        draining = true
        audio?.setRoar(0.7)
        status = doneStatus
    }

    func putBack() {
        guard phase == .done || phase == .tidied || phase == .tidying else { return }
        draining = false
        setPhase(.puttingBack)
        led = SIMD3(0.5, 0.75, 1)
        let tidied = items.contains { !$0.inDock && $0.flight == .none }
        let slots = items.map { ($0, $0.home) }
        launch(slots, from: { it in it.inDock ? self.bagPos : it.icon.pos }, flight: .toHome, spread: 2.9)
        _ = tidied
        audio?.setRoar(0.55)
        bagFill = 0
    }

    func launch(_ slots: [(Item, V2)], from: (Item) -> V2, flight: Flight, spread: Float) {
        let n = max(slots.count, 1)
        for (i, (it, to)) in slots.enumerated() {
            it.flightFrom = from(it)
            it.flight = flight
            it.flightTo = to
            it.icon.gone = false; it.icon.ingesting = false; it.icon.pos = it.flightFrom; it.icon.pull = 0; it.icon.agit = 0
            it.flightT = 0
            it.flightDelay = spread * 0.72 * Float(i) / Float(n)
            it.flightDur = 0.75 + rand(0, 0.25)
            it.flightSpin = rand(-2.5, 2.5)
            it.flightScale = 0.18
            it.labelAttached = true; it.label.gone = false; it.label.pull = 0; it.label.ingesting = false
        }
    }

    // MARK: - Pointer

    func hitRobot(_ p: V2) -> Bool { (p - pos).len < R && ![.docking, .emptying, .dropping, .puttingBack, .leaving].contains(phase) }

    func hitItem(_ p: V2) -> Item? {
        var best: Item?; var bd: Float = 40
        for it in items where it.onFloor {
            let d = (it.icon.pos - p).len
            if d < bd { bd = d; best = it }
        }
        return best
    }

    func pickUp() { picked = true; audio?.chirp([(988, 0.1), (784, 0.1), (988, 0.1), (784, 0.16)]); status = "Put me down!" }
    func drag(robotTo p: V2) { pos = clampToWalk(p) }
    func dropRobot() {
        picked = false; audio?.thud(0.55); shake = 0.6
        pushOutOfDock()
        if phase == .cleaning { planLanes(); phaseT = 0 }
    }

    // MARK: - Particles

    func spawn(_ p: V2, _ vel: V2, life: Float, size: Float, color: SIMD4<Float>, chip: Float) {
        if particles.count > 2300 { particles.removeFirst(100) }
        particles.append(Particle(pos: p, vel: vel, life: life, maxLife: life, size: size, color: color, chip: chip, ang: rand(0, 6.28)))
    }

    func updateParticles(_ dt: Float) {
        let on = suctionOn
        // Air the robot is drawing in, visible as a few fast specks.
        if on && !picked {
            let rate = 44 * dt
            var acc = rate + rand(0, 1)
            while acc >= 1 {
                acc -= 1
                let a = rand(-1.25, 1.25)
                let dir = fwd.rotated(a)
                let p = pos + dir * (R * rand(1.1, 1.95))
                spawn(p, -dir * rand(60, 140), life: rand(0.25, 0.5), size: rand(0.8, 2), color: SIMD4(1, 1, 1, 0.34), chip: 0)
            }
        }
        var i = 0
        while i < particles.count {
            particles[i].life -= dt
            if particles[i].life <= 0 { particles.swapAt(i, particles.count - 1); particles.removeLast(); continue }
            if on {
                let d = intake - particles[i].pos, l = d.len
                if l < R * 3 { particles[i].vel += d.unit * (2800 * (1 - l / (R * 3))) * dt }
                if l < R * 0.5 { particles[i].life = 0 }
            }
            particles[i].vel *= exp(-dt * 2.4)
            particles[i].pos += particles[i].vel * dt
            particles[i].ang += dt * 9 * particles[i].chip
            i += 1
        }
    }
}
