//! Every animation frame is also the true native input frame.
use super::{placement, SidebarFrame, WebviewWindow, STATE};
use placement::Geometry;
use std::sync::{Mutex, OnceLock, atomic::{AtomicBool, Ordering}};
use std::time::Instant;

#[derive(Clone)]
struct Animation { from: SidebarFrame, target: Geometry, started_ms: f64, duration_ms: f64, snapping: bool }
#[derive(Default)]
struct Controller { revision: u64, active: Option<Animation> }
static REDUCED: AtomicBool = AtomicBool::new(false);
static MOTION: Mutex<Controller> = Mutex::new(Controller { revision: 0, active: None });
fn clock_ms() -> f64 { static START: OnceLock<Instant> = OnceLock::new(); START.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0 }

fn environment_matches(a: &Geometry, b: &Geometry) -> bool {
    a.screen_id == b.screen_id && a.work == b.work && a.scale == b.scale && a.side == b.side && a.center == b.center
}
fn frames_near(a: SidebarFrame, b: SidebarFrame) -> bool {
    [(a.x - b.x), (a.y - b.y), (a.width - b.width), (a.height - b.height)].iter().all(|d| d.abs() <= 0.75)
}
fn easing(t: f64, expanding: bool) -> f64 {
    if t <= 0.0 { return 0.0; }
    if t >= 1.0 { return 1.0; }
    if expanding { (1.0 - (1.0 + 8.0 * t) * (-8.0 * t).exp()) / (1.0 - 9.0 * (-8.0_f64).exp()) }
    else { 1.0 - (1.0 - t).powi(3) }
}
fn animated_frame(animation: &Animation, now_ms: f64) -> SidebarFrame {
    let t = ((now_ms - animation.started_ms) / animation.duration_ms).clamp(0.0, 1.0);
    if t >= 1.0 { return animation.target.rail; }
    let target = &animation.target;
    if animation.snapping {
        let p = easing(t, false);
        let mix = |a: f64, b: f64| a + (b - a) * p;
        return SidebarFrame { x: mix(animation.from.x, target.rail.x), y: mix(animation.from.y, target.rail.y),
            width: mix(animation.from.width, target.rail.width), height: mix(animation.from.height, target.rail.height) };
    }
    let p = easing(t, animation.duration_ms > 300.0);
    let width = (animation.from.width + (target.rail.width - animation.from.width) * p).clamp(1.0, target.work.width.max(1.0));
    let height = (animation.from.height + (target.rail.height - animation.from.height) * p).clamp(1.0, target.work.height.max(1.0));
    SidebarFrame { x: if target.side == "left" { target.work.x } else { target.work.x + target.work.width - width },
        y: (target.center - height / 2.0).clamp(target.work.y, target.work.y + target.work.height - height), width, height }
}
impl Controller {
    fn cancel(&mut self) { self.revision = self.revision.wrapping_add(1); self.active = None; }
    fn request(&mut self, current: SidebarFrame, target: Geometry, reduced: bool, now_ms: f64) -> Option<u64> {
        if !reduced && self.active.as_ref().is_some_and(|a| a.target == target) { return None; }
        self.cancel();
        if reduced || frames_near(current, target.rail) { return None; }
        let expanding = target.rail.height > current.height || target.rail.width > current.width;
        self.active = Some(Animation { from: current, target, started_ms: now_ms, duration_ms: if expanding { 440.0 } else { 240.0 }, snapping: false });
        Some(self.revision)
    }
    fn sample(&mut self, revision: u64, now_ms: f64, current_target: &Geometry) -> Option<SidebarFrame> {
        if self.revision != revision { return None; }
        let animation = self.active.as_ref()?;
        if !environment_matches(&animation.target, current_target) { self.cancel(); return None; }
        let frame = animated_frame(animation, now_ms);
        if now_ms >= animation.started_ms + animation.duration_ms { self.active = None; }
        Some(frame)
    }
}
pub(super) fn cancel() { if let Ok(mut motion) = MOTION.lock() { motion.cancel(); } }

pub(super) fn start(rail: &WebviewWindow, detail: &WebviewWindow, side: &str, mode: super::SidebarMode, five: bool, reduced: bool, refresh_geometry: bool) -> Result<SidebarFrame, String> {
    REDUCED.store(reduced, Ordering::Relaxed);
    // Capture monitor/workarea once per intent or explicit environment refresh.
    // No disk reads or monitor enumeration occur in the frame loop.
    let target = placement::geometry(rail, side, mode, five)?;
    if mode == super::SidebarMode::Detail { placement::set_frame(detail, target.card)?; }
    begin(rail, target, reduced, refresh_geometry, false)
}

pub(super) fn snap(rail: &WebviewWindow, target: Geometry) -> Result<(), String> {
    let current = placement::window_frame(rail)?;
    let near = (current.x - target.rail.x).abs() <= 160.0 * target.scale;
    begin(rail, target, REDUCED.load(Ordering::Relaxed) || !near, false, true)?;
    Ok(())
}

fn begin(rail: &WebviewWindow, target: Geometry, reduced: bool, refresh: bool, snapping: bool) -> Result<SidebarFrame, String> {
    let current = placement::window_frame(rail)?;
    let mut motion = MOTION.lock().map_err(|e| e.to_string())?;
    let environment_changed = refresh && motion.active.as_ref().is_some_and(|a| !environment_matches(&a.target, &target));
    let revision = motion.request(current, target.clone(), reduced || environment_changed, clock_ms());
    if let Some(revision) = revision {
        if snapping { if let Some(animation) = motion.active.as_mut() { animation.snapping = true; animation.duration_ms = 220.0; } }
        let native = rail.clone();
        let period = placement::frame_period(rail);
        tauri::async_runtime::spawn(async move {
            let mut cadence = tokio::time::interval(period);
            cadence.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                cadence.tick().await;
                let frame_window = native.clone();
                match placement::on_main(&native, move || tick(&frame_window, revision)).await {
                    Ok(true) => continue,
                    Ok(false) => break,
                    Err(error) => { if let Ok(mut motion) = MOTION.lock() { if motion.revision == revision { motion.cancel(); } } eprintln!("Quota sidebar animation failed: {error}"); break; }
                }
            }
        });
    } else if motion.active.is_none() {
        placement::set_frame(rail, target.rail)?;
    }
    Ok(target.rail)
}

fn tick(rail: &WebviewWindow, revision: u64) -> Result<bool, String> {
    let enabled = STATE.lock().map_err(|e| e.to_string())?.as_ref().is_some_and(|(display, _, _)| display.quota_sidebar_enabled);
    if !enabled || placement::is_dragging() || !rail.is_visible().map_err(|e| e.to_string())? { cancel(); return Ok(false); }
    let mut motion = MOTION.lock().map_err(|e| e.to_string())?;
    if motion.revision != revision { return Ok(false); }
    let Some(target) = motion.active.as_ref().map(|a| a.target.clone()) else { return Ok(false); };
    if let Some(frame) = motion.sample(revision, clock_ms(), &target) {
        let current = placement::window_frame(rail)?;
        // Quantization avoids subpixel tail writes; the last frame is exact.
        let changed = [frame.x-current.x, frame.y-current.y, frame.width-current.width, frame.height-current.height]
            .iter().any(|d| d.abs() >= 0.25);
        if changed || motion.active.is_none() { placement::set_frame(rail, frame)?; }
    }
    Ok(motion.active.is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn target(side: &str, mode: super::super::SidebarMode, work: SidebarFrame, center: f64) -> Geometry {
        let (rail, card) = super::super::frames_for_at(work, side, mode, false, center);
        Geometry { screen_id: "main".into(), work, scale: 1.0, center: work.y + work.height * center, side: side.into(), rail, card }
    }
    fn work() -> SidebarFrame { SidebarFrame { x: -1440.0, y: 24.0, width: 1440.0, height: 1000.0 } }
    #[test]
    fn snap_preserves_partly_offscreen_release_and_finishes_exactly() {
        let end = target("right", super::super::SidebarMode::Rest, work(), 0.5);
        let mut from = end.rail; from.x += 40.0;
        let animation = Animation { from, target: end.clone(), started_ms: 0.0, duration_ms: 220.0, snapping: true };
        assert_eq!(animated_frame(&animation, 0.0), from);
        let early = animated_frame(&animation, 2.2);
        assert!(early.x > end.rail.x && (early.x - from.x).abs() < 2.0);
        assert_eq!(animated_frame(&animation, 220.0), end.rail);
    }
    #[test]
    fn expansion_has_intermediate_native_sizes_no_overshoot_and_exact_terminal_frame() {
        let end = target("right", super::super::SidebarMode::Hover, work(), 0.5);
        let start = target("right", super::super::SidebarMode::Rest, work(), 0.5).rail;
        let mut controller = Controller::default();
        let revision = controller.request(start, end.clone(), false, 0.0).unwrap();
        let early = controller.sample(revision, 40.0, &end).unwrap();
        assert!(early.width > start.width && early.width < end.rail.width);
        assert!(early.height > start.height && early.height < end.rail.height);
        let peak = controller.sample(revision, 154.0, &end).unwrap();
        assert!(peak.width < end.rail.width); assert!(peak.height < end.rail.height);
        assert!(peak.height < end.rail.height + (end.rail.height - start.height) * 0.07);
        assert_eq!(controller.sample(revision, 440.0, &end), Some(end.rail));
        assert!(controller.active.is_none()); assert_eq!(controller.sample(revision, 450.0, &end), None);
    }
    #[test]
    fn every_frame_stays_inside_workarea_on_both_edges_with_center_or_boundary_clamp() {
        for side in ["left", "right"] {
            for center in [0.0, 0.15, 0.5, 1.0] {
                for work in [work(), SidebarFrame { x: 10.5, y: -200.0, width: 82.0, height: 210.5 }] {
                    let end = target(side, super::super::SidebarMode::Hover, work, center);
                    let start = target(side, super::super::SidebarMode::Rest, work, center).rail;
                    let animation = Animation { from: start, target: end, started_ms: 0.0, duration_ms: 440.0, snapping: false };
                    for ms in (0..=440).step_by(8) {
                        let frame = animated_frame(&animation, ms as f64);
                        assert!(frame.x >= work.x); assert!(frame.x + frame.width <= work.x + work.width + 1e-8);
                        assert!(frame.y >= work.y); assert!(frame.y + frame.height <= work.y + work.height + 1e-8);
                        if side == "left" { assert_eq!(frame.x, work.x); }
                        else { assert!((frame.x + frame.width - work.x - work.width).abs() < 1e-8); }
                        if center == 0.5 { assert!((frame.y + frame.height / 2.0 - work.y - work.height / 2.0).abs() < 1e-8); }
                    }
                }
            }
        }
    }
    #[test]
    fn collapse_is_faster_monotonic_and_retarget_starts_at_the_actual_frame() {
        let hover = target("left", super::super::SidebarMode::Hover, work(), 0.5);
        let rest = target("left", super::super::SidebarMode::Rest, work(), 0.5);
        let mut controller = Controller::default();
        let old = controller.request(rest.rail, hover.clone(), false, 0.0).unwrap();
        let current = controller.sample(old, 100.0, &hover).unwrap();
        let next = controller.request(current, rest.clone(), false, 100.0).unwrap();
        assert_eq!(controller.sample(old, 110.0, &hover), None);
        assert_eq!(controller.sample(next, 100.0, &rest), Some(current));
        let middle = controller.sample(next, 200.0, &rest).unwrap();
        assert!(middle.width < current.width && middle.width > rest.rail.width);
        assert_eq!(controller.sample(next, 340.0, &rest), Some(rest.rail));
    }
    #[test]
    fn detail_and_repeated_reconcile_preserve_the_current_timeline() {
        let hover = target("left", super::super::SidebarMode::Hover, work(), 0.5);
        let detail = target("left", super::super::SidebarMode::Detail, work(), 0.5);
        let rest = target("left", super::super::SidebarMode::Rest, work(), 0.5).rail;
        assert_eq!(hover, detail);
        let mut controller = Controller::default();
        let revision = controller.request(rest, hover.clone(), false, 0.0).unwrap();
        let current = controller.sample(revision, 90.0, &hover).unwrap();
        assert_eq!(controller.request(current, detail, false, 90.0), None);
        assert_eq!(controller.revision, revision);
        assert_eq!(controller.active.as_ref().unwrap().started_ms, 0.0);
    }
    #[test]
    fn cancel_drag_disable_and_reduced_motion_invalidate_old_samples() {
        let end = target("right", super::super::SidebarMode::Hover, work(), 0.5);
        let start = target("right", super::super::SidebarMode::Rest, work(), 0.5).rail;
        let mut controller = Controller::default();
        let revision = controller.request(start, end.clone(), false, 0.0).unwrap();
        controller.cancel(); assert_eq!(controller.sample(revision, 80.0, &end), None);
        assert_eq!(controller.request(start, end.clone(), true, 90.0), None);
        assert!(controller.active.is_none());
        let second = controller.request(start, end.clone(), false, 100.0).unwrap();
        assert_eq!(controller.request(start, end.clone(), true, 110.0), None);
        assert_eq!(controller.sample(second, 120.0, &end), None);
    }
    #[test]
    fn monitor_workarea_or_scale_changes_cancel_the_old_frame_and_rounding_does_not_restart() {
        let end = target("right", super::super::SidebarMode::Hover, work(), 0.5);
        let start = target("right", super::super::SidebarMode::Rest, work(), 0.5).rail;
        for kind in [0, 1, 2] {
            let mut controller = Controller::default();
            let revision = controller.request(start, end.clone(), false, 0.0).unwrap();
            let mut changed = end.clone();
            if kind == 0 { changed.screen_id = "other".into(); }
            if kind == 1 { changed.work.height -= 24.0; }
            if kind == 2 { changed.scale = 2.0; }
            assert_eq!(controller.sample(revision, 50.0, &changed), None);
            assert!(controller.active.is_none());
        }
        let mut controller = Controller::default(); let mut rounded = end.rail; rounded.height += 0.5;
        assert_eq!(controller.request(rounded, end, false, 0.0), None);
    }
}
