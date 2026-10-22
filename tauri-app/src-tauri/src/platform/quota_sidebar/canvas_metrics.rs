//! Shared logical canvas size for production surfaces and the Windows compositor probe.
use std::sync::atomic::{AtomicU32, Ordering};
use tauri::{Emitter, WebviewWindow};

pub(super) const SIDEBAR_CANVAS_HEIGHT: f64 = 680.0;
const SIDEBAR_CANVAS_STEP: u32 = 128;
const SIDEBAR_CANVAS_MAX: u32 = 4096;
static SIDEBAR_CANVAS_HEIGHT_CURRENT: AtomicU32 = AtomicU32::new(SIDEBAR_CANVAS_HEIGHT as u32);

pub(super) fn canvas_height() -> f64 {
    SIDEBAR_CANVAS_HEIGHT_CURRENT.load(Ordering::Acquire) as f64
}

fn rounded_canvas_height(current: u32, required: f64) -> Result<u32, String> {
    if !required.is_finite() || required < 1.0 || required > SIDEBAR_CANVAS_MAX as f64 {
        return Err("Invalid quota sidebar canvas height".into());
    }
    let required = required.ceil() as u32;
    if required <= current { return Ok(current); }
    let rounded = required.div_ceil(SIDEBAR_CANVAS_STEP) * SIDEBAR_CANVAS_STEP;
    Ok(rounded.max(SIDEBAR_CANVAS_HEIGHT as u32).min(SIDEBAR_CANVAS_MAX))
}

/// Grow only before a new native target is applied. Keeping the maximum avoids
/// reallocating/reflowing the WebView canvas on every animation sample.
pub(super) fn ensure_canvas_height(required: f64) -> Result<f64, String> {
    loop {
        let current = SIDEBAR_CANVAS_HEIGHT_CURRENT.load(Ordering::Acquire);
        let next = rounded_canvas_height(current, required)?;
        if next == current { return Ok(current as f64); }
        if SIDEBAR_CANVAS_HEIGHT_CURRENT.compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire).is_ok() {
            return Ok(next as f64);
        }
    }
}

pub(super) fn publish_canvas_height(window: &WebviewWindow) -> Result<(), String> {
    window.emit("quota-sidebar-canvas-changed", canvas_height()).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canvas_growth_keeps_minimum_and_rounds_up_in_128_point_steps() {
        assert_eq!(rounded_canvas_height(680, 500.0).unwrap(), 680);
        assert_eq!(rounded_canvas_height(680, 680.0).unwrap(), 680);
        assert_eq!(rounded_canvas_height(680, 681.0).unwrap(), 768);
        assert_eq!(rounded_canvas_height(768, 768.0).unwrap(), 768);
        assert_eq!(rounded_canvas_height(768, 769.0).unwrap(), 896);
        assert_eq!(rounded_canvas_height(3968, 4096.0).unwrap(), 4096);
        assert!(rounded_canvas_height(680, 4097.0).is_err());
        assert!(rounded_canvas_height(680, f64::NAN).is_err());
    }
}
