import SwiftUI

struct FloatingUnreadEffectOverlay: View {
    let effect: FloatingPanelUnreadEffect
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    var body: some View {
        switch effect {
        case .off:
            EmptyView()
        case .ripple:
            FloatingUnreadRippleOverlay(color: color, cornerRadius: cornerRadius, scale: scale)
        case .shimmer:
            FloatingUnreadShimmerOverlay(color: color, cornerRadius: cornerRadius, scale: scale)
        }
    }
}
