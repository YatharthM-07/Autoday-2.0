//
//  TaskCelebration.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 22/10/26.
//
//  The "done" moment: blur + dim, tile glides to the centre of the screen, pen strikes the
//  title, tick pops, themed confetti, chime, a progress card right below the tile, then the
//  tile glides back and the screen returns to normal with a green tile.
//
//  Tiers keep it from getting old:
//    quick     – rapid completions: tile stays in place, no dim, no card.
//    full      – centred tile + progress card.
//    milestone – full + bigger confetti and a stronger haptic (50% / all done).
//  Tap anywhere to skip.

import SwiftUI
import UIKit
import AVFoundation

// MARK: - Model

enum CelebrationTier {
    case quick, full, milestone

    var usesScrim: Bool { self != .quick }
    var showsCard: Bool { self != .quick }
    var centersTile: Bool { self != .quick }

    var particleCount: Int {
        switch self {
        case .quick:     return 16
        case .full:      return 46
        case .milestone: return 96
        }
    }

    /// How long the progress card stays up (milliseconds).
    var holdMs: Int {
        switch self {
        case .quick:     return 250
        case .full:      return 1500
        case .milestone: return 1900
        }
    }
}

struct Celebration: Identifiable {
    let id = UUID()
    let taskTitle: String
    let timeText: String
    let color: PastelColor
    let tileFrame: CGRect            // global
    let previous: CompletionProgress
    let progress: CompletionProgress
    let tier: CelebrationTier
}

// MARK: - Hook into TimelineView

extension TimelineView {

    /// Global frame of a task's tile (same maths the drag code uses).
    func tileFrame(for task: TimelineTask, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + Theme.labelWidth + 24,
               y: frame.minY + topOffsetForHour(task.startHour) - scrollBox.currentY,
               width: frame.width - Theme.labelWidth - 24 - 16,
               height: max(CGFloat(task.durationHours) * Theme.hourHeight - 2, 32))
    }

    /// Right swipe. Undo is quiet; marking done plays the celebration.
    func completeTask(_ task: TimelineTask, tileFrame: CGRect) {
        if task.isDone {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { store.toggleDone(task.id) }
            return
        }

        let before = CompletionProgress.make(from: store.tasks, on: selectedDate)
        store.toggleDone(task.id)       // data first: it's saved even if the user skips the animation
        let after  = CompletionProgress.make(from: store.tasks, on: selectedDate)

        let milestone = after.isComplete || (before.ratio < 0.5 && after.ratio >= 0.5)
        let rapid     = lastCelebrationAt.map { Date().timeIntervalSince($0) < 10 } ?? false
        let tier: CelebrationTier = milestone ? .milestone : (rapid ? .quick : .full)
        lastCelebrationAt = Date()

        celebration = Celebration(
            taskTitle: task.title,
            timeText: "\(hm(task.startHour)) – \(hm(task.endHour))",
            color: task.color,
            tileFrame: tileFrame,
            previous: before,
            progress: after,
            tier: tier
        )
    }

    @ViewBuilder
    var celebrationLayer: some View {
        if let c = celebration {
            CelebrationOverlay(celebration: c) { celebration = nil }
                .id(c.id)
                .transition(.identity)
        }
    }
}

// MARK: - Overlay

struct CelebrationOverlay: View {
    let celebration: Celebration
    let onFinish: () -> Void

    /// Where the centred tile sits, as a fraction of the screen height (0.5 = dead centre).
    /// Slightly above centre leaves room for the card underneath.
    private static let centerYRatio: CGFloat = 0.44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scrimOn = false
    @State private var lifted = false
    @State private var centered = false
    @State private var strike: CGFloat = 0
    @State private var turnedGreen = false
    @State private var tickOn = false
    @State private var ringPulse = false
    @State private var cardOn = false
    @State private var shine = false
    @State private var barRatio: Double = 0
    @State private var shownDone: Int = -1          // -1 = still showing the previous count
    @State private var burstStart: Date? = nil
    @State private var fadeOut = false
    @State private var skipped = false
    @State private var finishing = false

    private var progress: CompletionProgress { celebration.progress }
    private var accent: Color { TaskStatusStyle.done.accent }

    var body: some View {
        GeometryReader { geo in
            let origin  = geo.frame(in: .global).origin
            let tile    = celebration.tileFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let centers = celebration.tier.centersTile

            // Where the tile "lives" during the celebration.
            let anchor = centers
                ? CGPoint(x: geo.size.width / 2, y: geo.size.height * Self.centerYRatio)
                : CGPoint(x: tile.midX, y: tile.midY)
            let shownScale: CGFloat = centers ? 1.08 : 1.04
            let halfHeight = tile.height * shownScale / 2

            let tickCenter = CGPoint(x: anchor.x, y: max(anchor.y - halfHeight - 40, 80))
            let cardTop    = anchor.y + halfHeight + 22

            ZStack {
                // Blur + dim
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.30))
                    .opacity(scrimOn ? 1 : 0)
                    .ignoresSafeArea()

                // The tile, lifted above the scrim (and glided to the centre)
                CelebrationTile(title: celebration.taskTitle,
                                timeText: celebration.timeText,
                                color: celebration.color,
                                compact: tile.height < 50,
                                strike: strike,
                                turnedGreen: turnedGreen,
                                lifted: lifted,
                                scale: lifted ? shownScale : 1)
                    .frame(width: tile.width, height: tile.height)
                    .position(x: centered ? anchor.x : tile.midX,
                              y: centered ? anchor.y : tile.midY)
                    .opacity(fadeOut ? 0 : 1)

                // Confetti + sparkles
                if let burstStart, !reduceMotion {
                    ConfettiBurst(origin: tickCenter, start: burstStart,
                                  colors: confettiColors, count: celebration.tier.particleCount)
                }

                tickBadge
                    .position(tickCenter)

                // Progress card, right under the tile
                if celebration.tier.showsCard {
                    card
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, cardTop)
                        .offset(y: cardOn ? 0 : 24)
                        .scaleEffect(cardOn ? 1 : 0.92, anchor: .top)
                        .opacity(cardOn ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { skipped = true }          // tap anywhere to skip
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task { await run() }
    }

    // MARK: Pieces

    private var tickBadge: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.5), lineWidth: 3)
                .scaleEffect(ringPulse ? 2.2 : 1)
                .opacity(ringPulse ? 0 : 0.8)
            Circle()
                .fill(accent)
                .shadow(color: accent.opacity(0.45), radius: 10, y: 4)
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 46, height: 46)
        .scaleEffect(tickOn ? 1 : 0.2)
        .opacity(tickOn ? 1 : 0)
    }

    // MARK: Progress card

    private var card: some View {
        let p = progress
        let c1 = p.isComplete ? accent : Theme.primary
        let c2 = p.isComplete ? Color(hex: "#7BDCA8") : Color(hex: "#A98BFF")
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return HStack(spacing: 12) {
            progressRing(c1, c2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: p.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .symbolEffect(.bounce, value: cardOn)
                    Text(p.message)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [c1, c2], startPoint: .leading, endPoint: .trailing))

                Text(p.isComplete ? "Every task done today" : "\(p.remaining) more to go")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 262)
        .modifier(CelebrationCardBackground())
        .overlay {                                   // soft colour wash
            shape.fill(LinearGradient(colors: [c1.opacity(0.12), c2.opacity(0.04)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
        .overlay {                                   // gradient edge
            shape.strokeBorder(LinearGradient(colors: [c1.opacity(0.7), c2.opacity(0.2)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing),
                               lineWidth: 1.2)
        }
        .overlay { shineSweep(shape) }
        .shadow(color: c1.opacity(0.22), radius: 14, y: 5)
    }

    private func progressRing(_ c1: Color, _ c2: Color) -> some View {
        let shown = shownDone < 0 ? celebration.previous.done : shownDone
        return ZStack {
            Circle().stroke(c1.opacity(0.15), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(barRatio, 0.001))
                .stroke(AngularGradient(colors: [c1, c2, c1], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(shown)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                Text("of \(progress.total)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
    }
    
    private func shineSweep(_ shape: RoundedRectangle) -> some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.4)
                .rotationEffect(.degrees(18))
                .offset(x: shine ? g.size.width * 1.1 : -g.size.width * 0.6)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    private var confettiColors: [Color] {
        [Theme.primary, Theme.secondary, celebration.color.text, celebration.color.fill, accent, .white]
    }

    // MARK: Sequence

    @MainActor
    private func run() async {
        barRatio = celebration.previous.ratio

        // 1. Blur + dim, tile lifts and glides to the centre
        withAnimation(.easeOut(duration: 0.22)) {
            scrimOn = celebration.tier.usesScrim
            lifted = true
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82)) {
            centered = celebration.tier.centersTile
        }
        guard await pause(celebration.tier.centersTile ? 400 : 240) else { return await finish() }

        // 2. Pen strikes the title
        if reduceMotion { strike = 1 } else { withAnimation(.easeOut(duration: 0.5)) { strike = 1 } }
        guard await pause(reduceMotion ? 100 : 480) else { return await finish() }

        // 3. Tick, burst, chime, haptic, tile turns green
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.55)) {
            tickOn = true
        }
        if !reduceMotion { withAnimation(.easeOut(duration: 0.7)) { ringPulse = true } }
        withAnimation(.easeInOut(duration: 0.35)) { turnedGreen = true }
        burstStart = Date()
        playFeedback()
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(celebration.taskTitle) done. \(progress.done) of \(progress.total) tasks done. \(progress.message)"
        )
        guard await pause(300) else { return await finish() }

        // 4. Progress card
        if celebration.tier.showsCard {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { cardOn = true }
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) {
                barRatio = progress.ratio
                shownDone = progress.done
            }
            withAnimation(.easeInOut(duration: 0.9).delay(0.25)) { shine = true }
        }
        guard await pause(celebration.tier.holdMs) else { return await finish() }

        await finish()
    }

    /// Everything glides away: the tile returns to its place on the timeline, then hands back control.
    @MainActor
    private func finish() async {
        guard !finishing, !Task.isCancelled else { return }
        finishing = true
        let fast = skipped

        withAnimation(.spring(response: fast ? 0.25 : 0.42, dampingFraction: 0.88)) {
            centered = false
            scrimOn = false
            cardOn = false
            tickOn = false
        }
        try? await Task.sleep(for: .milliseconds(fast ? 260 : 440))

        withAnimation(.easeOut(duration: 0.12)) { fadeOut = true }
        try? await Task.sleep(for: .milliseconds(130))
        onFinish()
    }

    /// Sleeps in small steps so a tap can cut it short. Returns false if skipped or cancelled.
    @MainActor
    private func pause(_ ms: Int) async -> Bool {
        var left = ms
        while left > 0 {
            if skipped || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(min(left, 50)))
            left -= 50
        }
        return !(skipped || Task.isCancelled)
    }

    private func playFeedback() {
        switch celebration.tier {
        case .quick:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            ChimePlayer.shared.play(.soft)
        case .full:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ChimePlayer.shared.play(.done)
        case .milestone:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
            ChimePlayer.shared.play(.milestone)
        }
    }
}

// Icon for the progress message (mirrors the thresholds in CompletionProgress.message).
private extension CompletionProgress {
    var symbol: String {
        if isComplete { return "trophy.fill" }
        if (remaining == 1 && total >= 3) || ratio >= 0.75 { return "flag.checkered" }
        if ratio >= 0.5 { return "star.leadinghalf.filled" }
        if done <= 1 { return "bolt.fill" }
        return "flame.fill"
    }
}

// MARK: - The tile copy (strike + turns green)

private struct CelebrationTile: View {
    let title: String
    let timeText: String
    let color: PastelColor
    let compact: Bool
    let strike: CGFloat
    let turnedGreen: Bool
    let lifted: Bool
    let scale: CGFloat

    var body: some View {
        let accent = turnedGreen ? TaskStatusStyle.done.accent : color.text
        let fill   = turnedGreen ? TaskStatusStyle.done.fill   : color.fill

        let titleText = Text(title)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
            .overlay {
                StrikeShape()
                    .trim(from: 0, to: strike)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(.horizontal, -4)
            }
        let timeLabel = Text(timeText)
            .font(.system(size: 12))
            .opacity(0.7 * (1 - 0.4 * strike))
            .lineLimit(1)

        Group {
            if compact {
                HStack(spacing: 6) {
                    titleText
                    timeLabel
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    timeLabel
                }
            }
        }
        .foregroundStyle(accent)
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.vertical, compact ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: compact ? .leading : .topLeading)
        .background(fill)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: 6.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: lifted ? 18 : 0, y: lifted ? 10 : 0)
        .scaleEffect(scale)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: scale)
        .animation(.easeInOut(duration: 0.35), value: turnedGreen)
    }
}

/// A slightly wobbly pen line, drawn left to right with `.trim`.
private struct StrikeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY + 1
        p.move(to: CGPoint(x: rect.minX, y: y + 1.5))
        p.addCurve(to: CGPoint(x: rect.maxX, y: y - 1.5),
                   control1: CGPoint(x: rect.width * 0.3, y: y - 3),
                   control2: CGPoint(x: rect.width * 0.7, y: y + 3))
        return p
    }
}

// MARK: - Card background (glass on iOS 26)

private struct CelebrationCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - Confetti

private struct ConfettiBurst: View {
    struct Particle {
        let angle: Double
        let speed: Double
        let size: CGFloat
        let spin: Double
        let phase: Double
        let flip: Double
        let delay: Double
        let life: Double
        let color: Color
        let shape: Int          // 0,1 = confetti strip, 2 = dot, 3 = sparkle
    }

    let origin: CGPoint
    let start: Date
    @State private var particles: [Particle]

    init(origin: CGPoint, start: Date, colors: [Color], count: Int) {
        self.origin = origin
        self.start = start
        _particles = State(initialValue: (0..<count).map { _ in
            Particle(angle: Double.random(in: (-Double.pi * 0.97)...(-Double.pi * 0.03)),
                     speed: Double.random(in: 260...620),
                     size: CGFloat.random(in: 6...11),
                     spin: Double.random(in: -6...6),
                     phase: Double.random(in: 0...(2 * Double.pi)),
                     flip: Double.random(in: 4...10),
                     delay: Double.random(in: 0...0.08),
                     life: Double.random(in: 1.3...2.1),
                     color: colors.randomElement() ?? .white,
                     shape: Int.random(in: 0...3))
        })
    }

    var body: some View {
        // `SwiftUI.` because the app has its own TimelineView.
        SwiftUI.TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSince(start)
                let k = 1.8          // air drag
                let g = 700.0        // gravity

                for p in particles {
                    let td = t - p.delay
                    guard td > 0, td < p.life else { continue }

                    let drag = (1 - exp(-k * td)) / k
                    let x = origin.x + cos(p.angle) * p.speed * drag
                    let y = origin.y + (sin(p.angle) * p.speed + g / k) * drag - g * td / k

                    let fadeStart = p.life * 0.65
                    let alpha = td < fadeStart ? 1 : max(0, 1 - (td - fadeStart) / (p.life - fadeStart))

                    var c = context
                    c.opacity = alpha
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.phase + p.spin * td))

                    let s = p.size
                    switch p.shape {
                    case 2:
                        let dot = CGRect(x: -s * 0.4, y: -s * 0.4, width: s * 0.8, height: s * 0.8)
                        c.fill(Path(ellipseIn: dot), with: .color(p.color))
                    case 3:
                        c.fill(Self.sparkle(size: s * 1.7), with: .color(p.color))
                    default:
                        c.scaleBy(x: 1, y: max(0.15, abs(cos(td * p.flip))))   // tumbling paper
                        let strip = CGRect(x: -s / 2, y: -s * 0.3, width: s, height: s * 0.6)
                        c.fill(Path(roundedRect: strip, cornerRadius: 1.5), with: .color(p.color))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Four-point sparkle centred on the origin.
    static func sparkle(size: CGFloat) -> Path {
        var path = Path()
        let outer = size / 2
        let inner = outer * 0.28
        for i in 0..<8 {
            let angle = Double(i) * Double.pi / 4 - Double.pi / 2
            let r = i % 2 == 0 ? outer : inner
            let point = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Chime (generated in code, no audio file needed)

/// Plays a short synthesised chime. Uses the .ambient session, so it follows the silent switch
/// and mixes with other audio. Users can turn it off with UserDefaults key "celebrationSound".
/// To use your own sound later, replace `render(_:)` with loading a file.
final class ChimePlayer {
    enum Kind { case soft, done, milestone }

    static let shared = ChimePlayer()
    private var player: AVAudioPlayer?
    private var cache: [Kind: Data] = [:]

    func play(_ kind: Kind) {
        let enabled = UserDefaults.standard.object(forKey: "celebrationSound") as? Bool ?? true
        guard enabled else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        let data = cache[kind] ?? Self.render(kind)
        cache[kind] = data
        player = try? AVAudioPlayer(data: data)
        player?.volume = 0.8
        player?.prepareToPlay()
        player?.play()
    }

    private static func render(_ kind: Kind) -> Data {
        let notes: [(freq: Double, at: Double)]
        let seconds: Double
        switch kind {
        case .soft:
            notes = [(1318.5, 0)]                                            // E6
            seconds = 0.5
        case .done:
            notes = [(1318.5, 0), (1975.5, 0.09)]                            // E6, B6
            seconds = 0.8
        case .milestone:
            notes = [(1046.5, 0), (1318.5, 0.09), (1568.0, 0.18), (2093.0, 0.27)]   // C6 E6 G6 C7
            seconds = 1.1
        }

        let rate = 44_100
        let count = Int(Double(rate) * seconds)
        var samples = [Float](repeating: 0, count: count)

        for note in notes {
            let first = Int(note.at * Double(rate))
            guard first < count else { continue }
            for i in first..<count {
                let t = Double(i - first) / Double(rate)
                let envelope = min(1, t / 0.004) * exp(-t / 0.17)
                let tone = sin(2 * Double.pi * note.freq * t) + 0.25 * sin(4 * Double.pi * note.freq * t)
                samples[i] += Float(tone * envelope * 0.3)
            }
        }

        var pcm = Data(capacity: count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            pcm.append(UInt8(truncatingIfNeeded: v))
            pcm.append(UInt8(truncatingIfNeeded: v >> 8))
        }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.appendLE(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.appendLE(UInt32(16))            // fmt chunk size
        wav.appendLE(UInt16(1))             // PCM
        wav.appendLE(UInt16(1))             // mono
        wav.appendLE(UInt32(rate))
        wav.appendLE(UInt32(rate * 2))      // byte rate
        wav.appendLE(UInt16(2))             // block align
        wav.appendLE(UInt16(16))            // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.appendLE(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
