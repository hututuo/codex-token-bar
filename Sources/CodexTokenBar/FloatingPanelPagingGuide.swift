import AppKit
import SwiftUI

enum FloatingPanelPagingGuideState {
    static func shouldPresent(
        setupGuideCompleted: Bool,
        completedRevision: Int,
        hasPagedRows: Bool
    ) -> Bool {
        setupGuideCompleted
            && completedRevision < FloatingPanelContentVisibility.currentPagingGuideRevision
            && hasPagedRows
    }
}

struct FloatingPanelPagingGuide: View {
    @Binding var showsArrowGlyphs: Bool
    let scale: CGFloat
    let targetY: CGFloat
    let onComplete: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                edgeGlow(isLeading: true)
                edgeGlow(isLeading: false)
                animatedPointer(in: proxy.size)

                VStack(spacing: 3.scaled(by: scale)) {
                    Text("点两侧即可翻页")
                        .font(.system(size: 11.4.scaled(by: scale), weight: .bold))
                    Text("点击阴影边缘试一下")
                        .font(.system(size: 8.4.scaled(by: scale), weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 7.scaled(by: scale)) {
                        Toggle("显示箭头", isOn: $showsArrowGlyphs)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                            .fixedSize()

                        Button("开始体验", action: onComplete)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                    }
                }
                .foregroundStyle(Color.primary.opacity(0.94))
                .padding(.horizontal, 9.scaled(by: scale))
                .padding(.vertical, 7.scaled(by: scale))
                .frame(width: 168.scaled(by: scale))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
                        .stroke(Color.white.opacity(0.48), lineWidth: 0.8.scaled(by: scale))
                )
                .shadow(color: Color.black.opacity(0.2), radius: 10.scaled(by: scale), y: 4.scaled(by: scale))
                .contentShape(RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("悬浮窗翻页引导")
    }

    private func edgeGlow(isLeading: Bool) -> some View {
        let alignment: Alignment = isLeading ? .leading : .trailing
        return LinearGradient(
            colors: isLeading
                ? [AppTheme.accentBlue.opacity(0.38), AppTheme.accentBlue.opacity(0.08), .clear]
                : [.clear, AppTheme.accentBlue.opacity(0.08), AppTheme.accentBlue.opacity(0.38)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 42.scaled(by: scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .shadow(color: AppTheme.accentBlue.opacity(0.42), radius: 8.scaled(by: scale))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func animatedPointer(in size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let motion = pointerMotion(at: context.date)
            let targetX = max(0, size.width / 2 - 24.scaled(by: scale))
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 16.scaled(by: scale), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTheme.accentBlue)
                .shadow(color: Color.white.opacity(0.72), radius: 2.scaled(by: scale))
                .scaleEffect(motion.isClicking ? 0.84 : 1)
                .position(
                    x: size.width / 2 + targetX * motion.direction * motion.progress,
                    y: min(max(targetY, 12.scaled(by: scale)), size.height - 12.scaled(by: scale))
                )
                .opacity(motion.opacity)
                .zIndex(3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pointerMotion(at date: Date) -> (direction: CGFloat, progress: CGFloat, isClicking: Bool, opacity: Double) {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.2)
        let half = cycle < 2.6 ? cycle : cycle - 2.6
        let direction: CGFloat = cycle < 2.6 ? 1 : -1
        let rawProgress = min(max((half - 0.18) / 1.35, 0), 1)
        let eased = CGFloat(1 - pow(1 - rawProgress, 3))
        let isClicking = half >= 1.55 && half <= 1.92
        let fade = half < 2.22 ? 1 : max(0, (2.6 - half) / 0.38)
        return (direction, eased, isClicking, fade)
    }
}

struct FloatingPanelInteractionBridge: NSViewRepresentable {
    let guidePresented: Bool
    let isLocked: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updatePanel(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updatePanel(from: nsView)
    }

    private func updatePanel(from view: NSView) {
        DispatchQueue.main.async {
            (view.window as? FloatingTokenPanelWindow)?.allowsBackgroundDrag = !guidePresented && !isLocked
        }
    }
}
