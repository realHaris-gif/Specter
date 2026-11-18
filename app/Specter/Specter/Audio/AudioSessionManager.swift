import Foundation
import AVFoundation

public final class AudioSessionManager {
    public static let shared = AudioSessionManager()

    /// Called on the main queue when a call, Siri, alarm etc. interrupts audio.
    public var onInterruptionBegan: (() -> Void)?
    /// Called on the main queue when headphones/AirPods appear or disappear. Argument is a short reason.
    public var onRouteChangeRequiringStop: ((String) -> Void)?

    private var observers: [NSObjectProtocol] = []

    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .allowBluetooth removed: Bluetooth HFP forces ~16 kHz audio, which makes 18-21 kHz sonar impossible.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        // Prefer the phone's own microphone over any wired/BT input.
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        guard abs(session.sampleRate - 48_000) < 1 else {
            let got = session.sampleRate
            try? session.setActive(false)
            throw NSError(domain: "Specter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Hardware sample rate must be 48 kHz. Got \(got) Hz."
            ])
        }

        startObserving()
    }

    public func deactivate() {
        stopObserving()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// VERIFY ON DEVICE: first call shows the system permission dialog (needs NSMicrophoneUsageDescription).
    public func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: finish)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(finish)
        }
    }

    // MARK: - Interruption and route-change observers

    private func startObserving() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.onInterruptionBegan?()
        })

        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // Only real device changes. Our own setCategory() posts .categoryChange; ignore it.
            switch reason {
            case .newDeviceAvailable:
                self?.onRouteChangeRequiringStop?("Audio device connected")
            case .oldDeviceUnavailable:
                self?.onRouteChangeRequiringStop?("Audio device disconnected")
            default:
                break
            }
        })
    }

    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}