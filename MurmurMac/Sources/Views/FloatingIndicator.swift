import SwiftUI
import AppKit
import Combine

enum IndicatorPosition: String, CaseIterable, Identifiable {
    case bottomCenter, topCenter, topRight
    var id: String { rawValue }
    var label: String {
        switch self { case .bottomCenter: "Bottom center"; case .topCenter: "Top center"; case .topRight: "Top right" }
    }
    static var current: IndicatorPosition {
        IndicatorPosition(rawValue: UserDefaults.standard.string(forKey: "indicatorPosition") ?? "") ?? .bottomCenter
    }
}

enum IndicatorAccent: String, CaseIterable, Identifiable {
    case aurora, sunset, ocean, mono
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colors: [Color] {
        switch self {
        case .aurora: [Color(red: 0.55, green: 0.36, blue: 1.0), Color(red: 0.2, green: 0.85, blue: 0.95)]
        case .sunset: [Color(red: 1.0, green: 0.42, blue: 0.35), Color(red: 1.0, green: 0.75, blue: 0.3)]
        case .ocean:  [Color(red: 0.15, green: 0.5, blue: 1.0), Color(red: 0.3, green: 0.95, blue: 0.7)]
        case .mono:   [Color.white.opacity(0.95), Color.white.opacity(0.6)]
        }
    }
    static var current: IndicatorAccent {
        IndicatorAccent(rawValue: UserDefaults.standard.string(forKey: "indicatorAccent") ?? "") ?? .aurora
    }
}

@MainActor
final class FloatingIndicatorController {
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var visible = false
    private let size = NSSize(width: 176, height: 44)

    init() {
        let host = NSHostingView(rootView: FloatingIndicatorView().environmentObject(AppState.shared))
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.becomesKeyOnlyIfNeeded = true
        w.contentView = host
        w.backgroundColor = .clear
        w.isOpaque = false
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.isMovableByWindowBackground = true
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { n in
            guard let win = n.object as? NSWindow, win.isVisible else { return }
            UserDefaults.standard.set(NSStringFromPoint(win.frame.origin), forKey: "indicatorOrigin")
        }
        window = w

        // Stay visible through recording AND transcribing, so the user sees progress.
        AppState.shared.$isRecording.combineLatest(AppState.shared.$isProcessing)
            .map { $0 || $1 }
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] active in active ? self?.reallyShow() : self?.reallyHide() }
            .store(in: &bag)
    }

    // Kept for existing callers; visibility now follows AppState.
    func show() { reallyShow() }
    func hide() { }

    private func reallyShow() {
        guard !visible, UserDefaults.standard.object(forKey: "showIndicator") as? Bool ?? true,
              let window, let screen = NSScreen.main else { return }
        visible = true
        let f = screen.visibleFrame
        var origin: NSPoint
        switch IndicatorPosition.current {
        case .bottomCenter: origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + 24)
        case .topCenter:    origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 12)
        case .topRight:     origin = NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12)
        }
        if let saved = UserDefaults.standard.string(forKey: "indicatorOrigin") {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -20, dy: -20).contains(p) }) { origin = p }
        }
        window.setFrameOrigin(origin)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; window.animator().alphaValue = 1 }
    }

    private func reallyHide() {
        guard visible, let window else { return }
        visible = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; window.animator().alphaValue = 0 } completionHandler: {
            window.orderOut(nil)
        }
    }
}

struct FloatingIndicatorView: View {
    @EnvironmentObject var app: AppState
    @State private var levels: [CGFloat] = Array(repeating: 0.05, count: 14)
    @State private var started = Date()
    @State private var appear = false
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var accent: [Color] { IndicatorAccent.current.colors }

    var body: some View {
        HStack(spacing: 7) {
            orb
            if app.isProcessing && !app.isRecording {
                processing
            } else {
                waveform
                Text(elapsed)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Capsule())
        .help("Drag to move")
        .background {
            Capsule().fill(Color.black.opacity(0.82))
            Capsule().fill(.ultraThinMaterial).opacity(0.35)
            Capsule().strokeBorder(
                AngularGradient(colors: accent + [accent[0]], center: .center),
                lineWidth: 1.2).opacity(0.7)
        }
        .shadow(color: accent[0].opacity(0.4), radius: 8, y: 2)
        .scaleEffect(appear ? 1 : 0.8)
        .opacity(appear ? 1 : 0)
        .frame(width: 176, height: 44)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { appear = true }
        }
        .onChange(of: app.isRecording) { _, rec in if rec { started = Date() } }
        .onReceive(tick) { _ in
            let raw = app.isRecording ? LevelMeter.level() : 0
            var next = Array(levels.dropFirst())
            next.append(max(0.06, raw * CGFloat.random(in: 0.75...1.15)))
            withAnimation(.linear(duration: 1.0 / 30.0)) { levels = next }
        }
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var orb: some View {
        TimelineView(.animation) { ctx in
            orbBody(t: ctx.date.timeIntervalSinceReferenceDate)
        }
    }

    private func orbBody(t: Double) -> some View {
        let lvl: CGFloat = levels.last ?? 0
        let thinking = app.isProcessing && !app.isRecording
        let coreScale: CGFloat = thinking ? CGFloat(0.85 + 0.1 * sin(t * 6)) : 1 + lvl * 0.25
        let ring = AngularGradient(colors: accent + [accent[0]], center: .center, angle: .degrees(t * 120))
        let glow = RadialGradient(colors: [accent[0].opacity(0.55), Color.clear], center: .center, startRadius: 2, endRadius: 12)
        _ = ring
        return ZStack {
            Circle().fill(glow).scaleEffect(1 + lvl * 0.9)
            Image("IndicatorIcon")
                .resizable().interpolation(.high)
                .frame(width: 17, height: 17)
                .scaleEffect(coreScale)
        }
        .frame(width: 20, height: 20)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: accent, startPoint: .bottom, endPoint: .top))
                    .frame(width: 2.5, height: 3 + levels[i] * 17)
                    .opacity(0.45 + Double(i) / Double(levels.count) * 0.55)
            }
        }
        .frame(height: 22)
    }

    private var processing: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                Text("Transcribing")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(accent[i % accent.count])
                            .frame(width: 4, height: 4)
                            .offset(y: -2 * sin(t * 6 + Double(i) * 0.9))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 128)
        }
    }
}
