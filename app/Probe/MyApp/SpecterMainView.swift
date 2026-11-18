import SwiftUI
import Combine

// MARK: - Monochrome Palette

private enum Palette {
    static let bg    = Color(red: 0.035, green: 0.035, blue: 0.040)
    static let ink   = Color(red: 0.93,  green: 0.92,  blue: 0.90)
    static let dim   = Color(white: 0.52)
    static let faint = Color(white: 0.20)
    static let hair  = Color(white: 1, opacity: 0.08)

    static let stateActive = Color(red: 0.93, green: 0.92, blue: 0.90)
    static let stateIdle   = Color(white: 0.52)
}

// MARK: - Breath scaling (shared by graph and orb)

enum BreathScale {
    static let windowSize = 150

    static func levels(_ raw: [Double]) -> [Double] {
        let tail = Array(raw.suffix(windowSize)).filter { $0.isFinite }
        guard tail.count > 1 else { return tail.map { _ in 0.5 } }
        let m = median(tail)
        let mad = median(tail.map { abs($0 - m) })
        let half = max(1.3 * 1.4826 * mad, 0.4)
        return tail.map { min(max(($0 - m) / (2 * half) + 0.5, 0), 1) }
    }

    private static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }
}

// MARK: - Main view

struct SpecterMainView: View {
    @StateObject private var engine = SpecterEngine()

    @State private var showMotion = false
    @State private var motionTask: Task<Void, Never>?

    @State private var heldBpm: Double = 0
    @State private var heldAt: Date = .distantPast

    @State private var lastSample: Date = Date()
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let levels = BreathScale.levels(engine.displacementHistory)
        let spec = bannerSpec

        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                metrics
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                waveform(levels)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                // State banner without any beacon indicator dots
                StateBanner(title: spec.title, subtitle: spec.subtitle, tint: spec.tint)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                BlobField(level: levels.last ?? 0.5,
                          energy: energy,
                          active: engine.isRunning)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 8)

                if let msg = engine.statusMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(Palette.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                }

                actionButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(ticker) { now = $0 }
        .onChange(of: engine.displacementHistory.last) { _ in lastSample = Date() }
        .onChange(of: engine.currentBpm) { v in
            if v > 3, engine.sensingState != .motionDetected {
                heldBpm = v
                heldAt = Date()
            }
        }
        .onChange(of: engine.isRunning) { running in
            if running {
                lastSample = Date()
            } else {
                heldBpm = 0
                showMotion = false
                motionTask?.cancel()
            }
        }
        .onChange(of: engine.sensingState) { s in
            if s == .motionDetected {
                motionTask?.cancel()
                showMotion = true
            } else if showMotion {
                motionTask?.cancel()
                motionTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { showMotion = false }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("specter")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.ink)
            Spacer()
            Text(stateLabel)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Palette.dim)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: engine.sensingState)
        }
    }

    private var bpmLive: Bool {
        engine.isRunning && engine.currentBpm > 3 && engine.sensingState == .calmBreathing
    }

    private var bpmText: String {
        if bpmLive { return String(format: "%.1f", engine.currentBpm) }
        if heldBpm > 0, now.timeIntervalSince(heldAt) < 90 { return String(format: "%.1f", heldBpm) }
        return "--"
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            MetricBox(title: bpmLive ? "respiration" : "respiration (last)",
                      value: bpmText,
                      unit: "bpm",
                      dimmed: !bpmLive)
            divider
            MetricBox(title: "distance",
                      value: String(format: "%.2f", engine.currentRangeMeters),
                      unit: "m")
            divider
            MetricBox(title: "confidence",
                      value: String(format: "%.0f", engine.confidence * 100),
                      unit: "%")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.hair)
            .frame(width: 1, height: 36)
    }

    private func waveform(_ levels: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("chest displacement, mm")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Palette.dim)

            WaveformView(levels: levels)
                .frame(height: 90)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.25),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.hair).frame(height: 1)
                }
        }
    }

    private struct BannerSpec {
        let title: String
        let subtitle: String
        let tint: Color
    }

    private var isStale: Bool {
        engine.isRunning && engine.sensingState != .calibrating
            && now.timeIntervalSince(lastSample) > 2.5
    }

    private var bannerSpec: BannerSpec {
        if engine.isStarting {
            return BannerSpec(title: "STARTING", subtitle: "opening audio", tint: Palette.dim)
        }
        if !engine.isRunning {
            return BannerSpec(title: "READY", subtitle: "tap start sensing", tint: Palette.dim)
        }
        if showMotion {
            let sub = engine.currentRangeMeters > 0.05
                ? String(format: "about %.1f m from the phone", engine.currentRangeMeters)
                : "something is moving close by"
            return BannerSpec(title: "MOVEMENT NEAR PHONE", subtitle: sub, tint: Palette.ink)
        }
        if isStale {
            return BannerSpec(title: "NO SIGNAL", subtitle: "check volume and phone position",
                              tint: Palette.dim)
        }
        switch engine.sensingState {
        case .calmBreathing:
            let sub = bpmLive ? String(format: "%.0f breaths per minute", engine.currentBpm) : "tracking"
            return BannerSpec(title: "BREATHING", subtitle: sub, tint: Palette.ink)
        case .breathHold:
            return BannerSpec(title: "BREATH HOLD", subtitle: "no breathing movement detected",
                              tint: Palette.dim)
        case .calibrating:
            return BannerSpec(title: "CALIBRATING", subtitle: "keep still for a moment",
                              tint: Palette.dim)
        case .quiet, .motionDetected:
            return BannerSpec(title: "QUIET", subtitle: "nothing moving nearby",
                              tint: Palette.dim)
        }
    }

    private var actionButton: some View {
        let running = engine.isRunning
        let starting = engine.isStarting

        return Button {
            if running || starting {
                engine.stop()
            } else {
                engine.start()
            }
        } label: {
            Text(starting ? "starting" : (running ? "stop" : "start sensing"))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundColor(running ? Palette.ink : Palette.bg)
                .background(running ? Palette.bg : Palette.ink)
                .overlay(
                    Capsule().stroke(running ? Palette.faint : Color.clear, lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(starting)
        .opacity(starting ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.25), value: running)
    }

    private var stateLabel: String {
        switch engine.sensingState {
        case .calmBreathing:  return "breathing"
        case .motionDetected: return "motion"
        case .breathHold:     return "breath hold"
        case .calibrating:    return "calibrating"
        case .quiet:          return "idle"
        }
    }

    private var energy: Double {
        switch engine.sensingState {
        case .motionDetected: return 1.0
        case .calibrating:    return 0.4
        case .calmBreathing:  return 0.2
        case .breathHold, .quiet: return 0.0
        }
    }
}

// MARK: - State banner (Beacon completely removed)

struct StateBanner: View {
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundColor(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 68)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Palette.hair, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: title)
    }
}

// MARK: - Metric

struct MetricBox: View {
    let title: String
    let value: String
    let unit: String
    var dimmed: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Palette.dim)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundColor(dimmed ? Palette.dim : Palette.ink)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: value)
                Text(unit)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Palette.dim)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Metaball field

private final class OrbSmoother {
    var level: Double = 0.5
    var energy: Double = 0
    private var last: TimeInterval = 0

    func step(level target: Double, energy energyTarget: Double, now: TimeInterval) {
        let dt = last == 0 ? 0 : min(max(now - last, 0), 0.1)
        last = now
        level  += (target - level) * (1 - exp(-dt / 0.15))
        energy += (energyTarget - energy) * (1 - exp(-dt / 0.8))
    }
}

struct BlobField: View {
    var level: Double
    var energy: Double
    var active: Bool

    @State private var smoother = OrbSmoother()

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, size in
                smoother.step(level: active ? level : 0.5,
                              energy: active ? energy : 0,
                              now: now)
                let v = smoother.level
                let wobble = smoother.energy
                let t = now

                ctx.addFilter(.alphaThreshold(min: 0.5, color: Palette.ink))
                ctx.addFilter(.blur(radius: 13))

                ctx.drawLayer { layer in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let base = min(size.width, size.height) * 0.5

                    let outer = 9
                    for i in 0..<outer {
                        let f = Double(i)
                        let dir: Double = i % 2 == 0 ? 1 : -0.55
                        let angle = (f / Double(outer)) * .pi * 2 + t * 0.14 * dir

                        let drift  = sin(t * 0.6 + f * 1.3) * 0.025
                        let jitter = sin(t * 5.0 + f * 2.7) * 0.02 * wobble
                        let r = base * (0.32 + 0.30 * v + drift + jitter)

                        let sz = base * (0.115 + 0.02 * v + 0.012 * sin(t * 0.8 + f * 2.1))
                        let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                        layer.fill(Path(ellipseIn: CGRect(x: p.x - sz, y: p.y - sz,
                                                          width: sz * 2, height: sz * 2)),
                                   with: .color(.white))
                    }

                    let inner = 4
                    for i in 0..<inner {
                        let f = Double(i)
                        let angle = (f / Double(inner)) * .pi * 2 - t * 0.25
                        let r = base * (0.08 + 0.10 * v + 0.012 * sin(t * 0.9 + f * 1.9))
                        let sz = base * (0.095 + 0.015 * v)
                        let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                        layer.fill(Path(ellipseIn: CGRect(x: p.x - sz, y: p.y - sz,
                                                          width: sz * 2, height: sz * 2)),
                                   with: .color(.white))
                    }
                }
            }
        }
    }
}

// MARK: - Waveform

struct WaveformView: View {
    let levels: [Double]

    var body: some View {
        GeometryReader { geo in
            let stepX = geo.size.width / CGFloat(max(levels.count - 1, 1))
            let pts: [CGPoint] = levels.enumerated().map { idx, n in
                let y = geo.size.height - (CGFloat(n) * geo.size.height * 0.8 + geo.size.height * 0.1)
                return CGPoint(x: CGFloat(idx) * stepX, y: y)
            }
            smoothPath(pts)
                .stroke(Palette.ink,
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
    }

    private func smoothPath(_ pts: [CGPoint]) -> Path {
        Path { path in
            guard pts.count > 1 else { return }
            path.move(to: pts[0])
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2,
                                  y: (pts[i - 1].y + pts[i].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i - 1])
            }
            path.addLine(to: pts[pts.count - 1])
        }
    }
}