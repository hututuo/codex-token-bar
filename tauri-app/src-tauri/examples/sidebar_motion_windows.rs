//! Windows compositor probe using the production canvas and real SSR rail.
//! Does not initialize the application, accounts, settings, or usage database.
#[derive(Clone, Copy, Debug)]
pub struct SidebarFrame { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }
#[cfg(windows)]
#[path = "../src/platform/quota_sidebar/canvas_geometry.rs"]
mod canvas_geometry;
#[cfg(windows)]
#[path = "../src/platform/quota_sidebar/canvas_windows.rs"]
mod canvas_windows;

#[cfg(windows)]
fn main() {
    use tauri::{Manager, WebviewWindowBuilder, WebviewUrl};
    let url = tauri::Url::from_file_path(std::env::args().nth(1).expect("SSR hover-windows.html path")).unwrap();
    let left = std::env::args().any(|arg| arg == "--left");
    tauri::Builder::default().setup(move |app| {
        let rail = WebviewWindowBuilder::new(app, "sidebar-motion-qa", WebviewUrl::External(url))
            .title("Sidebar motion QA").inner_size(16.0, 192.0).min_inner_size(1.0, 1.0)
            .decorations(false).transparent(true).shadow(false).resizable(false)
            .always_on_top(true).focused(false).focusable(false).visible(false)
            .on_document_title_changed(|window, title| {
                if title.starts_with("REPORT:") {
                    println!("{title} host={:?}/{:?} clip={:?}", window.outer_position(), window.outer_size(), canvas_windows::window_frame(&window));
                }
            }).build()?;
        <tauri::WebviewWindow as AsRef<tauri::Webview>>::as_ref(&rail).set_auto_resize(false)?;
        let monitor = rail.current_monitor()?.ok_or("No monitor")?;
        let scale = monitor.scale_factor();
        let work = monitor.work_area();
        let edge = if left { work.position.x as f64 } else { work.position.x as f64 + work.size.width as f64 };
        let center = work.position.y as f64 + work.size.height as f64 / 2.0;
        let rest = SidebarFrame { x: if left { edge } else { edge - 16.0 * scale },
            y: center - 96.0 * scale, width: 16.0 * scale, height: 192.0 * scale };
        canvas_windows::set_frame(&rail, rest, left, scale)?;
        rail.show()?;
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(2));
            // Three expand/collapse cycles, followed by a partial expansion
            // reversed in flight. 88x560 and summary center 280 must not change.
            for pass in 0..8 {
                let expanding = pass % 2 == 0;
                let steps = if pass >= 6 { 14 } else { 28 };
                for step in 0..=steps {
                    let p = if expanding { step as f64 / 28.0 }
                        else if pass == 7 { (14 - step) as f64 / 28.0 }
                        else { 1.0 - step as f64 / 28.0 };
                    let frame = SidebarFrame { width: (16.0 + 72.0 * p) * scale,
                        height: (192.0 + 278.0 * p) * scale, ..rest };
                    let frame = SidebarFrame { x: if left { edge } else { edge - frame.width },
                        y: center - frame.height / 2.0, ..frame };
                    let w = rail.clone();
                    let (send, receive) = std::sync::mpsc::sync_channel(1);
                    rail.run_on_main_thread(move || {
                        let result = canvas_windows::set_frame(&w, frame, left, scale).and_then(|()| {
                            w.eval(&format!(r#"(()=>{{
                                const rail=document.querySelector('.qs-rail');
                                rail.classList.toggle('qs-left',{left});rail.classList.toggle('qs-right',!{left});
                                document.querySelector('.qs-bars').dataset.visible=String(!{expanding});
                                document.querySelector('.qs-summary').dataset.visible=String({expanding});
                                document.documentElement.style.setProperty('--qs-native-width','{}px');
                                document.documentElement.style.setProperty('--qs-native-height','{}px');
                                requestAnimationFrame(()=>{{const r=document.querySelector('.qs-summary').getBoundingClientRect();
                                    document.title='REPORT:'+JSON.stringify({{pass:{pass},step:{step},viewport:[innerWidth,innerHeight],summary:[r.x,r.y,r.width,r.height],
                                        layoutOK:Math.abs(innerWidth-88)<=1&&Math.abs(innerHeight-560)<=1&&Math.abs(r.y+r.height/2-280)<=1}});
                                }});
                            }})()"#, frame.width/scale, frame.height/scale)).map_err(|e| e.to_string())
                        });
                        let _ = send.send(result);
                    }).unwrap();
                    if let Err(error) = receive.recv().unwrap() {
                        eprintln!("FAIL: {error}"); rail.app_handle().exit(1); return;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(16));
                }
                if pass < 6 { std::thread::sleep(std::time::Duration::from_millis(600)); }
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
            rail.app_handle().exit(0);
        });
        Ok(())
    }).run(tauri::generate_context!()).expect("run isolated Windows sidebar compositor probe");
}

#[cfg(not(windows))]
fn main() { eprintln!("This compositor probe requires Windows."); }
