import Foundation

public struct AnalysisResult {
    public let directBin: Int
    public let targetBin: Int
    public let rangeMeters: Double
    public let bpm: Double
    public let confidence: Double
    public let displacementMm: [Double]
}

public final class SpecterPipeline {
    public static let cSpeed = 343.0
    public let config: ChirpConfig
    private let estimator: ChannelEstimator

    public init(config: ChirpConfig = ChirpConfig()) {
        self.config = config
        self.estimator = ChannelEstimator(config: config)
    }

    public func analyze(samples: [Double]) -> AnalysisResult {
        let n = config.n
        let numFrames = samples.count / n
        var h = [[ComplexD]]()
        h.reserveCapacity(numFrames)
        for k in 0..<numFrames {
            let start = k * n
            let frame = Array(samples[start..<(start + n)])
            h.append(estimator.estimate(frame: frame))
        }

        // 1. Static clutter removal (alpha = 0.98), same filter the live engine will use
        let clutter = ClutterFilter(alpha: 0.98, n: n)
        var dyn = [[ComplexD]]()
        dyn.reserveCapacity(numFrames)
        for k in 0..<numFrames { dyn.append(clutter.update(frame: h[k])) }

        // 2. Direct-path index
        var meanMag = [Double](repeating: 0, count: n)
        for k in 0..<numFrames {
            for bin in 0..<n { meanMag[bin] += h[k][bin].magnitude }
        }
        let nd = meanMag.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0

        // 3. Target bin search (last 281 frames, offset 42..<420)
        let win = min(281, numFrames)
        let segStart = numFrames - win
        var bestBin = (nd + 42) % n
        var bestEnergy = -1.0
        for off in 42..<420 {
            let idx = (nd + off) % n
            var energy = 0.0
            for k in segStart..<numFrames {
                energy += dyn[k][idx].magnitudeSquared
            }
            if energy > bestEnergy {
                bestEnergy = energy
                bestBin = idx
            }
        }

        // 4. Arc demodulation (last 1875 frames)
        let zWin = min(1875, numFrames)
        let z = (numFrames - zWin)..<numFrames
        let zSlice = z.map { h[$0][bestBin] }   // RAW h, as in the Python reference (not clutter-removed)
        let center = circleCenter(z: zSlice)
        let fc = 0.5 * (config.f0 + config.f1)
        let lam = Self.cSpeed / fc

        let rawAngles = zSlice.map { ($0 - center).phase }
        // Unwrap phase
        var unwrapped = [Double](repeating: 0, count: rawAngles.count)
        if !rawAngles.isEmpty {
            unwrapped[0] = rawAngles[0]
            for i in 1..<rawAngles.count {
                var diff = rawAngles[i] - rawAngles[i - 1]
                while diff > Double.pi { diff -= 2.0 * Double.pi }
                while diff < -Double.pi { diff += 2.0 * Double.pi }
                unwrapped[i] = unwrapped[i - 1] + diff
            }
        }
        let dispMm = unwrapped.map { -$0 * lam / (4.0 * Double.pi) * 1000.0 }

        // 5. BPM estimation
        let slowFs = config.fs / Double(n)
        let (bpm, conf) = estimateBPM(d: dispMm, fs: slowFs)
        let binDiff = ((bestBin - nd) % n + n) % n
        let rangeMeters = (Double(binDiff) / config.fs) * Self.cSpeed / 2.0

        return AnalysisResult(
            directBin: nd,
            targetBin: bestBin,
            rangeMeters: rangeMeters,
            bpm: bpm,
            confidence: conf,
            displacementMm: dispMm
        )
    }

    private func circleCenter(z: [ComplexD]) -> ComplexD {
        // Algebraic Kasa circle fit: solve A * [D, E, F]^T = b via normal equations
        var sXX = 0.0, sYY = 0.0, sXY = 0.0, sX = 0.0, sY = 0.0
        var sXb = 0.0, sYb = 0.0, sB = 0.0
        let count = Double(z.count)
        for p in z {
            let x = p.real, y = p.imag, b = x * x + y * y
            sXX += x * x; sYY += y * y; sXY += x * y
            sX += x; sY += y
            sXb += x * b; sYb += y * b; sB += b
        }
        // Gaussian elimination on 3x3 normal matrix
        var m = [
            [sXX, sXY, sX, sXb],
            [sXY, sYY, sY, sYb],
            [sX,  sY,  count, sB]
        ]
        for i in 0..<3 {
            var pivot = i
            for r in (i + 1)..<3 where abs(m[r][i]) > abs(m[pivot][i]) { pivot = r }
            m.swapAt(i, pivot)
            let div = m[i][i]
            guard abs(div) > 1e-18 else { continue }
            for c in i..<4 { m[i][c] /= div }
            for r in 0..<3 where r != i {
                let factor = m[r][i]
                for c in i..<4 { m[r][c] -= factor * m[i][c] }
            }
        }
        // b = +(x^2+y^2) solves x^2+y^2 = D x + E y + F, so the centre is (+D/2, +E/2)
        return ComplexD(m[0][3] / 2.0, m[1][3] / 2.0)
    }

    private func estimateBPM(d: [Double], fs: Double) -> (Double, Double) {
        let len = d.count
        guard len > 1 else { return (0, 0) }
        // Linear detrend
        let meanX = Double(len - 1) / 2.0
        let meanY = d.reduce(0, +) / Double(len)
        var num = 0.0, den = 0.0
        for i in 0..<len {
            let dx = Double(i) - meanX
            num += dx * (d[i] - meanY)
            den += dx * dx
        }
        let slope = den > 0 ? num / den : 0.0
        let intercept = meanY - slope * meanX

        // Apply Hann window
        var windowed = [Double](repeating: 0, count: len)
        for i in 0..<len {
            let detrended = d[i] - (slope * Double(i) + intercept)
            let hann = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(len - 1)))
            windowed[i] = detrended * hann
        }

        // Zero-padded power spectrum (8x)
        let nfft = len * 8
        let half = nfft / 2 + 1
        var bestK = 0
        var bestPower = -1.0
        var powers = [Double](repeating: 0, count: half)
        for k in 0..<half {
            let freq = Double(k) * fs / Double(nfft)
            if freq > 1.5 { break }
            if freq >= 0.05 {
                let omega = 2.0 * Double.pi * Double(k) / Double(nfft)
                var re = 0.0, im = 0.0
                for n in 0..<len {
                    let angle = omega * Double(n)
                    re += windowed[n] * cos(angle)
                    im -= windowed[n] * sin(angle)
                }
                let p = re * re + im * im
                powers[k] = p
                if freq >= 0.1 && freq <= 0.7 && p > bestPower {
                    bestPower = p
                    bestK = k
                }
            }
        }
        let bestFreq = Double(bestK) * fs / Double(nfft)
        var nearSum = 0.0, wideSum = 0.0
        for k in 0..<half {
            let freq = Double(k) * fs / Double(nfft)
            if freq >= 0.05 && freq <= 1.5 {
                wideSum += powers[k]
                if abs(freq - bestFreq) <= 0.04 { nearSum += powers[k] }
            }
        }
        return (60.0 * bestFreq, nearSum / (wideSum + 1e-18))
    }
}