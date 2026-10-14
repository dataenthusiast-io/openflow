import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var visible = false
    @Published private(set) var text = ""
    /// Number of trailing characters of `text` that are still fading in.
    @Published private(set) var freshCount = 0
    /// Bumped when a new batch of characters starts fading in; restarts the reveal animation.
    @Published private(set) var generation = 0
    @Published var lang: String?
    @Published var level: Float = 0
    @Published var finishing = false
    /// Hands-free mode (double-tap): recording continues until the next press.
    @Published var locked = false

    private var batchStarted = Date.distantPast
    private static let maxChars = 320
    private static let maxLines = 4  // logical lines; wrapping can add more on screen

    func reset() {
        text = ""
        freshCount = 0
        lang = nil
        level = 0
        finishing = false
        locked = false
    }

    /// Partials arrive once per 320 ms chunk, as several tokens a few ms apart. Tokens within one
    /// burst join the same reveal; a new burst starts a new one.
    func update(_ full: String) {
        let new = Self.tail(full)
        guard new != text else { return }
        let common = new.commonPrefix(with: text).count
        let added = new.count - common
        if Date().timeIntervalSince(batchStarted) < 0.15 {
            freshCount = min(new.count, freshCount + added)
        } else {
            freshCount = added
            generation += 1
            batchStarted = Date()
        }
        text = new
    }

    /// Keep the HUD small: show the most recent lines and words.
    private static func tail(_ full: String) -> String {
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        let s = lines.count > maxLines ? lines.suffix(maxLines).joined(separator: "\n") : full
        guard s.count > maxChars else { return s }
        let cut = s.suffix(maxChars)
        let word = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[word...]
    }
}

/// Floating, non-activating HUD at the bottom of the screen; never takes focus or mouse events.
final class OverlayPanel {
    let model = OverlayModel()
    private let panel: NSPanel
    private static let size = NSSize(width: 720, height: 280)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the glass draws its own
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show() {
        model.reset()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 24))
        }
        panel.orderFrontRegardless()
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.visible = true }
    }

    func hide() {
        withAnimation(.spring(duration: 0.3, bounce: 0)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            if !model.visible { panel.orderOut(nil) }
        }
    }
}

let brand = LinearGradient(
    colors: [Color(red: 0.36, green: 0.27, blue: 0.96), Color(red: 0.55, green: 0.24, blue: 0.93), Color(red: 0.98, green: 0.36, blue: 0.55)],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

private struct OverlayView: View {
    static let maxLines = 8
    @ObservedObject var model: OverlayModel
    @Namespace private var glass

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.visible {
                content
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 16)
        .animation(.spring(duration: 0.4, bounce: 0.25), value: model.lang)
        .animation(.smooth(duration: 0.3), value: model.text)
        .animation(.smooth(duration: 0.3), value: model.finishing)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: model.locked)
    }

    @ViewBuilder private var content: some View {
        GlassGroup {
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    LevelBars(level: model.level, finishing: model.finishing)
                    transcript
                    if model.locked && !model.finishing {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 13)
                .frame(minHeight: 50)
                .glass(in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                .glassID("pill", in: glass)

                if let lang = model.lang {
                    Text(lang.prefix(2).uppercased())
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(brand)
                        .frame(width: 42, height: 42)
                        .glass(in: Circle())
                        .glassID("lang", in: glass)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        if model.text.isEmpty {
            Text(model.finishing ? "…" : model.locked ? "Hands-free · press ⌥ to finish" : "Listening…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else {
            let split = model.text.index(model.text.endIndex, offsetBy: -model.freshCount)
            (Text(verbatim: String(model.text[..<split]))
                + Text(verbatim: String(model.text[split...])).customAttribute(Fresh()))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(Self.maxLines)
                .truncationMode(.head)  // if it still overflows, drop the oldest text
                .multilineTextAlignment(.leading)
                .contentTransition(.identity)  // no crossfade on re-wrap; RevealRenderer handles new glyphs
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .keyframeAnimator(initialValue: 1.0, trigger: model.generation) { view, progress in
                    view.textRenderer(RevealRenderer(progress: progress))
                } keyframes: { _ in
                    MoveKeyframe(0.0)
                    CubicKeyframe(1.0, duration: 0.5)
                }
        }
    }
}

// MARK: - Fluid text reveal

private struct Fresh: TextAttribute {}

/// Draws glyphs marked `Fresh` rising out of a blur, staggered left to right.
private struct RevealRenderer: TextRenderer {
    var progress: Double

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let fresh = layout.flatMap { $0 }.filter { $0[Fresh.self] != nil }.reduce(0) { $0 + $1.count }
        let stagger = fresh > 1 ? min(0.5, 6.0 / Double(fresh)) : 0  // share of the timeline spent staggering
        var i = 0
        for line in layout {
            for run in line {
                guard run[Fresh.self] != nil, progress < 1 else {
                    ctx.draw(run)
                    continue
                }
                for glyph in run {
                    let start = fresh > 1 ? stagger * Double(i) / Double(fresh - 1) : 0
                    let p = max(0, min(1, (progress - start) / (1 - stagger)))
                    var c = ctx
                    c.opacity = p
                    c.translateBy(x: 0, y: (1 - p) * 5)
                    if p < 1 { c.addFilter(.blur(radius: (1 - p) * 4)) }
                    c.draw(glyph)
                    i += 1
                }
            }
        }
    }
}

// MARK: - Level bars

struct LevelBars: View {
    var level: Float
    var finishing: Bool
    var fill = AnyShapeStyle(brand)
    private static let weights: [Double] = [0.45, 0.8, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let l = Double(min(1, sqrt(level) * 3))
            HStack(spacing: 3) {
                ForEach(Self.weights.indices, id: \.self) { i in
                    let h: Double = finishing
                        ? 5 + 7 * (0.5 + 0.5 * sin(t * 6 - Double(i) * 0.9))  // "thinking" wave
                        : 5 + 19 * l * Self.weights[i] * (0.75 + 0.25 * sin(t * 9 + Double(i) * 1.3))
                    Capsule()
                        .fill(finishing ? AnyShapeStyle(.secondary) : fill)
                        .frame(width: 4, height: h)
                }
            }
            .frame(width: 32, height: 26)
        }
    }
}

// MARK: - Liquid Glass with a material fallback before macOS 26

struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay(shape.stroke(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
    }

    @ViewBuilder func glassID(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(macOS 26, *) { glassEffectID(id, in: ns) } else { self }
    }
}
