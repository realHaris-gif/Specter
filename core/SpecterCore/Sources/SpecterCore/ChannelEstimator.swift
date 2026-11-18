import Foundation

public struct ComplexD {
    public var real: Double
    public var imag: Double
    public init(_ real: Double, _ imag: Double) {
        self.real = real
        self.imag = imag
    }
    public var magnitude: Double { hypot(real, imag) }
    public var magnitudeSquared: Double { real * real + imag * imag }
    public var phase: Double { atan2(imag, real) }
    public static func +(lhs: ComplexD, rhs: ComplexD) -> ComplexD { ComplexD(lhs.real + rhs.real, lhs.imag + rhs.imag) }
    public static func -(lhs: ComplexD, rhs: ComplexD) -> ComplexD { ComplexD(lhs.real - rhs.real, lhs.imag - rhs.imag) }
    public static func *(lhs: ComplexD, rhs: Double) -> ComplexD { ComplexD(lhs.real * rhs, lhs.imag * rhs) }
}

public final class ChannelEstimator {
    public let config: ChirpConfig
    private let fft: ComplexFFT
    private let sReal: [Double]
    private let sImag: [Double]
    private let m0: Int
    private let m1: Int
    private let normFactor: Double

    public init(config: ChirpConfig = ChirpConfig()) {
        self.config = config
        self.fft = ComplexFFT(n: config.n)
        let chirp = makeChirp(c: config)
        let S = fft.forward(real: chirp)
        self.sReal = S.real
        self.sImag = S.imag
        self.m0 = Int(ceil(config.f0 * Double(config.n) / config.fs))
        self.m1 = Int(floor(config.f1 * Double(config.n) / config.fs))
        var energy = 0.0
        for m in m0...m1 {
            energy += sReal[m] * sReal[m] + sImag[m] * sImag[m]
        }
        self.normFactor = sqrt(energy) + 1e-12
    }

    public func estimate(frame: [Double]) -> [ComplexD] {
        let R = fft.forward(real: frame)
        var hReal = [Double](repeating: 0.0, count: config.n)
        var hImag = [Double](repeating: 0.0, count: config.n)
        for m in m0...m1 {
            // R[m] * conj(S[m])
            hReal[m] = R.real[m] * sReal[m] + R.imag[m] * sImag[m]
            hImag[m] = R.imag[m] * sReal[m] - R.real[m] * sImag[m]
        }
        let inv = fft.inverse(real: hReal, imag: hImag)
        return (0..<config.n).map { ComplexD(inv.real[$0] / normFactor, inv.imag[$0] / normFactor) }
    }
}
