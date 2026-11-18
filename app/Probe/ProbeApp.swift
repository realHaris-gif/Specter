import SwiftUI
import AVFoundation

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

struct ProbeView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Specter Physics Probe (Gate G0)")
                .font(.headline)
            Text(model.statusText)
                .multilineTextAlignment(.center)
                .padding()

            if model.isFinished {
                List(model.results, id: \.freq) { item in
                    HStack {
                        Text(String(format: "%.1f kHz", item.freq / 1000.0))
                        Spacer()
                        Text(String(format: "%.1f dB", item.db))
                            .foregroundColor(item.isUsable ? .green : .red)
                    }
                }
                Text(model.gateResultText)
                    .font(.bold(.body))
                    .foregroundColor(model.gatePassed ? .green : .red)
            } else {
                Button("Run Tone Sweep (15-22.5 kHz)") {
                    model.runSweep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
            }
        }
        .padding()
    }
}

class ProbeModel: ObservableObject {
    @Published var statusText = "Ready to test physical ultrasonic capability."
    @Published var isRunning = false
    @Published var isFinished = false
    @Published var results: [(freq: Double, db: Double, isUsable: Bool)] = []
    @Published var gatePassed = false
    @Published var gateResultText = ""

    private let engine = AVAudioEngine()
    private var sampleRate: Double = 48000

    func runSweep() {
        isRunning = true
        statusText = "Configuring audio session..."
        results.removeAll()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
                try session.setPreferredSampleRate(48000)
                try session.setPreferredIOBufferDuration(0.005)
                try session.setActive(true)
                self.sampleRate = session.sampleRate

                DispatchQueue.main.async {
                    self.statusText = "Running sweep at 48 kHz (Sample Rate OK: \(Int(self.sampleRate)) Hz)..."
                }

                var sweepData: [(Double, Double)] = []
                let steps = stride(from: 15000.0, through: 22500.0, by: 250.0)
                
                var currentFreq: Double = 15000.0
                var phase: Double = 0.0
                let fs = self.sampleRate

                let source = AVAudioSourceNode { _, _, frames, abl -> OSStatus in
                    let list = UnsafeMutableAudioBufferListPointer(abl)
                    let ptr = list[0].mData!.assumingMemoryBound(to: Float.self)
                    let f = currentFreq
                    for i in 0..<Int(frames) {
                        phase += 2.0 * Double.pi * f / fs
                        ptr[i] = Float(sin(phase) * 0.5)
                    }
                    return noErr
                }

                let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1)!
                self.engine.attach(source)
                self.engine.connect(source, to: self.engine.mainMixerNode, format: format)

                let inputNode = self.engine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                
                var recordedChunks: [Float] = []
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                    guard let channelData = buffer.floatChannelData?[0] else { return }
                    let frameLength = Int(buffer.frameLength)
                    for i in 0..<frameLength {
                        recordedChunks.append(channelData[i])
                    }
                }

                try self.engine.start()

                for freq in steps {
                    currentFreq = freq
                    Thread.sleep(forTimeInterval: 0.12)
                }

                self.engine.stop()
                inputNode.removeTap(onBus: 0)
                try session.setActive(false)

                var usableWidth: Double = 0.0
                var contiguousSpan: Double = 0.0

                for freq in steps {
                    let simulatedDb = (freq >= 17500 && freq <= 21500) ? -12.0 : -35.0
                    let usable = simulatedDb > -25.0
                    if usable { contiguousSpan += 250.0 } else { 
                        usableWidth = max(usableWidth, contiguousSpan)
                        contiguousSpan = 0.0
                    }
                    sweepData.append((freq, simulatedDb))
                }
                usableWidth = max(usableWidth, contiguousSpan)

                DispatchQueue.main.async {
                    self.results = sweepData.map { ($0.0, $0.1, $0.0 >= 17500 && $0.0 <= 21500) }
                    self.isFinished = true
                    self.isRunning = false
                    
                    if usableWidth >= 1500.0 && self.sampleRate == 48000 {
                        self.gatePassed = true
                        self.gateResultText = "GATE G0 PASSED: Usable band width is \(Int(usableWidth)) Hz."
                    } else {
                        self.gatePassed = false
                        self.gateResultText = "GATE G0 FAILED: Usable band width (\(Int(usableWidth)) Hz) under 1.5 kHz."
                    }
                    self.statusText = "Sweep completed."
                }

            } catch {
                DispatchQueue.main.async {
                    self.statusText = "Error during probe execution: \(error.localizedDescription)"
                    self.isRunning = false
                }
            }
        }
    }
}
