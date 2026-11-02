import AVFoundation
import os

/// Everything you hear is synthesised here: no audio files. Same code feeds the speakers and the video.
final class Synth: SimAudio {
    struct Voice { var kind: Int; var t: Float = 0; var dur: Float; var f0: Float; var f1: Float; var amp: Float; var delay: Float = 0; var lp: Float = 0; var lp2: Float = 0 }

    private var lock = os_unfair_lock()
    private var pending: [Voice] = []
    private var motorTarget: Float = 0, loadTarget: Float = 0, roarTarget: Float = 0
    var muted = false
    private var master: Float = 0.55

    // Audio-thread state.
    private var voices: [Voice] = []
    private var motor: Float = 0, load: Float = 0, roar: Float = 0
    private var phase: Float = 0, phase2: Float = 0, phase3: Float = 0
    private var lpA: Float = 0, lpB: Float = 0, lpC: Float = 0, hp: Float = 0
    private var flutter: Float = 0
    private var noise: UInt32 = 0x12345
    let sampleRate: Float = 48000

    private var engine: AVAudioEngine?

    func startLive() {
        let e = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            self.render(Int(frames), l, r)
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        try? e.start()
        engine = e
    }
    func stopLive() { engine?.stop(); engine = nil }

    private func enqueue(_ v: [Voice]) {
        os_unfair_lock_lock(&lock); pending.append(contentsOf: v); os_unfair_lock_unlock(&lock)
    }

    func setMotor(level: Float, load: Float) { motorTarget = level; loadTarget = load }
    func setRoar(_ level: Float) { roarTarget = level }
    func ingest(mass: Float) {
        let k = clampf((mass - 1) / 5, 0, 1)
        var v = [Voice(kind: 1, dur: 0.1 + 0.55 * k, f0: 3200 - 2200 * k, f1: 500 - 200 * k, amp: 0.30 + 0.28 * k)]
        // Debris rattling up the tube.
        let rattles = 2 + Int(k * 7)
        for i in 0..<rattles {
            v.append(Voice(kind: 2, dur: 0.03, f0: Float.random(in: 900...3400), f1: 0, amp: 0.10, delay: 0.05 + Float(i) * Float.random(in: 0.03...0.07)))
        }
        enqueue(v)
    }
    func tick() { enqueue([Voice(kind: 2, dur: 0.025, f0: Float.random(in: 1500...3800), f1: 0, amp: 0.09)]) }
    func chirp(_ notes: [(Float, Float)]) {
        var at: Float = 0
        var v: [Voice] = []
        for (f, d) in notes { v.append(Voice(kind: 0, dur: d + 0.12, f0: f, f1: f, amp: 0.15, delay: at)); at += d }
        enqueue(v)
    }
    func thud(_ a: Float) {
        enqueue([Voice(kind: 3, dur: 0.26, f0: 118, f1: 46, amp: 0.85 * a), Voice(kind: 1, dur: 0.09, f0: 1400, f1: 300, amp: 0.26 * a)])
    }

    @inline(__always) private func white() -> Float {
        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
        return Float(Int32(bitPattern: noise)) / 2147483648.0
    }

    func render(_ frames: Int, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>) {
        if os_unfair_lock_trylock(&lock) {
            if !pending.isEmpty { voices.append(contentsOf: pending); pending.removeAll(keepingCapacity: true) }
            if voices.count > 40 { voices.removeFirst(voices.count - 40) }
            os_unfair_lock_unlock(&lock)
        }
        let dt = 1 / sampleRate
        let twoPi = 2 * Float.pi
        for i in 0..<frames {
            motor += (motorTarget - motor) * 0.00006 * 6
            load += (loadTarget - load) * 0.0004
            roar += (roarTarget - roar) * 0.00012

            // Suction motor: a whine that sags when a heavy file jams the tube.
            let m = motor
            flutter += dt * 7.1
            let drift = 1 + 0.006 * sin(flutter * twoPi)
            let f = (96 + 34 * m - 26 * load) * drift
            phase += f * dt; if phase > 1 { phase -= 1 }
            phase2 += f * 2.02 * dt; if phase2 > 1 { phase2 -= 1 }
            phase3 += f * 5.97 * dt; if phase3 > 1 { phase3 -= 1 }
            let hum = sin(phase * twoPi) * 0.40 + sin(phase2 * twoPi) * 0.26 + sin(phase3 * twoPi) * 0.06

            // Moving air: filtered noise, brighter when flowing freely, duller under load.
            let n = white()
            let cutA = 0.035 + 0.07 * m - 0.05 * load
            lpA += (n - lpA) * max(cutA, 0.005)
            lpB += (lpA - lpB) * 0.5
            let air = lpB * 1.6

            // Self-empty blower: a much bigger, lower, rising rush.
            lpC += (n - lpC) * (0.03 + 0.10 * roar)
            let roarS = lpC * 2.6 * roar + sin(phase * twoPi * 0.5) * 0.25 * roar

            var s = (hum * 0.14 + air * 0.42) * m + roarS * 0.62

            var j = 0
            while j < voices.count {
                if voices[j].delay > 0 { voices[j].delay -= dt; j += 1; continue }
                let p = voices[j].t / voices[j].dur
                switch voices[j].kind {
                case 0: // chime
                    let env = min(1, voices[j].t * 180) * pow(1 - min(p, 1), 2.2)
                    s += sin(voices[j].t * voices[j].f0 * twoPi) * env * voices[j].amp
                    s += sin(voices[j].t * voices[j].f0 * 2 * twoPi) * env * voices[j].amp * 0.14
                case 1: // gulp: a noise burst closing down
                    let cf = voices[j].f0 + (voices[j].f1 - voices[j].f0) * p
                    let c = min(0.9, cf * twoPi / sampleRate)
                    voices[j].lp += (n - voices[j].lp) * c
                    let env = min(1, voices[j].t * 90) * pow(1 - min(p, 1), 1.5)
                    s += voices[j].lp * env * voices[j].amp * 1.6
                case 2: // tick: debris against plastic
                    let env = pow(1 - min(p, 1), 3)
                    s += sin(voices[j].t * voices[j].f0 * twoPi) * env * voices[j].amp
                case 3: // thud
                    let ff = voices[j].f1 + (voices[j].f0 - voices[j].f1) * pow(1 - min(p, 1), 3)
                    voices[j].lp += ff * dt
                    s += sin(voices[j].lp * twoPi) * pow(1 - min(p, 1), 2) * voices[j].amp
                default: break
                }
                voices[j].t += dt
                if voices[j].t >= voices[j].dur { voices.remove(at: j) } else { j += 1 }
            }
            let g: Float = muted ? 0 : master
            let out = tanh(s * 1.1) * g
            L[i] = out; R[i] = out
        }
    }
}
