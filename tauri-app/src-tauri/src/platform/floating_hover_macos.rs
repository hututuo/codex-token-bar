//! Passive AppKit tracking continues while another application has focus.
//! The view owns no timers, never takes first responder and never handles clicks.
use std::cell::RefCell;
use objc2::{define_class, msg_send, rc::Retained, DeclaredClass, MainThreadOnly, AnyThread};
use objc2_app_kit::{NSEvent, NSAutoresizingMaskOptions, NSTrackingArea, NSTrackingAreaOptions, NSView, NSWindow};
use objc2_foundation::{MainThreadMarker, NSObjectProtocol, NSPoint};
use tauri::{Emitter, Manager};

pub struct HoverIvars {
    app: tauri::AppHandle,
    area: RefCell<Option<Retained<NSTrackingArea>>>,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[ivars = HoverIvars]
    struct FloatingHoverView;

    unsafe impl NSObjectProtocol for FloatingHoverView {}
    impl FloatingHoverView {
        #[unsafe(method_id(hitTest:))]
        fn hit_test(&self, _point: NSPoint) -> Option<Retained<NSView>> { None }

        #[unsafe(method(updateTrackingAreas))]
        fn update_tracking_areas(&self) {
            unsafe { let _: () = msg_send![super(self), updateTrackingAreas]; }
            if let Some(area) = self.ivars().area.borrow_mut().take() { self.removeTrackingArea(&area); }
            let area = unsafe { NSTrackingArea::initWithRect_options_owner_userInfo(
                NSTrackingArea::alloc(), self.bounds(),
                NSTrackingAreaOptions::MouseEnteredAndExited | NSTrackingAreaOptions::ActiveAlways
                    | NSTrackingAreaOptions::InVisibleRect,
                Some(self), None,
            ) };
            self.addTrackingArea(&area);
            *self.ivars().area.borrow_mut() = Some(area);
        }

        #[unsafe(method(mouseEntered:))]
        fn mouse_entered(&self, _event: &NSEvent) {
            let _ = self.ivars().app.emit_to("floating", "floating-native-hover", true);
        }
        #[unsafe(method(mouseExited:))]
        fn mouse_exited(&self, _event: &NSEvent) {
            let _ = self.ivars().app.emit_to("floating", "floating-native-hover", false);
        }
    }
);

pub fn install(window: &tauri::WebviewWindow) -> Result<(), String> {
    let mtm = MainThreadMarker::new().ok_or("Floating hover installation requires the main thread")?;
    let raw = window.ns_window().map_err(|error| error.to_string())?;
    let native = unsafe { &*raw.cast::<NSWindow>() };
    let content = native.contentView().ok_or("Floating window has no content view")?;
    let allocated = FloatingHoverView::alloc(mtm).set_ivars(HoverIvars {
        app: window.app_handle().clone(), area: RefCell::new(None),
    });
    let view: Retained<FloatingHoverView> = unsafe { msg_send![super(allocated), initWithFrame: content.bounds()] };
    view.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);
    content.addSubview(&view);
    view.updateTrackingAreas();
    Ok(())
}
