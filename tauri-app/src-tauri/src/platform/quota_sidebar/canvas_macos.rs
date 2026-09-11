//! Keep WebKit's frame unchanged throughout the native clipping animation.
use objc2::{rc::Retained, MainThreadOnly};
use objc2_app_kit::{NSAutoresizingMaskOptions, NSColor, NSView, NSWindow, NSUserInterfaceItemIdentification};
use objc2_foundation::{MainThreadMarker, NSObjectProtocol, NSEdgeInsets, NSPoint, NSRect, NSSize, NSString};

const CANVAS_ID: &str = "quota-sidebar-canvas";
const WIDTH: f64 = 88.0;
const HEIGHT: f64 = 560.0;

fn webview(view: &NSView) -> Option<Retained<NSView>> {
    for child in view.subviews().iter() {
        if child.isKindOfClass(objc2::class!(WKWebView)) { return Some(child); }
        if let Some(found) = webview(&child) { return Some(found); }
    }
    None
}

/// The native window supplies the clip. WebKit must not reinterpret the clipped
/// top as titlebar space and insert an additional, asynchronously updated inset.
fn configure_insets(web: &NSView) {
    unsafe {
        let zero = NSEdgeInsets { top: 0.0, left: 0.0, bottom: 0.0, right: 0.0 };
        if web.respondsToSelector(objc2::sel!(setObscuredContentInsets:)) {
            // WebKit's public macOS 26 setter returns early for equal insets.
            // Establish manual ownership before the window is ever shown.
            let _: () = objc2::msg_send![web, setObscuredContentInsets: NSEdgeInsets { top: 1.0, ..zero }];
            let _: () = objc2::msg_send![web, setObscuredContentInsets: zero];
        } else if web.respondsToSelector(objc2::sel!(_setAutomaticallyAdjustsContentInsets:)) {
            let _: () = objc2::msg_send![web, _setAutomaticallyAdjustsContentInsets: false];
        }
    }
}

pub(super) fn set_frame(native: &NSWindow, rect: NSRect) -> Result<(), String> {
    let content = native.contentView().ok_or("Sidebar has no content view")?;
    let canvas = if let Some(canvas) = content.subviews().iter()
        .find(|view| view.identifier().is_some_and(|id| id.to_string() == CANVAS_ID)) {
        canvas
    } else {
        let web = webview(&content).ok_or("Sidebar webview unavailable")?;
        let mtm = MainThreadMarker::new().ok_or("Sidebar layout requires the main thread")?;
        let canvas = NSView::initWithFrame(NSView::alloc(mtm), NSRect::new(NSPoint::ZERO, NSSize::new(WIDTH, HEIGHT)));
        canvas.setIdentifier(Some(&NSString::from_str(CANVAS_ID)));
        canvas.setAutoresizingMask(NSAutoresizingMaskOptions::empty());
        canvas.setWantsLayer(true);
        web.removeFromSuperview();
        web.setAutoresizingMask(NSAutoresizingMaskOptions::empty());
        web.setFrame(NSRect::new(NSPoint::ZERO, NSSize::new(WIDTH, HEIGHT)));
        configure_insets(&web);
        canvas.addSubview(&web);
        content.addSubview(&canvas);
        canvas
    };
    let left = native.screen().is_some_and(|screen| (rect.origin.x - screen.visibleFrame().origin.x).abs() < 1.0);
    // Moving WKWebView itself causes WebKit to update its visible viewport on
    // a later render transaction. Only move this plain AppKit canvas instead.
    unsafe {
        let _: () = objc2::msg_send![objc2::class!(CATransaction), begin];
        let _: () = objc2::msg_send![objc2::class!(CATransaction), setDisableActions: true];
    }
    if native.frame() != rect { native.setFrame_display(rect, false); }
    content.setWantsLayer(true);
    // AppKit rounds native frames to display pixels. Anchor the canvas to the
    // accepted content bounds, not the unrounded requested animation sample.
    let size = content.bounds().size;
    canvas.setFrameOrigin(NSPoint::new(if left { 0.0 } else { size.width - WIDTH }, (size.height - HEIGHT) / 2.0));
    unsafe {
        let layer: *mut objc2::runtime::AnyObject = objc2::msg_send![&*content, layer];
        let color = NSColor::colorWithSRGBRed_green_blue_alpha(0.031, 0.039, 0.035, 1.0);
        let cg: *const std::ffi::c_void = objc2::msg_send![&*color, CGColor];
        let _: () = objc2::msg_send![layer, setBackgroundColor: cg];
        let _: () = objc2::msg_send![layer, setMasksToBounds: true];
        let _: () = objc2::msg_send![layer, setCornerRadius: (8.0 + (size.width - 16.0) * 14.0 / 72.0).clamp(8.0, 22.0)];
        let _: () = objc2::msg_send![layer, setMaskedCorners: if left { 10_usize } else { 5_usize }];
        let _: () = objc2::msg_send![objc2::class!(CATransaction), commit];
    }
    Ok(())
}
