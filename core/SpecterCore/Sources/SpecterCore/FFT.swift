import Foundation
import Accelerate

public final class ComplexFFT {
    public let n: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetupD

    public init(n: Int = 512) {
        self.n = n
        self.log2n = vDSP_Length(log2(Double(n)))
        self.fftSetup = vDSP_create_fftsetupD(self.log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetupD(fftSetup)
    }

    public func forward(real: [Double], imag: [Double]? = nil) -> (real: [Double], imag: [Double]) {
        var r = real
        var i = imag ?? [Double](repeating: 0.0, count: n)
        r.withUnsafeMutableBufferPointer { rPtr in
            i.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPDoubleSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                vDSP_fft_zipD(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        return (r, i)
    }

    public func inverse(real: [Double], imag: [Double]) -> (real: [Double], imag: [Double]) {
        var r = real
        var i = imag
        r.withUnsafeMutableBufferPointer { rPtr in
            i.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPDoubleSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                vDSP_fft_zipD(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
            }
        }
        let scale = 1.0 / Double(n)          // vDSP inverse is unscaled; numpy ifft divides by n
        for idx in 0..<n { r[idx] *= scale; i[idx] *= scale }
        return (r, i)
    }
}