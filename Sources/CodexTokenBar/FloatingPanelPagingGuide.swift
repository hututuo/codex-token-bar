import AppKit
import SwiftUI

enum FloatingPanelGuidePage: String, Equatable, Sendable {
    case paging
    case runningModels
}

enum FloatingPanelPagingGuideState {
    static let setupGuideCompletedKey = "setupGuideCompletedV01"
    static let pagingLearnedRevision = 4

    static func pages(
        completedRevision: Int,
        hasPagedRows: Bool,
        hasRunningThreadDetailsTarget: Bool
    ) -> [FloatingPanelGuidePage] {
        guard completedRevision < FloatingPanelContentVisibility.currentPagingGuideRevision else {
            return []
        }
        var pages: [FloatingPanelGuidePage] = []
        if completedRevision < pagingLearnedRevision, hasPagedRows {
            pages.append(.paging)
        }
        if hasRunningThreadDetailsTarget {
            pages.append(.runningModels)
        }
        return pages
    }

    static func shouldPresent(
        setupGuideCompleted: Bool,
        completedRevision: Int,
        hasPagedRows: Bool,
        hasRunningThreadDetailsTarget: Bool
    ) -> Bool {
        setupGuideCompleted
            && !pages(
                completedRevision: completedRevision,
                hasPagedRows: hasPagedRows,
                hasRunningThreadDetailsTarget: hasRunningThreadDetailsTarget
            ).isEmpty
    }

    static func runningThreadSummary(
        live: RunningThreadSummary,
        guidePresented: Bool,
        page: FloatingPanelGuidePage
    ) -> RunningThreadSummary {
        guard guidePresented, page == .runningModels else { return live }
        return .guideModelDetailsDemo
    }
}

@MainActor
final class FloatingPanelPagingGuideSessionState: ObservableObject {
    struct Completion: Equatable {
        let revision: Int
        let showsArrowGlyphs: Bool
    }

    @Published private(set) var completion: Completion?

    func complete(revision: Int, showsArrowGlyphs: Bool) {
        completion = Completion(
            revision: revision,
            showsArrowGlyphs: showsArrowGlyphs
        )
    }

    func completion(for revision: Int) -> Completion? {
        completion?.revision == revision ? completion : nil
    }
}

struct FloatingPanelPagingGuide: View {
    let page: FloatingPanelGuidePage
    let isLastPage: Bool
    @Binding var showsArrowGlyphs: Bool
    let scale: CGFloat
    let appearance: FloatingPanelAppearance
    let surfaceWidth: CGFloat
    let surfaceHeight: CGFloat
    let targetY: CGFloat
    let targetYs: [CGFloat]
    let calloutTargetY: CGFloat
    let cardY: CGFloat
    let showsDemoModelUsage: Bool
    let modelTargetX: CGFloat
    let modelTargetY: CGFloat
    let modelTargetWidth: CGFloat
    let onAdvance: () -> Void

    @State private var arrowCueEmphasized = false
    @State private var arrowCueFadeTask: Task<Void, Never>?
    @State private var completionTriggered = false

    private let guideSurface = Color(red: 0.882, green: 0.925, blue: 0.980)
    private let guidePrimaryText = Color(red: 0.063, green: 0.169, blue: 0.302)
    private let guideSecondaryText = Color(red: 0.208, green: 0.329, blue: 0.451)
    private let guideAccent = Color(red: 0.078, green: 0.361, blue: 0.694)
    private let guideEdgeShade = Color(red: 0.235, green: 0.255, blue: 0.282)
    private static let quotaPaceGuideImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "FloatingQuotaPaceGuide",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if page == .paging {
                    pagingGuideContent(in: proxy.size)
                } else {
                    runningModelsGuideContent(in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            refreshArrowCueEmphasis(isVisible: showsArrowGlyphs)
        }
        .onChange(of: showsArrowGlyphs) { _, isVisible in
            refreshArrowCueEmphasis(isVisible: isVisible)
        }
        .onDisappear {
            arrowCueFadeTask?.cancel()
        }
        .opacity(completionTriggered ? 0 : 1)
        .allowsHitTesting(!completionTriggered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page == .paging ? "悬浮窗翻页引导" : "运行模型详情引导")
    }

    private func advanceImmediately() {
        guard !completionTriggered else { return }
        if isLastPage {
            completionTriggered = true
        }
        onAdvance()
    }

    @ViewBuilder
    private func pagingGuideContent(in size: CGSize) -> some View {
        edgeShadow(in: size, isLeading: true)
        edgeShadow(in: size, isLeading: false)
        ForEach(Array((targetYs.isEmpty ? [targetY] : targetYs).prefix(2).enumerated()), id: \.offset) { _, rowY in
            if showsArrowGlyphs {
                edgeArrowCue(in: size, isLeading: true, targetY: rowY)
                edgeArrowCue(in: size, isLeading: false, targetY: rowY)
            }
            animatedPointer(in: size, targetY: rowY)
        }
        quotaPaceCallout(in: size)

        let cardWidth = min(
            max(0, surfaceWidth - 16.scaled(by: scale)),
            180.scaled(by: scale)
        )
        VStack(spacing: 3.scaled(by: scale)) {
            Text("点两侧即可翻页")
                .font(.system(size: 11.4.scaled(by: scale), weight: .bold))
                .foregroundStyle(guidePrimaryText)
            Text("点击阴影边缘试一下")
                .font(.system(size: 8.4.scaled(by: scale), weight: .semibold))
                .foregroundStyle(guideSecondaryText)

            if showsDemoModelUsage {
                Text("悬浮窗数据为示例")
                    .font(.system(size: 7.2.scaled(by: scale), weight: .semibold))
                    .foregroundStyle(guideSecondaryText.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .help("仅用于引导展示，不会写入真实统计")
            }

            HStack(spacing: 7.scaled(by: scale)) {
                Button {
                    showsArrowGlyphs.toggle()
                } label: {
                    HStack(spacing: 3.scaled(by: scale)) {
                        Image(systemName: showsArrowGlyphs ? "checkmark.square.fill" : "square")
                            .font(.system(size: 10.scaled(by: scale), weight: .semibold))
                            .foregroundStyle(guideAccent)
                        Text("显示翻页箭头")
                            .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                            .foregroundStyle(guidePrimaryText)
                    }
                    .frame(
                        minWidth: 88.scaled(by: scale),
                        minHeight: 24.scaled(by: scale)
                    )
                    .background(
                        Color.white.opacity(0.001),
                        in: RoundedRectangle(cornerRadius: 7.scaled(by: scale), style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7.scaled(by: scale), style: .continuous)
                            .stroke(guideAccent.opacity(0.34), lineWidth: 0.8.scaled(by: scale))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7.scaled(by: scale), style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsArrowGlyphs ? "已开启" : "已关闭")
                .help("显示翻页箭头")

                guideAdvanceButton
            }
        }
        .padding(.horizontal, 9.scaled(by: scale))
        .padding(.vertical, 7.scaled(by: scale))
        .frame(width: cardWidth)
        .background(
            guideSurface,
            in: RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
                .stroke(guideAccent.opacity(0.62), lineWidth: 0.9.scaled(by: scale))
        )
        .shadow(color: guidePrimaryText.opacity(0.34), radius: 11.scaled(by: scale), y: 4.scaled(by: scale))
        .contentShape(RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous))
        .position(x: surfaceWidth / 2, y: cardY)
    }

    @ViewBuilder
    private func runningModelsGuideContent(in size: CGSize) -> some View {
        let demoWidth = FloatingTokenPanelMetrics.runningModelDetailsWidth.scaled(by: scale)
        let demoHeight = FloatingTokenPanelMetrics.runningModelDetailsHeight(
            rowCount: RunningThreadSummary.guideModelDetailsDemo.runningModelDetailsRowUnits
        ).scaled(by: scale)
        let demoX = surfaceWidth
            + FloatingTokenPanelMetrics.runningModelDetailsGap.scaled(by: scale)
            + demoWidth / 2
        let demoY = min(
            max(modelTargetY, demoHeight / 2 + 6.scaled(by: scale)),
            size.height - demoHeight / 2 - 6.scaled(by: scale)
        )
        let targetHeight = 22.scaled(by: scale)
        let connectorStart = modelTargetX + modelTargetWidth / 2
        let connectorEnd = demoX - demoWidth / 2
        let connectorWidth = max(0, connectorEnd - connectorStart)

        RoundedRectangle(cornerRadius: 6.scaled(by: scale), style: .continuous)
            .fill(guideAccent.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 6.scaled(by: scale), style: .continuous)
                    .stroke(guideAccent, lineWidth: 1.2.scaled(by: scale))
            }
            .frame(width: modelTargetWidth, height: targetHeight)
            .position(x: modelTargetX, y: modelTargetY)
            .allowsHitTesting(false)

        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.6) / 1.6
            let pressing = phase > 0.52 && phase < 0.72
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 16.scaled(by: scale), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(guideAccent)
                .shadow(color: Color.white.opacity(0.78), radius: 2.scaled(by: scale))
                .scaleEffect(pressing ? 0.84 : 1)
                .position(
                    x: modelTargetX + 8.scaled(by: scale),
                    y: modelTargetY + 8.scaled(by: scale)
                )
        }
        .allowsHitTesting(false)

        Rectangle()
            .fill(guideAccent)
            .frame(width: connectorWidth, height: 2.scaled(by: scale))
            .position(x: connectorStart + connectorWidth / 2, y: modelTargetY)
            .allowsHitTesting(false)
        Image(systemName: "chevron.right")
            .font(.system(size: 11.scaled(by: scale), weight: .heavy))
            .foregroundStyle(guideAccent)
            .position(x: connectorEnd - 4.scaled(by: scale), y: modelTargetY)
            .allowsHitTesting(false)

        FloatingRunningThreadModelDetailsCard(
            summary: .guideModelDetailsDemo,
            scale: scale,
            width: demoWidth,
            height: demoHeight,
            appearance: appearance,
            isDemo: true
        )
        .position(x: demoX, y: demoY)
        .allowsHitTesting(false)

        VStack(spacing: 4.scaled(by: scale)) {
            Text("点击“主 / 子”查看模型")
                .font(.system(size: 11.4.scaled(by: scale), weight: .bold))
                .foregroundStyle(guidePrimaryText)
            Text("右侧按主线程分组显示模型和思考强度；悬停主线程可查看会话标题")
                .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                .foregroundStyle(guideSecondaryText)
                .multilineTextAlignment(.center)
            guideAdvanceButton
        }
        .padding(.horizontal, 9.scaled(by: scale))
        .padding(.vertical, 7.scaled(by: scale))
        .frame(width: min(surfaceWidth - 16.scaled(by: scale), 200.scaled(by: scale)))
        .background(
            guideSurface,
            in: RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
                .stroke(guideAccent.opacity(0.62), lineWidth: 0.9.scaled(by: scale))
        }
        .shadow(color: guidePrimaryText.opacity(0.34), radius: 11.scaled(by: scale), y: 4.scaled(by: scale))
        .position(x: surfaceWidth / 2, y: cardY)
    }

    private var guideAdvanceButton: some View {
        Button(action: advanceImmediately) {
            Text(isLastPage ? "开始体验" : "下一步")
                .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    minWidth: 58.scaled(by: scale),
                    minHeight: 24.scaled(by: scale)
                )
                .background(
                    guideAccent,
                    in: RoundedRectangle(cornerRadius: 7.scaled(by: scale), style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: 7.scaled(by: scale), style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(isLastPage ? "关闭引导并保存选择" : "查看下一项引导")
    }

    private func edgeShadow(in size: CGSize, isLeading: Bool) -> some View {
        return Rectangle()
        .fill(guideEdgeShade.opacity(0.24))
        .frame(width: 24.scaled(by: scale), height: surfaceHeight)
        .position(
            x: isLeading ? 12.scaled(by: scale) : surfaceWidth - 12.scaled(by: scale),
            y: surfaceHeight / 2
        )
        .shadow(
            color: guideEdgeShade.opacity(0.38),
            radius: 6.scaled(by: scale),
            x: (isLeading ? 4 : -4).scaled(by: scale)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edgeArrowCue(in size: CGSize, isLeading: Bool, targetY: CGFloat) -> some View {
        let cueColor = arrowCueEmphasized ? guideAccent : guideEdgeShade.opacity(0.72)
        return RoundedRectangle(cornerRadius: 5.scaled(by: scale), style: .continuous)
        .fill(cueColor.opacity(arrowCueEmphasized ? 0.10 : 0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 5.scaled(by: scale), style: .continuous)
                .stroke(cueColor, lineWidth: 1.scaled(by: scale))
        }
        .frame(width: 18.scaled(by: scale), height: 24.scaled(by: scale))
        .position(
            x: isLeading ? 9.scaled(by: scale) : surfaceWidth - 9.scaled(by: scale),
            y: min(max(targetY, 12.scaled(by: scale)), size.height - 12.scaled(by: scale))
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func refreshArrowCueEmphasis(isVisible: Bool) {
        arrowCueFadeTask?.cancel()
        guard isVisible else {
            arrowCueEmphasized = false
            return
        }
        arrowCueEmphasized = true
        arrowCueFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(950))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.85)) {
                arrowCueEmphasized = false
            }
        }
    }

    private func animatedPointer(in size: CGSize, targetY: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let motion = pointerMotion(at: context.date)
            let targetX = max(0, surfaceWidth / 2 - 24.scaled(by: scale))
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 16.scaled(by: scale), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(guideAccent)
                .shadow(color: Color.white.opacity(0.72), radius: 2.scaled(by: scale))
                .scaleEffect(motion.isClicking ? 0.84 : 1)
                .position(
                    x: surfaceWidth / 2 + targetX * motion.direction * motion.progress,
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

    private func quotaPaceCallout(in size: CGSize) -> some View {
        let calloutWidth = min(
            FloatingTokenPanelMetrics.pagingGuideCalloutWidth.scaled(by: scale),
            max(0, size.width - surfaceWidth - 22.scaled(by: scale))
        )
        let imageWidth = max(0, calloutWidth - 14.scaled(by: scale))
        let estimatedCardHeight = imageWidth * (2.0 / 3.0)
            + 14.scaled(by: scale)
            + 2.scaled(by: scale)
        let safeInset = 6.scaled(by: scale)
        let minimumCardY = estimatedCardHeight / 2 + safeInset
        let maximumCardY = max(minimumCardY, size.height - estimatedCardHeight / 2 - safeInset)
        let calloutCardY = min(max(calloutTargetY, minimumCardY), maximumCardY)
        return ZStack {
            if let quotaPaceGuideImage = Self.quotaPaceGuideImage {
                Image(nsImage: quotaPaceGuideImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: max(0, calloutWidth - 14.scaled(by: scale)))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 8.scaled(by: scale),
                            style: .continuous
                        )
                    )
                    .padding(7.scaled(by: scale))
                    .background(
                        guideSurface,
                        in: RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11.scaled(by: scale), style: .continuous)
                            .stroke(guideAccent.opacity(0.62), lineWidth: 0.9.scaled(by: scale))
                    }
                    .shadow(color: guidePrimaryText.opacity(0.30), radius: 10.scaled(by: scale), y: 4.scaled(by: scale))
                    .position(
                        x: surfaceWidth + 18.scaled(by: scale) + calloutWidth / 2,
                        y: calloutCardY
                    )
                    .accessibilityLabel("7d 余量与均速差值示意图")
            }
            Rectangle()
                .fill(guideAccent)
                .frame(width: 84.scaled(by: scale), height: 2.scaled(by: scale))
                .position(
                    x: surfaceWidth - 18.scaled(by: scale),
                    y: calloutTargetY
                )
            Image(systemName: "chevron.left")
                .font(.system(size: 13.scaled(by: scale), weight: .heavy))
                .foregroundStyle(guideAccent)
                .position(
                    x: surfaceWidth - 60.scaled(by: scale),
                    y: calloutTargetY
                )
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
