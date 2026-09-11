//! Isolated native compositor smoke test. Uses SSR output of SidebarRailContent;
//! does not load settings, account credentials, session logs, or usage indexes.
#[cfg(target_os = "macos")]
#[path = "../src/platform/quota_sidebar/canvas_macos.rs"]
mod canvas_macos;
#[cfg(target_os = "macos")]
fn main() {
    use tauri::{Manager, WebviewWindowBuilder, WebviewUrl};
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let url = tauri::Url::from_file_path(std::env::args().nth(1).expect("SSR hover.html path")).unwrap();
    tauri::Builder::default().setup(move |app| {
        let rail = WebviewWindowBuilder::new(app, "sidebar-motion-qa", WebviewUrl::External(url))
            .title("Sidebar motion QA").inner_size(16.0, 134.0).min_inner_size(1.0, 1.0)
            .decorations(false).transparent(true).shadow(false).resizable(false).always_on_top(true)
            .on_document_title_changed(|window, title| {
                if title.starts_with("REPORT:") {
                    let native = unsafe { &*window.ns_window().unwrap().cast::<objc2_app_kit::NSWindow>() };
                    println!("{} native={:?}", title, native.frame());

                }
            }).build()?;
        <tauri::WebviewWindow as AsRef<tauri::Webview>>::as_ref(&rail).set_auto_resize(false)?;
        let native = unsafe { &*rail.ns_window().unwrap().cast::<objc2_app_kit::NSWindow>() };
        let work = native.screen().unwrap().visibleFrame();
        let edge = work.origin.x + work.size.width;
        let center = work.origin.y + work.size.height / 2.0;
        canvas_macos::set_frame(native, NSRect::new(NSPoint::new(edge-16.0, center-67.0), NSSize::new(16.0,134.0)))?;
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(2));
            // The first pass expands, the second collapses. Sample actual
            // WebKit layout, not just requested native frame numbers.
            for pass in 0..if std::env::var_os("SIDEBAR_SMOKE_HOLD").is_some() { 1 } else { 2 } {
                for step in 0..=55 {
                    let w=rail.clone();
                    w.clone().run_on_main_thread(move || {
                        let native = unsafe { &*w.ns_window().unwrap().cast::<objc2_app_kit::NSWindow>() };
                        let t=step as f64/55.0;
                        let p=if pass==0 {(1.0-(1.0+8.0*t)*(-8.0*t).exp())/(1.0-9.0*(-8.0_f64).exp())} else {(1.0-t).powi(3)};
                        let width=16.0+72.0*p; let height=134.0+336.0*p;
                        canvas_macos::set_frame(native,NSRect::new(NSPoint::new(edge-width,center-height/2.0),NSSize::new(width,height))).unwrap();
                        w.eval(&format!(r#"(()=>{{const r=document.querySelector('.qs-summary').getBoundingClientRect();document.title='REPORT:'+JSON.stringify({{pass:{pass},step:{step},viewport:[innerWidth,innerHeight],summary:[r.x,r.y,r.width,r.height]}})}})()"#)).unwrap();
                    }).unwrap();
                    std::thread::sleep(std::time::Duration::from_millis(8));
                }
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
            if std::env::var_os("SIDEBAR_SMOKE_HOLD").is_some() { std::thread::sleep(std::time::Duration::from_secs(180)); }
            rail.app_handle().exit(0);
        });
        Ok(())
    }).run(tauri::generate_context!()).expect("run isolated sidebar compositor test");
}
#[cfg(not(target_os = "macos"))]
fn main() { eprintln!("This compositor test requires macOS."); }
