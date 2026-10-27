//! Pixel geometry for the fixed sidebar canvas, with a 680px minimum height.
use super::{SidebarFrame, SIDEBAR_CANVAS_HEIGHT};

pub(super) const BASE_CANVAS_WIDTH: f64 = 88.0;
pub(super) const PREVIEW_CANVAS_WIDTH: f64 = 112.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CanvasFrame {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub canvas_width: i32,
    pub canvas_height: i32,
    pub canvas_x: i32,
    pub canvas_y: i32,
    pub clip_x: i32,
    pub clip_y: i32,
    pub radius: i32,
}

pub(super) fn layout(frame: SidebarFrame, left: bool, scale: f64) -> Result<CanvasFrame, String> {
    layout_with_canvas_width_and_height(frame, left, scale, BASE_CANVAS_WIDTH, super::canvas_metrics::canvas_height())
}

pub(super) fn layout_with_canvas_height(frame: SidebarFrame, left: bool, scale: f64, logical_canvas_height: f64) -> Result<CanvasFrame, String> {
    layout_with_canvas_width_and_height(frame, left, scale, BASE_CANVAS_WIDTH, logical_canvas_height)
}

pub(super) fn layout_with_canvas_width_and_height(frame: SidebarFrame, left: bool, scale: f64, logical_canvas_width: f64, logical_canvas_height: f64) -> Result<CanvasFrame, String> {
    if !scale.is_finite() || scale <= 0.0 || scale > 16.0
        || [frame.x, frame.y, frame.width, frame.height].iter()
            .any(|v| !v.is_finite() || v.abs() > (i32::MAX / 2) as f64)
        || !logical_canvas_width.is_finite() || !(BASE_CANVAS_WIDTH..=PREVIEW_CANVAS_WIDTH).contains(&logical_canvas_width)
        || !logical_canvas_height.is_finite() || !(SIDEBAR_CANVAS_HEIGHT..=4096.0).contains(&logical_canvas_height)
        || frame.width < 1.0 || frame.height < 1.0
    {
        return Err("Invalid sidebar canvas geometry".into());
    }
    let width = frame.width.round() as i32;
    let height = frame.height.round() as i32;
    let canvas_width = (logical_canvas_width * scale).round() as i32;
    let canvas_height = (logical_canvas_height * scale).round() as i32;
    if height > canvas_height { return Err("Sidebar clip exceeds its fixed canvas".into()); }
    let x = if left { frame.x.round() as i32 } else { (frame.x + frame.width).round() as i32 - width };
    let y = frame.y.round() as i32;
    let canvas_x = if left { x } else { x + width - canvas_width };
    let canvas_y = (frame.y + frame.height / 2.0 - canvas_height as f64 / 2.0).round() as i32;
    Ok(CanvasFrame {
        // Round the anchored edge, then derive the origin: separately rounding
        // x and width can move the right edge by one physical pixel.
        x, y,
        width, height, canvas_width, canvas_height,
        canvas_x, canvas_y, clip_x: x - canvas_x, clip_y: y - canvas_y,
        radius: ((8.0 + (width as f64 / scale - 16.0) * 14.0 / 72.0).clamp(8.0, 22.0) * scale).round() as i32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_expansion_sample_keeps_viewport_edge_and_content_center() {
        for scale in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5] {
            for left in [true, false] {
                for expanded_height in [590.0, 680.0] {
                    for step in 0..=120 {
                        let t = step as f64 / 120.0;
                        let width = (16.0 + 72.0 * t) * scale;
                        let height = (192.0 + (expanded_height - 192.0) * t) * scale;
                        let edge = -1920.0;
                        let center = 900.0;
                        let f = layout(SidebarFrame { x: if left { edge } else { edge - width },
                            y: center - height / 2.0, width, height }, left, scale).unwrap();
                        assert_eq!(f.canvas_width, (88.0 * scale).round() as i32);
                        assert_eq!(f.canvas_height, (SIDEBAR_CANVAS_HEIGHT * scale).round() as i32);
                        let canvas_edge = f.canvas_x + if left { 0 } else { f.canvas_width };
                        assert_eq!(canvas_edge, edge as i32);
                        let canvas_center = f.canvas_y as f64 + f.canvas_height as f64 / 2.0;
                        assert!((canvas_center - center).abs() <= 0.5);
                        assert_eq!(f.canvas_y, (center - f.canvas_height as f64 / 2.0).round() as i32);
                        assert_eq!((f.canvas_x + f.clip_x, f.canvas_y + f.clip_y), (f.x, f.y));
                        assert!(f.clip_y >= 0 && f.clip_x >= 0);
                    }
                }
            }
        }
    }

    #[test]
    fn constrained_workarea_and_free_drag_keep_the_canvas_centered() {
        for left in [true, false] {
            let f = layout(SidebarFrame { x: -2500.4, y: -120.2, width: 50.4, height: 210.5 }, left, 1.25).unwrap();
            assert_eq!((f.canvas_width, f.canvas_height), (110, 850));
            assert_eq!(f.height, 211);
            assert!(((425.0 - f.clip_y as f64) - f.height as f64 / 2.0).abs() <= 1.0);
        }
    }

    #[test]
    fn invalid_geometry_is_rejected_before_native_calls() {
        let frame = SidebarFrame { x: 0.0, y: 0.0, width: 16.0, height: 192.0 };
        for scale in [0.0, -1.0, f64::NAN, f64::INFINITY] { assert!(layout(frame, false, scale).is_err()); }
        assert!(layout(SidebarFrame { width: 0.0, ..frame }, false, 1.0).is_err());
        assert!(layout(SidebarFrame { x: f64::NAN, ..frame }, false, 1.0).is_err());
        assert!(layout_with_canvas_height(frame, false, 1.0, 679.0).is_err());
        assert!(layout_with_canvas_height(frame, false, 1.0, f64::INFINITY).is_err());
    }

    #[test]
    fn larger_target_uses_a_centered_canvas_and_never_exceeds_its_clip() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            let f = layout_with_canvas_height(SidebarFrame { x: -1920.0, y: 100.0, width: 88.0 * scale, height: 750.0 * scale }, false, scale, 768.0).unwrap();
            assert_eq!(f.canvas_height, (768.0 * scale).round() as i32);
            assert!(f.clip_y >= 0);
            assert!(f.clip_y + f.height <= f.canvas_height);
            assert!((f.clip_y + f.height / 2 - f.canvas_height / 2).abs() <= 1);
        }
    }

    #[test]
    fn settings_preview_canvas_keeps_a_stable_112_point_envelope_and_edge_input_clip() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            for left in [true, false] {
                let width = 112.0 * scale;
                let edge = -1920.0;
                let f = layout_with_canvas_width_and_height(SidebarFrame {
                    x: if left { edge } else { edge - width }, y: 100.0, width, height: 420.0 * scale,
                }, left, scale, 112.0, SIDEBAR_CANVAS_HEIGHT).unwrap();
                assert_eq!(f.canvas_width, (112.0 * scale).round() as i32);
                let canvas_edge = f.canvas_x + if left { 0 } else { f.canvas_width };
                assert_eq!(canvas_edge, edge as i32);
                assert_eq!(f.clip_x, 0);
                assert_eq!((f.canvas_x + f.clip_x, f.canvas_y + f.clip_y), (f.x, f.y));

                // At the end of preview dismissal, the viewport returns to
                // 88pt while the larger envelope remains available until the
                // animation reaches its exact terminal frame.
                let normal_width = 88.0 * scale;
                let normal = layout_with_canvas_width_and_height(SidebarFrame {
                    x: if left { edge } else { edge - normal_width }, y: 100.0,
                    width: normal_width, height: 420.0 * scale,
                }, left, scale, 112.0, SIDEBAR_CANVAS_HEIGHT).unwrap();
                assert_eq!(normal.canvas_width, f.canvas_width);
                assert_eq!(normal.width, (88.0 * scale).round() as i32);
                assert_eq!(normal.clip_x, if left { 0 } else { (24.0 * scale).round() as i32 });
            }
        }
    }

    #[test]
    fn preview_canvas_keeps_narrow_input_regions_inside_its_edge_anchored_envelope() {
        let frame = SidebarFrame { x: 10.0, y: 20.0, width: 80.0, height: 192.0 };
        for left in [true, false] {
            let f = layout_with_canvas_width_and_height(frame, left, 1.0, 112.0, SIDEBAR_CANVAS_HEIGHT).unwrap();
            assert_eq!(f.canvas_width, 112);
            assert_eq!(f.clip_x, if left { 0 } else { 32 });
            assert_eq!(f.clip_x + f.width, if left { 80 } else { 112 });
            assert_eq!(f.canvas_x + f.clip_x, f.x);
        }
    }
}
