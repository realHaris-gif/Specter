import AVFoundation

public final class AudioIO {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ringBuffer: RingBuffer

    // Render-thread state lives in raw preallocated memory: no Swift array access, no ARC, no
    // allocation inside the render callback.
    private let table: UnsafeMutablePointer<Float>
    private let tableCount: Int
    private let phase: UnsafeMutablePointer<Int>

    public private(set) var isRunning = false

    public init(ringBuffer: RingBuffer, chirp: [Double], gain: Float = 0.5) {
        self.ringBuffer = ringBuffer
        let n = max(1, chirp.count)
        let t = UnsafeMutablePointer<Float>.allocate(capacity: n)
        t.initialize(repeating: 0, count: n)
        for i in 0..<chirp.count { t[i] = Float(chirp[i]) * gain }   // output level applied once, here
        let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        p.initialize(to: 0)
        self.table = t
        self.tableCount = n
        self.phase = p
    }

    deinit {
        stop()
        table.deallocate()
        phase.deallocate()
    }

    public func start() throws {
        guard !isRunning else { return }
        try AudioSessionManager.shared.configureSession()

        // The mic must really deliver 48 kHz or the range axis is wrong.
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate == 48_000, inputFormat.channelCount > 0 else {
            AudioSessionManager.shared.deactivate()
            throw NSError(domain: "Specter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Microphone format is \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch. Need 48 kHz. Check microphone permission and connected audio devices."
            ])
        }

        let table = self.table
        let n = self.tableCount
        let phasePtr = self.phase
        phasePtr.pointee = 0

        let node = AVAudioSourceNode { _, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let first = list.first, let m0 = first.mData else { return noErr }
            let out0 = m0.assumingMemoryBound(to: Float.self)
            let count = Int(frames)

            var idx = phasePtr.pointee
            for i in 0..<count {
                out0[i] = table[idx]
                idx += 1
                if idx == n { idx = 0 }
            }
            phasePtr.pointee = idx

            // Non-interleaved multichannel: replicate to the other buffers.
            if list.count > 1 {
                for j in 1..<list.count {
                    if let m = list[j].mData {
                        memcpy(m, m0, count * MemoryLayout<Float>.size)
                    }
                }
            }
            return noErr
        }
        sourceNode = node

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        let ring = ringBuffer
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            ring.write(channelData, count: Int(buffer.frameLength))
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            teardown()
            AudioSessionManager.shared.deactivate()
            throw error
        }
    }

    public func stop() {
        teardown()
        isRunning = false
        AudioSessionManager.shared.deactivate()
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)   // lets start() be called again without attaching twice
            sourceNode = nil
        }
    }
}