use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartupLaunchMode {
    Manual,
    Autostart,
}

impl StartupLaunchMode {
    pub fn from_args(args: impl IntoIterator<Item = impl AsRef<std::ffi::OsStr>>) -> Self {
        if args
            .into_iter()
            .any(|arg| arg.as_ref() == std::ffi::OsStr::new("--autostart"))
        {
            Self::Autostart
        } else {
            Self::Manual
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) enum SecondaryInstanceAction {
    ContinueAsPrimary,
    SignalPrimaryAndExit,
    ExitSilently,
}

#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn secondary_instance_action(
    owns_primary_mutex: bool,
    mode: StartupLaunchMode,
) -> SecondaryInstanceAction {
    if owns_primary_mutex {
        SecondaryInstanceAction::ContinueAsPrimary
    } else if mode == StartupLaunchMode::Autostart {
        SecondaryInstanceAction::ExitSilently
    } else {
        SecondaryInstanceAction::SignalPrimaryAndExit
    }
}

#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn start_activation_listener_once(
    started: &AtomicBool,
    start: impl FnOnce(),
) -> bool {
    if started
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return false;
    }
    start();
    true
}

#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn consume_activation_signals(
    mut wait_for_signal: impl FnMut() -> bool,
    mut activate_dashboard: impl FnMut(),
) {
    while wait_for_signal() {
        activate_dashboard();
    }
}

pub(crate) fn perform_dashboard_activation(
    dashboard_exists: bool,
    create: impl FnOnce() -> Result<(), String>,
    show: impl FnOnce() -> Result<(), String>,
    focus: impl FnOnce() -> Result<(), String>,
) -> Result<bool, String> {
    if !dashboard_exists {
        create()?;
    }
    show()?;
    focus()?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    #[test]
    fn launch_mode_and_secondary_intent_are_explicit() {
        assert_eq!(StartupLaunchMode::from_args(["ctb"]), StartupLaunchMode::Manual);
        assert_eq!(
            StartupLaunchMode::from_args(["ctb", "--autostart"]),
            StartupLaunchMode::Autostart
        );
        assert_eq!(
            secondary_instance_action(false, StartupLaunchMode::Manual),
            SecondaryInstanceAction::SignalPrimaryAndExit
        );
        assert_eq!(
            secondary_instance_action(false, StartupLaunchMode::Autostart),
            SecondaryInstanceAction::ExitSilently
        );
        assert_eq!(
            secondary_instance_action(true, StartupLaunchMode::Manual),
            SecondaryInstanceAction::ContinueAsPrimary
        );
    }

    #[test]
    fn queued_activation_is_consumed_after_listener_starts() {
        let mut queued = VecDeque::from([true, true, false]);
        let mut activations = 0;
        consume_activation_signals(
            || queued.pop_front().unwrap_or(false),
            || activations += 1,
        );
        assert_eq!(activations, 2);
    }

    #[test]
    fn repeated_registration_starts_only_one_listener() {
        let registration = AtomicBool::new(false);
        let mut listeners = 0;
        assert!(start_activation_listener_once(&registration, || listeners += 1));
        assert!(!start_activation_listener_once(&registration, || listeners += 1));
        assert_eq!(listeners, 1);
    }

    #[test]
    fn primary_activation_recreates_missing_dashboard_then_shows_and_focuses_once() {
        let mut create_calls = 0;
        let mut show_calls = 0;
        let mut focus_calls = 0;
        assert!(perform_dashboard_activation(
            false,
            || {
                create_calls += 1;
                Ok(())
            },
            || {
                show_calls += 1;
                Ok(())
            },
            || {
                focus_calls += 1;
                Ok(())
            },
        )
        .unwrap());
        assert_eq!((create_calls, show_calls, focus_calls), (1, 1, 1));
    }
}
