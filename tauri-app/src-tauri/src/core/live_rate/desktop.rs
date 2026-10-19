//! One Desktop observer for the currently requested physical data source.
//! Thread IDs come from the selected source; no Desktop history or usage is imported.
use super::{observed, LiveRateSourceScope};
use crate::core::desktop_stream::{DesktopStreamEvent, DesktopStreamObserver};
use std::sync::{Mutex, OnceLock};

struct Binding {
    scope: LiveRateSourceScope,
    observer: DesktopStreamObserver,
}
static BINDING: OnceLock<Mutex<Option<Binding>>> = OnceLock::new();

pub(super) fn poll(
    scope: &LiveRateSourceScope,
    threads: Vec<String>,
    now: f64,
) -> Vec<DesktopStreamEvent> {
    if !cfg!(windows) || cfg!(test) {
        return Vec::new();
    }
    let mut binding = BINDING
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if binding.as_ref().is_none_or(|b| b.scope != *scope) {
        if let Some(old) = binding.take() {
            old.observer.stop();
            observed::reset_desktop(&old.scope, now);
        }
        *binding = Some(Binding {
            scope: scope.clone(),
            observer: DesktopStreamObserver::start(),
        });
    }
    let observer = &binding.as_ref().expect("observer is bound").observer;
    observer.update_threads(threads);
    let mut events = Vec::new();
    while let Some(event) = observer.try_recv() {
        events.push(event);
        if events.len() >= 1024 {
            break;
        }
    }
    events
}
