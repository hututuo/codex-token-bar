import AppKit
import SwiftUI

/// A rehearsal uses the existing panel and dock controller. Its coordinates
/// never enter normal placement persistence, and cancellation restores first.
@MainActor
final class FloatingRealWindowGuide {
    private weak var panel: NSPanel?
    private let dock: FloatingEdgeDockController
    private let original: NSRect
    private let originallyAttached: Bool
    private let workArea: NSRect
    private let complete: (Bool) -> Void
    private let state = FloatingRealGuideCalloutState()
    private var callout: NSPanel?
    private var cursor: NSPanel?
    private var cursorView: NSHostingView<FloatingGuideCursor>?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var closed = false
    private var pressed = false

    init(panel: NSPanel, dock: FloatingEdgeDockController, complete: @escaping (Bool) -> Void) {
        self.panel = panel
        self.dock = dock
        original = dock.expandedFrame ?? panel.frame
        originallyAttached = dock.isAttached
        workArea = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        self.complete = complete
    }

    func start() {
        guard !closed, let panel else { return }
        if callout == nil {
            let callout = auxiliary(size: NSSize(width: 286, height: 100), interactive: true)
            callout.identifier = .init("CodexFloatingRealGuideCallout")
            callout.contentView = NSHostingView(rootView: FloatingRealGuideCallout(state: state,
                replay: { [weak self] in self?.start() }, finish: { [weak self] in self?.finish() }))
            self.callout = callout
            let cursor = auxiliary(size: NSSize(width: 54, height: 65), interactive: false)
            cursor.identifier = .init("CodexFloatingRealGuideCursor")
            let view = NSHostingView(rootView: FloatingGuideCursor(pressed: false))
            cursor.contentView = view
            self.cursor = cursor; cursorView = view
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(markComplete: false) }
            }
        }
        task?.cancel()
        dock.detach()
        panel.setFrame(restorableFrame(), display: true)
        state.finished = false
        (panel as? FloatingTokenPanelWindow)?.onGuideInteraction = { [weak self] in self?.finish() }
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.play() }
            catch is CancellationError { }
            catch { self.finish(markComplete: false) }
        }
    }

    private func play() async throws {
        guard let panel else { throw CancellationError() }
        let size = original.size
        let onRight = original.midX >= workArea.midX
        let target = NSPoint(x: onRight ? workArea.maxX - size.width : workArea.minX,
            y: min(max(original.minY, workArea.minY + 120), max(workArea.minY + 120, workArea.maxY - size.height - 90)))
        let distance = min(CGFloat(260), max(90, (workArea.width - size.width) * 0.4))
        let free = NSPoint(x: onRight ? target.x - distance : target.x + distance, y: target.y)
        dock.beginGuide(pointer: grabPoint(panel.frame))
        dock.beginDrag()
        panel.setFrame(NSRect(origin: free, size: size), display: true)
        let below = target.y - 110
        let cardY = below >= workArea.minY ? below : target.y + size.height + 10
        let cardX = min(max(target.x + (size.width - 286) / 2, workArea.minX + 8), workArea.maxX - 294)
        callout?.setFrameOrigin(NSPoint(x: cardX, y: min(max(cardY, workArea.minY + 8), workArea.maxY - 108)))
        callout?.orderFrontRegardless()
        positionCursor(grabPoint(panel.frame)); cursor?.orderFrontRegardless()
        setStep(1, "拖到边缘，自动吸附", "演示鼠标会带着这个悬浮窗移动")
        try await pause(0.95)
        setPressed(true)
        try await pause(0.2)
        try await moveWindow(to: target, duration: 1.7)
        try await pause(0.2)
        setPressed(false)
        dock.guideHover(at: grabPoint(panel.frame)); dock.endDrag()
        try await pause(0.35)
        setStep(2, "松手后吸附，移开后收起", "真实面板会收成屏幕边缘的色条")
        let away = NSPoint(x: target.x + size.width / 2, y: target.y - 24)
        try await moveCursor(to: away, duration: 0.4)
        dock.guideHover(at: away)
        try await pause(1.15)
        try await enterHandle(step: 3, title: "鼠标移入色条，自动展开")
        try await pause(0.7)
        setStep(4, "鼠标移开，再次收起", "需要时再移入，就能重新展开")
        try await moveCursor(to: away, duration: 0.4)
        dock.guideHover(at: away)
        try await pause(1.1)
        try await enterHandle(step: 5, title: "按住面板，拖出来还原")
        try await moveCursor(to: grabPoint(panel.frame), duration: 0.35)
        setPressed(true)
        try await pause(0.2)
        dock.beginDrag()
        try await moveWindow(to: free, duration: 1.7)
        try await pause(0.2)
        setPressed(false)
        dock.guideHover(at: grabPoint(panel.frame)); dock.endDrag()
        setStep(5, "已恢复普通悬浮窗", "脱离边缘后，可以自由摆放")
        try await pause(1.1)
        cursor?.orderOut(nil)
        dock.detach()
        try await moveWindow(to: restorableFrame().origin, duration: 0.45, tracksCursor: false)
        dock.endGuide()
        if originallyAttached { dock.snapIfNearEdge() }
        state.title = "演示完成"
        state.detail = "窗口已回到原位，可以重播或开始体验"
        state.finished = true
    }

    private func enterHandle(step: Int, title: String) async throws {
        guard let panel else { throw CancellationError() }
        setStep(step, title, step == 5 ? "拖离屏幕边缘，就能恢复自由悬浮" : "使用的是平时的真实展开效果")
        let point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        try await moveCursor(to: point, duration: 0.5)
        dock.guideHover(at: point)
        try await pause(0.45)
    }

    func finish(markComplete: Bool = true, notify: Bool = true) {
        guard !closed else { return }
        closed = true
        task?.cancel(); task = nil
        dock.detach()
        panel?.setFrame(restorableFrame(), display: true)
        dock.endGuide()
        if originallyAttached { dock.snapIfNearEdge() }
        (panel as? FloatingTokenPanelWindow)?.onGuideInteraction = nil
        cursor?.orderOut(nil); callout?.orderOut(nil)
        cursor?.close(); callout?.close()
        cursor = nil; callout = nil; cursorView = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if notify { complete(markComplete) }
    }

    private func restorableFrame() -> NSRect {
        let area = NSScreen.screens.max { a, b in
            let ar = a.visibleFrame.intersection(original), br = b.visibleFrame.intersection(original)
            return ar.width * ar.height < br.width * br.height
        }?.visibleFrame ?? workArea
        return FloatingEdgeDockController.restoredFrame(original, in: area)
    }
    private func auxiliary(size: NSSize, interactive: Bool) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = interactive; p.ignoresMouseEvents = !interactive
        p.level = NSWindow.Level(rawValue: (panel?.level.rawValue ?? NSWindow.Level.floating.rawValue) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }
    private func setStep(_ index: Int, _ title: String, _ detail: String) {
        state.step = index; state.title = title; state.detail = detail
    }
    private func grabPoint(_ frame: NSRect) -> NSPoint { NSPoint(x: frame.midX, y: frame.maxY - 20) }
    private func setPressed(_ value: Bool) { pressed = value; cursorView?.rootView = FloatingGuideCursor(pressed: value) }
    private func positionCursor(_ point: NSPoint) { cursor?.setFrameOrigin(NSPoint(x: point.x - 18, y: point.y - 39)) }
    private func cursorPoint() -> NSPoint { let frame = cursor?.frame ?? .zero; return NSPoint(x: frame.minX + 18, y: frame.minY + 39) }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation() }
    private func animate(duration: Double, update: (CGFloat) -> Void) async throws {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.04 : duration
        let start = Date()
        while true {
            try Task.checkCancellation()
            let t = min(1, Date().timeIntervalSince(start) / duration)
            update(CGFloat(t * t * (3 - 2 * t)))
            if t >= 1 { return }
            try await Task.sleep(for: .milliseconds(16))
        }
    }
    private func moveWindow(to target: NSPoint, duration: Double, tracksCursor: Bool = true) async throws {
        guard let panel else { throw CancellationError() }
        let start = panel.frame.origin
        try await animate(duration: duration) { progress in
            panel.setFrameOrigin(NSPoint(x: start.x + (target.x - start.x) * progress, y: start.y + (target.y - start.y) * progress))
            if tracksCursor { positionCursor(grabPoint(panel.frame)) }
        }
    }
    private func moveCursor(to target: NSPoint, duration: Double) async throws {
        let start = cursorPoint()
        try await animate(duration: duration) { progress in
            positionCursor(NSPoint(x: start.x + (target.x - start.x) * progress, y: start.y + (target.y - start.y) * progress))
        }
    }
}

@MainActor
private final class FloatingRealGuideCalloutState: ObservableObject {
    @Published var step = 1
    @Published var title = "准备演示贴边吸附"
    @Published var detail = ""
    @Published var finished = false
}
private struct FloatingRealGuideCallout: View {
    @ObservedObject var state: FloatingRealGuideCalloutState
    let replay: () -> Void
    let finish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.finished ? "悬浮窗使用指南" : "贴边演示 · \(state.step)/5").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if state.finished { Button("重播", action: replay).buttonStyle(.plain).font(.system(size: 10)) }
            }
            Text(state.title).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .bottom) {
                Text(state.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 5)
                Button(state.finished ? "开始体验" : "跳过", action: finish).font(.system(size: 10)).buttonStyle(.bordered)
            }
        }.foregroundStyle(Color(red: 0.08, green: 0.22, blue: 0.37))
            .padding(12).frame(width: 286, height: 100, alignment: .topLeading)
            .background(Color(red: 0.89, green: 0.94, blue: 1), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.3), lineWidth: 1) }
    }
}
private struct FloatingGuideCursor: View {
    let pressed: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            if pressed {
                Circle().fill(Color.blue.opacity(0.15)).overlay { Circle().stroke(Color.blue.opacity(0.7), lineWidth: 1) }
                    .frame(width: 26, height: 26).offset(x: 5, y: 13)
                Text("按住").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(red: 0.12, green: 0.39, blue: 0.68), in: Capsule()).offset(x: 5, y: 1)
            }
            Image(systemName: "cursorarrow").font(.system(size: 25, weight: .medium))
                .foregroundStyle(pressed ? Color(red: 0.08, green: 0.31, blue: 0.55) : .black)
                .shadow(color: .white, radius: 1).offset(x: 18, y: 26)
        }.frame(width: 54, height: 65).accessibilityHidden(true)
    }
}
