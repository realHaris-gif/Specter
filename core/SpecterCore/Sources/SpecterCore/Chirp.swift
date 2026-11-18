import Foundation
import Accelerate

public struct ChirpConfig {
    public var fs: Double = 48_000
    public var n: Int = 512
    public var f0: Double = 18_000
    public var f1: Double = 21_000
    public var taper: Double = 0.1
    public init() {}
}

public func makeChirp(c: ChirpConfig = ChirpConfig()) -> [Double] {
    let T = Double(c.n) / c.fs
    let k = (c.f1 - c.f0) / T
    let L = Int(c.taper * Double(c.n) / 2.0)
    var out = [Double](repeating: 0, count: c.n)
    for i in 0..<c.n {
        let t = Double(i) / c.fs
        var w = 1.0
        if i < L {
            w = 0.5 * (1.0 - cos(Double.pi * Double(i) / Double(L)))
        } else if i >= c.n - L {
            let j = c.n - 1 - i
            w = 0.5 * (1.0 - cos(Double.pi * Double(j) / Double(L)))
        }
        out[i] = sin(2.0 * Double.pi * (c.f0 * t + 0.5 * k * t * t)) * w
    }
    return out
}
