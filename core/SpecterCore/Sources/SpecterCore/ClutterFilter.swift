import Foundation

/// Per-bin exponential moving average of the static channel; output = frame - mean.
/// Double precision and ComplexD so it matches the Python reference and the pipeline.
public final class ClutterFilter {
    private let alpha: Double
    private var mu: [ComplexD]

    public init(alpha: Double = 0.98, n: Int = 512) {
        self.alpha = alpha
        self.mu = [ComplexD](repeating: ComplexD(0, 0), count: n)
    }

    public func update(frame: [ComplexD]) -> [ComplexD] {
        precondition(frame.count == mu.count, "frame length must equal n")
        var out = [ComplexD]()
        out.reserveCapacity(frame.count)
        for i in 0..<frame.count {
            mu[i] = mu[i] * alpha + frame[i] * (1.0 - alpha)
            out.append(frame[i] - mu[i])
        }
        return out
    }

    public func reset() {
        for i in 0..<mu.count { mu[i] = ComplexD(0, 0) }
    }
}