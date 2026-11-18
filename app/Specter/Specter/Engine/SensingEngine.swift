import Foundation
import Combine

/// Thread-safe cancel flag so a stopped DSP loop really exits (the old `isProcessing` Bool was
/// never cleared and was shared across threads without protection).
private final class RunToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Same formula as the Python reference `make_chirp` (Section 3.2).
/// TODO: replace with SpecterCore.makeChirp once the package is linked into the app target.
private func makeReferenceChirp(f0: Double = 18_000, f1: Double = 21_000,
                                n: Int = 512, fs: Double = 48_000,
                                taper: Double = 0.1) -> [Double] {
    let T = Double(n) / fs
    let k = (f1 - f0) / T
    let L = Int(taper * Double(n) / 2.0)
    return (0..<n).map { i in
        let t = Double(i) / fs
        var w = 1.0
        if i < L {
            w = 0.5 * (1 - cos(Double.pi * Double(i) / Double(L)))
        } else if i >= n - L {
            w = 0.5 * (1 - cos(Double.pi * Double(n - 1 - i) / Double(L)))
        }
        return sin(2 * Double.pi * (f0 * t + 0.5 * k * t * t)) * w
    }
}

public final class SensingEngine: ObservableObject {
    @Published public var directPathIndex: Int = 0
    @Published public var isRunning: Bool = false
    @Published public var latestRangeProfile: [Float] = []
    /// Human-readable reason when the engine could not start or was stopped (nil when fine).
    @Published public var lastError: String?

    private let ringBuffer = RingBuffer(capacity: 65536)
    private var audioIO: AudioIO?
    private let dspQueue = DispatchQueue(label: "com.specter.dsp", qos: .userInitiated)
    private var token: RunToken?
    private var isStarting = false

    private static let uiInterval: TimeInterval = 1.0 / 30.0   // guide 4.3: UI gets 30 Hz, not 94 Hz

    public init() {}

    /// Call from the main thread.
    public func startEngine() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        lastError = nil

        AudioSessionManager.shared.requestMicrophonePermission { [weak self] granted in
            guard let self = self else { return }
            self.isStarting = false
            guard granted else {
                self.lastError = "Microphone access is off. Specter needs it to hear its own echoes. Enable it in Settings."
                return
            }
            self.beginEngine()
        }
    }

    /// Call from the main thread.
    public func stopEngine() {
        token?.cancel()
        token = nil
        audioIO?.stop()
        audioIO = nil
        ringBuffer.reset()
        isRunning = false
    }

    private func beginEngine() {
        // Stop cleanly on calls, Siri, AirPods connecting, etc. (guide 4.3).
        AudioSessionManager.shared.onInterruptionBegan = { [weak self] in
            self?.stopEngine()
            self?.lastError = "Audio was interrupted. Tap Start to resume."
        }
        AudioSessionManager.shared.onRouteChangeRequiringStop = { [weak self] reason in
            self?.stopEngine()
            self?.lastError = "\(reason). Tap Start to resume."
        }

        ringBuffer.reset()
        let io = AudioIO(ringBuffer: ringBuffer, chirp: makeReferenceChirp())
        do {
            try io.start()
        } catch {
            lastError = error.localizedDescription
            return
        }
        audioIO = io
        isRunning = true
        startProcessingLoop()
    }

    private func startProcessingLoop() {
        token?.cancel()                 // never allow two loops
        let myToken = RunToken()
        token = myToken
        let ring = ringBuffer

        dspQueue.async { [weak self] in
            var frameBuffer = [Float](repeating: 0, count: 512)
            var lastPublish: TimeInterval = 0

            while !myToken.isCancelled {
                // Only read when a whole frame is queued. The old code consumed partial reads and
                // discarded them, silently dropping samples and breaking frame continuity.
                guard ring.availableToRead >= 512,
                      ring.read(into: &frameBuffer, count: 512) == 512 else {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }

                // TODO(Stage 4/5): replace with SpecterCore channel estimate + clutter removal.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPublish >= SensingEngine.uiInterval {
                    lastPublish = now
                    let profile = (0..<128).map { abs(frameBuffer[$0 % 512]) }
                    DispatchQueue.main.async {
                        guard let self = self, !myToken.isCancelled else { return }
                        self.latestRangeProfile = profile
                    }
                }
            }
        }
    }
}