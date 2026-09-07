import AppKit
import SwiftUI

/// A plain native view owns the window bounds. The nested SwiftUI host renders
/// inside those bounds without participating in NSWindow content-size policy.
@MainActor
final class FloatingPanelHostingController<Content: View>: NSViewController {
    let hostingController: NSHostingController<Content>

    init(rootView: Content) {
        hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        hostingController.sizingOptions = []
        hostingController.safeAreaRegions = []
        addChild(hostingController)
        let container = NSView(frame: .zero)
        container.autoresizingMask = [.width, .height]
        let hostedView = hostingController.view
        hostedView.frame = container.bounds
        hostedView.autoresizingMask = [.width, .height]
        container.addSubview(hostedView)
        view = container
    }

    required init?(coder: NSCoder) { nil }

    var rootView: Content {
        get { hostingController.rootView }
        set { hostingController.rootView = newValue }
    }
}
