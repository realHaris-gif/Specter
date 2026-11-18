import Foundation
import AVFoundation
import Combine
import os

// MARK: - Public types (unchanged API)

public struct ChirpConfig {
    public let fs: Double = 48000.0
    public let f0: Double = 18000.0
    public let f1: Double = 21000.0
    public let n: Int = 512
    public init() {}
}

public func makeChirp(c: ChirpConfig) -> [Double] {
    let n = c.n
    let fs = c.fs
    let f0 = c.f0
    let f1 = c.f1
    var chirp = [Double](repeating: 0.0, count: n)
    let T = Double(n) / fs
    let k = (f1 - f0) / T
    let taper = 0.1
    let L = max(1, Int(taper * Double(n) / 2.0))
    for i in 0..<n {
        let t = Double(i) / fs
        let phase = 2.0 * Double.pi * (f0 * t + 0.5 * k * t * t)
        let sample = sin(phase)
        var window = 1.0
        if i < L {
            window = 0.5 * (1.0 - cos(Double.pi * Double(i) / Double(L)))
        } else if i >= n - L {
            let dist = n - 1 - i
            window = 0.5 * (1.0 - cos(Double.pi * Double(dist) / Double(L)))
        }
        chirp[i] = sample * window
    }
    return chirp
}

public struct AnalysisResult {
    public let directBin: Int
    public let targetBin: Int
    public let rangeMeters: Double
    public let bpm: Double
    public let confidence: Double
    public let displacementMm: [Double]
}

public struct ComplexD {
    public var real: Double
    public var imag: Double
    public init(_ real: Double, _ imag: Double) {
        self.real = real; self.imag = imag
    }
    public var magnitude: Double { hypot(real, imag) }
    public var magnitudeSquared: Double { real * real + imag * imag }
    public var phase: Double { atan2(imag, real) }
    public static func +(lhs: ComplexD, rhs: ComplexD) -> ComplexD { ComplexD(lhs.real + rhs.real, lhs.imag + rhs.imag) }
    public static func -(lhs: ComplexD, rhs: ComplexD) -> ComplexD { ComplexD(lhs.real - rhs.real, lhs.imag - rhs.imag) }
    public static func *(lhs: ComplexD, rhs: Double) -> ComplexD { ComplexD(lhs.real * rhs, lhs.imag * rhs) }
}

public enum SensingState: String, CaseIterable {
    case calmBreathing = "Breathing"
    case motionDetected = "Movement"
    case breathHold = "Breath pause"
    case calibrating = "Learning"
    case quiet = "Quiet"
}

// MARK: - FFT (radix-2, any power of two)

fileprivate final class FFTPlan {
    let n: Int
    private let cosT: [Double]
    private let sinT: [Double]
    private let rev: [Int]

    init(n: Int) {
        precondition(n >= 2 && (n & (n - 1)) == 0, "FFT size must be a power of two")
        self.n = n
        var c = [Double](repeating: 0, count: n / 2)
        var s = [Double](repeating: 0, count: n / 2)
        for k in 0..<(n / 2) {
            let a = 2.0 * Double.pi * Double(k) / Double(n)
            c[k] = cos(a)
            s[k] = sin(a)
        }
        var bits = 0
        var t = n
        while t > 1 { t >>= 1; bits += 1 }
        var r = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var x = i
            var y = 0
            for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
            r[i] = y
        }
        cosT = c; sinT = s; rev = r
    }

    /// In-place transform. Inverse includes the 1/N scale (same as numpy.fft.ifft).
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        for i in 0..<n {
            let j = rev[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosT[k * step]
                    let wi = inverse ? sinT[k * step] : -sinT[k * step]
                    let a = start + k
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        if inverse {
            let s = 1.0 / Double(n)
            for i in 0..<n { re[i] *= s; im[i] *= s }
        }
    }
}

// MARK: - Small math helpers

fileprivate func detrended(_ d: [Double]) -> [Double] {
    let n = d.count
    guard n > 1 else { return d }
    let nd = Double(n)
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
    for i in 0..<n {
        let x = Double(i), y = d[i]
        sx += x; sy += y; sxx += x * x; sxy += x * y
    }
    let den = nd * sxx - sx * sx
    let slope = den != 0 ? (nd * sxy - sx * sy) / den : 0
    let icpt = (sy - slope * sx) / nd
    return (0..<n).map { d[$0] - (slope * Double($0) + icpt) }
}

fileprivate func peakToPeak(_ d: [Double]) -> Double {
    guard let lo = d.min(), let hi = d.max() else { return 0 }
    return hi - lo
}

fileprivate func nextPow2(_ v: Int) -> Int {
    var p = 2
    while p < v { p <<= 1 }
    return p
}

/// Kasa algebraic circle fit (Section 3.3 step 7). Normalised for numerical safety.
fileprivate func circleCenter(_ x: [Double], _ y: [Double]) -> (Double, Double) {
    let n = x.count
    guard n >= 3 else { return (x.first ?? 0, y.first ?? 0) }
    let nd = Double(n)
    var mx = 0.0, my = 0.0
    for i in 0..<n { mx += x[i]; my += y[i] }
    mx /= nd; my /= nd
    var v = 0.0
    for i in 0..<n {
        let dx = x[i] - mx, dy = y[i] - my
        v += dx * dx + dy * dy
    }
    let s = max((v / nd).squareRoot(), 1e-30)

    var sxx = 0.0, sxy = 0.0, sx = 0.0, syy = 0.0, sy = 0.0
    var b0 = 0.0, b1 = 0.0, b2 = 0.0
    for i in 0..<n {
        let u = (x[i] - mx) / s
        let w = (y[i] - my) / s
        let r = -(u * u + w * w)
        sxx += u * u; sxy += u * w; sx += u
        syy += w * w; sy += w
        b0 += u * r; b1 += w * r; b2 += r
    }
    let det = sxx * (syy * nd - sy * sy) - sxy * (sxy * nd - sy * sx) + sx * (sxy * sy - syy * sx)
    guard abs(det) > 1e-9 * nd * nd * nd else { return (mx, my) }
    let detD = b0 * (syy * nd - sy * sy) - sxy * (b1 * nd - sy * b2) + sx * (b1 * sy - syy * b2)
    let detE = sxx * (b1 * nd - sy * b2) - b0 * (sxy * nd - sy * sx) + sx * (sxy * b2 - b1 * sx)
    let D = detD / det
    let E = detE / det
    return (mx + s * (-D / 2), my + s * (-E / 2))
}

// MARK: - Sample store (audio tap -> DSP queue)

/// Preallocated Float ring. Short critical sections, no allocation after init.
fileprivate final class SampleStore {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var head = 0
    private var tail = 0
    private var used = 0

    init(capacity: Int) {
        let cap = max(1, capacity)
        let mem = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        mem.initialize(repeating: 0, count: cap)
        let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
        self.capacity = cap
        self.storage = mem
        self.lock = l
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var availableToRead: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return used
    }

    func reset() {
        os_unfair_lock_lock(lock)
        head = 0; tail = 0; used = 0
        os_unfair_lock_unlock(lock)
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        var src = data
        var remaining = count
        if remaining >= capacity {
            src += remaining - capacity
            remaining = capacity
            head = 0; tail = 0; used = 0
        }
        let free = capacity - used
        if remaining > free {
            let drop = remaining - free
            tail = (tail + drop) % capacity
            used -= drop
        }
        let stride = MemoryLayout<Float>.stride
        let first = min(remaining, capacity - head)
        memcpy(storage + head, src, first * stride)
        if remaining > first {
            memcpy(storage, src + first, (remaining - first) * stride)
        }
        head = (head + remaining) % capacity
        used += remaining
    }

    func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let n = min(count, used)
        guard n > 0 else { return 0 }
        let stride = MemoryLayout<Float>.stride
        let first = min(n, capacity - tail)
        memcpy(dest, storage + tail, first * stride)
        if n > first {
            memcpy(dest + first, storage, (n - first) * stride)
        }
        tail = (tail + n) % capacity
        used -= n
        return n
    }
}

// MARK: - Streaming sonar DSP (Section 3.3). Used on ONE queue only.

fileprivate struct BreathResult {
    var bpm: Double
    var conf: Double
    var targetBin: Int
    var rangeM: Double
    var disp: [Double]
}

fileprivate struct SonarUpdate {
    var state: SensingState
    var bpm: Double
    var confidence: Double
    var rangeMeters: Double
    var displacement: [Double]
    var message: String?
    var progress: Double
}

fileprivate final class StreamingSonar {
    static let histLen = 1875            // 20 s of slow time
    static let directFrames = 94         // 1 s to find the direct path
    static let minBreathFrames = 1400    // about 15 s before the first BPM
    static let hopFrames = 23            // update about 4x per second
    static let nearOffset = 42           // about 15 cm
    static let farOffset = 420           // about 1.5 m
    static let profileBins = 46
    static let binsPerCell = 9

    private let n: Int
    private let fs: Double
    private let carrier: Double
    private let m0: Int
    private let m1: Int
    private let fft: FFTPlan
    private var bigFFT: FFTPlan
    private let sRe: [Double]
    private let sIm: [Double]
    private let invNorm: Double

    // scratch + state
    private var re: [Double]
    private var im: [Double]
    private var muRe: [Double]
    private var muIm: [Double]
    private var dynRe: [Double]
    private var dynIm: [Double]
    private var energy: [Double]
    private var hpEnergy: [Double]
    private var sumMag: [Double]
    private var histRe: [Float]
    private var histIm: [Float]

    private(set) var frameCount = 0
    private(set) var directBin = 0
    private(set) var directLocked = false

    private let alpha = 0.98
    private let betaE = 1.0 - 1.0 / 281.0
    private let betaH = 1.0 - 1.0 / 28.0

    // motion detector
    private var settleUntil = 0
    private var hpSmooth = 0.0
    private var baselineSum = 0.0
    private var baselineCount = 0
    private var baseline = 0.0
    private var loudRun = 0
    private var quietRun = 0
    private var moving = false
    private var movingOffset = StreamingSonar.nearOffset
    private let baselineFrames = 469      // 5 s
    private let motionMultiplier = 6.0

    // breathing / pause
    private var ampBaseline = 0.0
    private var pauseRun = 0
    private var pausedUpdates = 0
    private var lastUpdateFrame = 0
    private let confThreshold = 0.25

    // waterfall scaling
    private var peakTrack = 0.0
    private var noiseEMA = 0.0

    init(config: ChirpConfig) {
        let n = config.n
        self.n = n
        self.fs = config.fs
        self.carrier = 0.5 * (config.f0 + config.f1)
        self.m0 = Int(ceil(config.f0 * Double(n) / config.fs))
        self.m1 = Int(floor(config.f1 * Double(n) / config.fs))
        let plan = FFTPlan(n: n)
        self.fft = plan
        self.bigFFT = FFTPlan(n: 16384)

        var cr = makeChirp(c: config)
        var ci = [Double](repeating: 0, count: n)
        plan.transform(&cr, &ci)
        var e = 0.0
        if m1 >= m0 {
            for m in m0...m1 { e += cr[m] * cr[m] + ci[m] * ci[m] }
        }
        self.sRe = cr
        self.sIm = ci
        self.invNorm = 1.0 / (e.squareRoot() + 1e-12)

        let z = [Double](repeating: 0, count: n)
        re = z; im = z; muRe = z; muIm = z; dynRe = z; dynIm = z
        energy = z; hpEnergy = z; sumMag = z
        histRe = [Float](repeating: 0, count: StreamingSonar.histLen * n)
        histIm = [Float](repeating: 0, count: StreamingSonar.histLen * n)
    }

    // MARK: per-frame

    func process(_ x: UnsafePointer<Float>) {
        for i in 0..<n { re[i] = Double(x[i]); im[i] = 0 }
        fft.transform(&re, &im)

        // Cross-spectrum restricted to the band (step 2)
        for m in 0..<n {
            if m >= m0 && m <= m1 {
                let a = re[m], b = im[m]
                re[m] = (a * sRe[m] + b * sIm[m]) * invNorm
                im[m] = (b * sRe[m] - a * sIm[m]) * invNorm
            } else {
                re[m] = 0; im[m] = 0
            }
        }
        fft.transform(&re, &im, inverse: true)      // h[n]: complex channel response (step 3)

        let row = (frameCount % StreamingSonar.histLen) * n
        for i in 0..<n {
            histRe[row + i] = Float(re[i])
            histIm[row + i] = Float(im[i])
        }

        if !directLocked {
            for i in 0..<n { sumMag[i] += hypot(re[i], im[i]) }
            if frameCount + 1 >= StreamingSonar.directFrames { lockDirectPath() }
        }

        // Static removal + energy trackers (steps 5, 6)
        let hasPrev = frameCount > 0
        for i in 0..<n {
            muRe[i] = alpha * muRe[i] + (1 - alpha) * re[i]
            muIm[i] = alpha * muIm[i] + (1 - alpha) * im[i]
            let dr = re[i] - muRe[i]
            let di = im[i] - muIm[i]
            energy[i] = betaE * energy[i] + (1 - betaE) * (dr * dr + di * di)
            if hasPrev {
                let pr = dr - dynRe[i]
                let pi_ = di - dynIm[i]
                hpEnergy[i] = betaH * hpEnergy[i] + (1 - betaH) * (pr * pr + pi_ * pi_)
            }
            dynRe[i] = dr
            dynIm[i] = di
        }

        if directLocked { updateMotion() }
        frameCount += 1
    }

    private func lockDirectPath() {
        var best = 0.0
        var idx = 0
        for i in 0..<n where sumMag[i] > best { best = sumMag[i]; idx = i }
        directBin = idx
        directLocked = true
        settleUntil = frameCount + 1 + 190
    }

    private func windowSum(_ a: [Double]) -> Double {
        var s = 0.0
        for off in StreamingSonar.nearOffset..<StreamingSonar.farOffset {
            s += a[(directBin + off) % n]
        }
        return s
    }

    private func updateMotion() {
        hpSmooth = 0.9 * hpSmooth + 0.1 * windowSum(hpEnergy)
        guard frameCount >= settleUntil else { return }

        if baselineCount < baselineFrames {
            baselineSum += hpSmooth
            baselineCount += 1
            if baselineCount == baselineFrames {
                baseline = max(baselineSum / Double(baselineCount), 1e-18)
            }
            return
        }

        let loud = hpSmooth > motionMultiplier * baseline
        if loud { loudRun += 1; quietRun = 0 } else { quietRun += 1; loudRun = 0 }
        if !moving && loudRun >= 47 { moving = true }          // 0.5 s
        if moving && quietRun >= 281 { moving = false }        // re-arm after 3 s
        if moving && loud && frameCount % 8 == 0 {
            var best = 0.0
            var bestOff = movingOffset
            for off in StreamingSonar.nearOffset..<StreamingSonar.farOffset {
                let v = hpEnergy[(directBin + off) % n]
                if v > best { best = v; bestOff = off }
            }
            movingOffset = bestOff
        }
    }

    // MARK: breathing (steps 6-8)

    func computeBreathing(minFrames: Int) -> BreathResult? {
        let avail = min(frameCount, StreamingSonar.histLen)
        guard directLocked, avail >= minFrames, avail >= 8 else { return nil }

        var best = -1.0
        var tgt = (directBin + StreamingSonar.nearOffset) % n
        for off in StreamingSonar.nearOffset..<StreamingSonar.farOffset {
            let idx = (directBin + off) % n
            if energy[idx] > best { best = energy[idx]; tgt = idx }
        }

        let L = avail
        var x = [Double](repeating: 0, count: L)
        var y = [Double](repeating: 0, count: L)
        for j in 0..<L {
            let frame = frameCount - L + j
            let o = (frame % StreamingSonar.histLen) * n + tgt
            x[j] = Double(histRe[o])
            y[j] = Double(histIm[o])
        }
        let (cx, cy) = circleCenter(x, y)

        let lam = SpecterPipeline.cSpeed / carrier
        var disp = [Double](repeating: 0, count: L)
        var last = atan2(y[0] - cy, x[0] - cx)
        var unwrapped = last
        disp[0] = -unwrapped * lam / (4 * Double.pi) * 1000.0
        if L > 1 {
            for j in 1..<L {
                let ph = atan2(y[j] - cy, x[j] - cx)
                var d = ph - last
                d -= 2 * Double.pi * (d / (2 * Double.pi)).rounded()
                unwrapped += d
                last = ph
                disp[j] = -unwrapped * lam / (4 * Double.pi) * 1000.0
            }
        }

        let (bpm, conf) = estimateBPM(disp)
        let rangeM = Double((tgt - directBin + n) % n) / fs * SpecterPipeline.cSpeed / 2.0
        return BreathResult(bpm: bpm, conf: conf, targetBin: tgt, rangeM: rangeM, disp: disp)
    }

    private func estimateBPM(_ d: [Double]) -> (Double, Double) {
        let L = d.count
        guard L > 8 else { return (0, 0) }
        let slowFs = fs / Double(n)
        let det = detrended(d)
        let nfft = nextPow2(8 * L)
        if bigFFT.n != nfft { bigFFT = FFTPlan(n: nfft) }
        var bre = [Double](repeating: 0, count: nfft)
        var bim = [Double](repeating: 0, count: nfft)
        for i in 0..<L {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(L - 1))
            bre[i] = det[i] * w
        }
        bigFFT.transform(&bre, &bim)

        let df = slowFs / Double(nfft)
        var wide = 0.0
        var bestP = 0.0
        var bestK = 0
        for k in 0...(nfft / 2) {
            let f = Double(k) * df
            let p = bre[k] * bre[k] + bim[k] * bim[k]
            if f >= 0.05 && f <= 1.5 { wide += p }
            if f >= 0.1 && f <= 0.7 && p > bestP { bestP = p; bestK = k }
        }
        guard bestP > 0 else { return (0, 0) }
        let fPeak = Double(bestK) * df
        var near = 0.0
        for k in 0...(nfft / 2) {
            let f = Double(k) * df
            if abs(f - fPeak) <= 0.04 { near += bre[k] * bre[k] + bim[k] * bim[k] }
        }
        return (60.0 * fPeak, min(1.0, near / (wide + 1e-18)))
    }

    // MARK: publishing

    func takeUpdateIfDue() -> SonarUpdate? {
        guard frameCount - lastUpdateFrame >= StreamingSonar.hopFrames else { return nil }
        lastUpdateFrame = frameCount
        return makeUpdate()
    }

    private func makeUpdate() -> SonarUpdate {
        let progress = min(1.0, Double(frameCount) / Double(StreamingSonar.minBreathFrames))
        guard directLocked, let r = computeBreathing(minFrames: StreamingSonar.minBreathFrames) else {
            return SonarUpdate(state: .calibrating, bpm: 0, confidence: 0, rangeMeters: 0,
                               displacement: [], message: "Learning the room. Keep still.",
                               progress: progress)
        }

        let det = detrended(r.disp)
        let ptp3 = peakToPeak(detrended(Array(r.disp.suffix(281))))   // last 3 s
        let breathing = r.conf >= confThreshold
        let recentStill = ampBaseline >= 0.8 && ptp3 < 0.25 * ampBaseline

        var state: SensingState
        var message: String? = nil
        if moving {
            state = .motionDetected
            pauseRun = 0
            message = "Movement near the phone."
        } else if recentStill {
            pauseRun += 1
            if pauseRun >= 20 {                       // about 5 s still + 3 s window
                state = .breathHold
                message = "Breath pause. Not a medical alert."
                pausedUpdates += 1
                if pausedUpdates > 120 { ampBaseline = 0; pausedUpdates = 0; pauseRun = 0 }
            } else {
                state = breathing ? .calmBreathing : .quiet
            }
        } else if breathing {
            ampBaseline = ampBaseline == 0 ? ptp3 : 0.85 * ampBaseline + 0.15 * ptp3
            pauseRun = 0
            pausedUpdates = 0
            state = .calmBreathing
        } else {
            pauseRun = 0
            state = .quiet
            message = "Signal faint. Move closer to the phone."
        }

        var shown: [Double] = []
        var i = det.count - 1
        while i >= 0 { shown.append(det[i]); i -= 9 }     // about 10 Hz
        shown.reverse()

        let rangeM = moving
            ? Double(movingOffset) / fs * SpecterPipeline.cSpeed / 2.0
            : r.rangeM

        return SonarUpdate(state: state,
                           bpm: state == .calmBreathing ? r.bpm : 0,
                           confidence: r.conf,
                           rangeMeters: rangeM,
                           displacement: shown,
                           message: message,
                           progress: 1.0)
    }

    /// Range-time column for the Veil: dynamic magnitude, near to far, 0...1.
    func makeProfile() -> [Float]? {
        guard directLocked else { return nil }
        let cells = StreamingSonar.profileBins
        let per = StreamingSonar.binsPerCell
        var raw = [Double](repeating: 0, count: cells)
        var overall = 0.0
        var sum = 0.0
        var cnt = 0.0
        for c in 0..<cells {
            var mx = 0.0
            for j in 0..<per {
                let idx = (directBin + c * per + j) % n
                let m = hypot(dynRe[idx], dynIm[idx])
                if m > mx { mx = m }
                sum += m; cnt += 1
            }
            raw[c] = mx
            if mx > overall { overall = mx }
        }
        let mean = sum / max(cnt, 1)
        noiseEMA = noiseEMA == 0 ? mean : 0.98 * noiseEMA + 0.02 * mean
        peakTrack = max(peakTrack * 0.997, overall, 4 * noiseEMA)
        let denom = max(peakTrack, 1e-30)
        return raw.map { Float(pow(min(1.0, $0 / denom), 0.7)) }
    }

    func finalResult() -> AnalysisResult {
        if !directLocked && frameCount > 0 { lockDirectPath() }
        guard let r = computeBreathing(minFrames: 64) else {
            return AnalysisResult(directBin: directBin, targetBin: directBin, rangeMeters: 0,
                                  bpm: 0, confidence: 0, displacementMm: [])
        }
        return AnalysisResult(directBin: directBin, targetBin: r.targetBin, rangeMeters: r.rangeM,
                              bpm: r.bpm, confidence: r.conf, displacementMm: r.disp)
    }
}

// MARK: - Offline pipeline (same API as before, now real)

public final class SpecterPipeline {
    public static let cSpeed = 343.0
    public let config: ChirpConfig

    public init(config: ChirpConfig = ChirpConfig()) {
        self.config = config
    }

    /// Runs the real DSP over a recording (matches the Python reference structure).
    public func analyze(samples: [Double]) -> AnalysisResult {
        let n = config.n
        let numFrames = samples.count / n
        guard numFrames > 0 else {
            return AnalysisResult(directBin: 0, targetBin: 0, rangeMeters: 0, bpm: 0, confidence: 0, displacementMm: [])
        }
        let sonar = StreamingSonar(config: config)
        var frame = [Float](repeating: 0, count: n)
        for k in 0..<numFrames {
            for i in 0..<n { frame[i] = Float(samples[k * n + i]) }
            frame.withUnsafeBufferPointer { sonar.process($0.baseAddress!) }
        }
        return sonar.finalResult()
    }
}

// MARK: - Engine

public final class SpecterEngine: ObservableObject {
    @Published public var sensingState: SensingState = .calibrating
    @Published public var currentBpm: Double = 0.0
    @Published public var currentRangeMeters: Double = 0.0
    @Published public var confidence: Double = 0.0
    @Published public var displacementHistory: [Double] = []
    @Published public var isRunning: Bool = false
    /// New: true while permission / audio start-up is in progress.
    @Published public var isStarting: Bool = false
    /// New: plain-language status or error (nil when fine).
    @Published public var statusMessage: String?
    /// New: 0...1 while the first ~15 s are being learned.
    @Published public var learningProgress: Double = 0.0

    /// New: range-time columns for the Veil, about 10 per second. A subject (not @Published)
    /// so it does not re-render the whole screen.
    public let profileSubject = PassthroughSubject<[Float], Never>()

    private let engine = AVAudioEngine()
    private let config = ChirpConfig()
    private let store = SampleStore(capacity: 48000 * 4)

    // Render-thread data: raw preallocated memory (no ARC/allocation in the callback).
    private let chirpTable: UnsafeMutablePointer<Float>
    private let tableCount: Int
    private let phasePtr: UnsafeMutablePointer<Int>

    private let audioQueue = DispatchQueue(label: "com.specter.audio", qos: .userInitiated)
    private let dspQueue = DispatchQueue(label: "com.specter.dsp", qos: .userInitiated)

    // audioQueue only
    private var sourceNode: AVAudioSourceNode?
    private var dspTimer: DispatchSourceTimer?

    // main only
    private var runID = 0
    private var observers: [NSObjectProtocol] = []

    public init() {
        let chirp = makeChirp(c: config)
        let n = max(1, chirp.count)
        let t = UnsafeMutablePointer<Float>.allocate(capacity: n)
        t.initialize(repeating: 0, count: n)
        for i in 0..<chirp.count { t[i] = Float(chirp[i] * 0.4) }
        let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        p.initialize(to: 0)
        chirpTable = t
        tableCount = n
        phasePtr = p
        registerObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        dspTimer?.cancel()
        engine.stop()
        chirpTable.deallocate()
        phasePtr.deallocate()
    }

    // MARK: start / stop (call from main thread)

    public func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        statusMessage = nil
        let id = runID

        requestMicPermission { [weak self] granted in
            guard let self = self else { return }
            guard self.runID == id else { self.isStarting = false; return }
            guard granted else {
                self.isStarting = false
                self.statusMessage = "Microphone access is off. Specter needs it to hear its own echoes. Enable it in Settings > Specter."
                return
            }
            // Audio session + engine start can take hundreds of ms: never on the main thread.
            self.audioQueue.async {
                let result: Result<Void, Error> = Result { try self.startAudio() }
                DispatchQueue.main.async {
                    self.isStarting = false
                    switch result {
                    case .success:
                        if self.runID == id {
                            self.isRunning = true
                        } else {
                            self.audioQueue.async { self.teardownAudio(deactivate: true) }
                        }
                    case .failure(let error):
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    public func stop() {
        guard isRunning || isStarting else { return }
        runID += 1
        isRunning = false
        isStarting = false
        sensingState = .calibrating
        currentBpm = 0
        currentRangeMeters = 0
        confidence = 0
        learningProgress = 0
        displacementHistory = []
        audioQueue.async { [weak self] in self?.teardownAudio(deactivate: true) }
    }

    // MARK: audio (audioQueue)

    private func fail(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "Specter", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func startAudio() throws {
        if sourceNode != nil || dspTimer != nil { teardownAudio(deactivate: false) }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(config.fs)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }

        guard abs(session.sampleRate - config.fs) < 1 else {
            let got = session.sampleRate
            try? session.setActive(false)
            throw fail(1, "Hardware sample rate must be 48 kHz. Got \(Int(got)) Hz. Disconnect Bluetooth audio and try again.")
        }

        // An invalid input format (permission denied, no mic) crashes installTap. Check first.
        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        guard inFmt.sampleRate == config.fs, inFmt.channelCount > 0 else {
            try? session.setActive(false)
            throw fail(2, "Microphone is not delivering 48 kHz audio (\(Int(inFmt.sampleRate)) Hz). Check permission and connected audio devices.")
        }

        store.reset()
        phasePtr.pointee = 0
        let sonar = StreamingSonar(config: config)

        let table = chirpTable
        let n = tableCount
        let phase = phasePtr
        let node = AVAudioSourceNode { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let first = list.first, let m0 = first.mData else { return noErr }
            let out = m0.assumingMemoryBound(to: Float.self)
            let count = Int(frames)
            var idx = phase.pointee
            for i in 0..<count {
                out[i] = table[idx]
                idx += 1
                if idx == n { idx = 0 }
            }
            phase.pointee = idx
            if list.count > 1 {
                for j in 1..<list.count {
                    if let m = list[j].mData { memcpy(m, m0, count * MemoryLayout<Float>.size) }
                }
            }
            return noErr
        }
        sourceNode = node
        let fmt = AVAudioFormat(standardFormatWithSampleRate: config.fs, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)

        let store = self.store
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            store.write(ch, count: Int(buffer.frameLength))
        }

        do {
            try engine.start()
        } catch {
            teardownAudio(deactivate: true)
            throw error
        }

        let timer = makeTimer(sonar: sonar, id: runIDSnapshot())
        dspTimer = timer
        timer.resume()
    }

    private func runIDSnapshot() -> Int {
        // runID is main-thread state; read it synchronously and safely.
        if Thread.isMainThread { return runID }
        return DispatchQueue.main.sync { runID }
    }

    private func teardownAudio(deactivate: Bool) {
        dspTimer?.cancel()
        dspTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)          // prevents nodes piling up across restarts
            sourceNode = nil
        }
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: DSP loop (dspQueue)

    private func makeTimer(sonar: StreamingSonar, id: Int) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: dspQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: .milliseconds(40), leeway: .milliseconds(5))
        let n = config.n
        var frame = [Float](repeating: 0, count: n)
        var lastProfile = 0.0

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            var budget = 64                              // never starve the queue after a hiccup
            while budget > 0, self.store.availableToRead >= n {
                budget -= 1
                let got = frame.withUnsafeMutableBufferPointer {
                    self.store.read(into: $0.baseAddress!, count: n)
                }
                if got == n {
                    frame.withUnsafeBufferPointer { sonar.process($0.baseAddress!) }
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProfile >= 0.1, let profile = sonar.makeProfile() {
                lastProfile = now
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.runID == id else { return }
                    self.profileSubject.send(profile)
                }
            }
            if let update = sonar.takeUpdateIfDue() {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.runID == id else { return }
                    self.apply(update)
                }
            }
        }
        return timer
    }

    private func apply(_ u: SonarUpdate) {
        sensingState = u.state
        currentBpm = u.bpm
        currentRangeMeters = u.rangeMeters
        confidence = u.confidence
        learningProgress = u.progress
        if !u.displacement.isEmpty { displacementHistory = u.displacement }
        statusMessage = u.message
    }

    // MARK: permission + interruptions

    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: finish)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(finish)
        }
    }

    private func registerObservers() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.stop()
            self.statusMessage = "Audio was interrupted. Tap the button to resume."
        })

        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.isRunning,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                self.stop()
                self.statusMessage = "Audio device changed. Tap the button to resume."
            }
        })

        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.stop()
            self.statusMessage = "Audio configuration changed. Tap the button to resume."
        })
    }
}