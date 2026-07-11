use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

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

pub(crate) const SECONDARY_SIGNAL_ATTEMPT_LIMIT: usize = 3;
const ACTIVATION_WAIT_RETRY_BASE: Duration = Duration::from_millis(100);
const ACTIVATION_WAIT_RETRY_MAX: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SingleInstanceLaunchOutcome {
    ContinueAsPrimary,
    SecondaryExit,
    FatalFailure(String),
}

#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn resolve_single_instance_launch(
    owns_primary_mutex: bool,
    mode: StartupLaunchMode,
    mut signal_primary: impl FnMut() -> Result<(), String>,
) -> SingleInstanceLaunchOutcome {
    if owns_primary_mutex {
        SingleInstanceLaunchOutcome::ContinueAsPrimary
    } else if mode == StartupLaunchMode::Autostart {
        SingleInstanceLaunchOutcome::SecondaryExit
    } else {
        let mut last_error = None;
        for _ in 0..SECONDARY_SIGNAL_ATTEMPT_LIMIT {
            match signal_primary() {
                Ok(()) => return SingleInstanceLaunchOutcome::SecondaryExit,
                Err(error) => last_error = Some(error),
            }
        }
        SingleInstanceLaunchOutcome::FatalFailure(format!(
            "无法通知已运行的主实例：{}",
            last_error.unwrap_or_else(|| "unknown activation error".into())
        ))
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
pub(crate) fn supervise_activation_signals(
    mut wait_for_signal: impl FnMut() -> Result<bool, String>,
    mut activate_dashboard: impl FnMut() -> Result<(), String>,
    mut report_error: impl FnMut(&str),
    mut sleep: impl FnMut(Duration),
) {
    let mut consecutive_wait_failures = 0_u32;
    loop {
        match wait_for_signal() {
            Ok(true) => {
                consecutive_wait_failures = 0;
                if let Err(error) = activate_dashboard() {
                    report_error(&error);
                }
            }
            Ok(false) => return,
            Err(error) => {
                report_error(&error);
                consecutive_wait_failures = consecutive_wait_failures.saturating_add(1);
                sleep(activation_wait_retry_delay(consecutive_wait_failures));
            }
        }
    }
}

fn activation_wait_retry_delay(consecutive_failures: u32) -> Duration {
    let exponent = consecutive_failures.saturating_sub(1).min(5);
    (ACTIVATION_WAIT_RETRY_BASE * 2_u32.pow(exponent)).min(ACTIVATION_WAIT_RETRY_MAX)
}

pub(crate) fn perform_dashboard_activation(
    dashboard_exists: bool,
    create: impl FnOnce() -> Result<(), String>,
    show: impl FnOnce() -> Result<(), String>,
    focus: impl FnOnce() -> Result<(), String>,
) -> Result<bool, String> {
    if !dashboard_exists {
        create()?;
        // The new WebView remains hidden until its PageLoad::Finished callback shows and
        // focuses it. Showing immediately can expose an unloaded window.
        return Ok(true);
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
        let mut signals = 0;
        assert_eq!(
            resolve_single_instance_launch(false, StartupLaunchMode::Manual, || {
                signals += 1;
                Ok(())
            }),
            SingleInstanceLaunchOutcome::SecondaryExit
        );
        assert_eq!(signals, 1);
        assert_eq!(
            resolve_single_instance_launch(false, StartupLaunchMode::Autostart, || {
                panic!("autostart secondary must not signal")
            }),
            SingleInstanceLaunchOutcome::SecondaryExit
        );
        assert_eq!(
            resolve_single_instance_launch(true, StartupLaunchMode::Manual, || {
                panic!("primary must not signal")
            }),
            SingleInstanceLaunchOutcome::ContinueAsPrimary
        );
    }

    #[test]
    fn pre_listener_auto_reset_signal_is_consumed_once_with_binary_semantics() {
        let mut pending = VecDeque::from([Ok(true), Ok(false)]);
        let mut activations = 0;
        supervise_activation_signals(
            || pending.pop_front().unwrap_or(Ok(false)),
            || {
                activations += 1;
                Ok(())
            },
            |_| {},
            |_| {},
        );
        assert_eq!(activations, 1);
    }

    #[test]
    fn manual_secondary_signal_retries_are_bounded_and_fail_closed() {
        let mut attempts = 0;
        let outcome = resolve_single_instance_launch(false, StartupLaunchMode::Manual, || {
            attempts += 1;
            Err(format!("signal {attempts} failed"))
        });
        assert_eq!(attempts, SECONDARY_SIGNAL_ATTEMPT_LIMIT);
        assert!(matches!(
            outcome,
            SingleInstanceLaunchOutcome::FatalFailure(error)
                if error.contains("signal 3 failed")
        ));

        let mut retry_then_success = 0;
        assert_eq!(
            resolve_single_instance_launch(false, StartupLaunchMode::Manual, || {
                retry_then_success += 1;
                if retry_then_success == 2 {
                    Ok(())
                } else {
                    Err("transient".into())
                }
            }),
            SingleInstanceLaunchOutcome::SecondaryExit
        );
        assert_eq!(retry_then_success, 2);
    }

    #[test]
    fn listener_reports_activation_and_wait_failures_without_poisoning_prior_signals() {
        let mut waits = VecDeque::from([Ok(true), Ok(true), Err("wait failed".to_string())]);
        let mut activations = 0;
        let mut errors = Vec::new();
        supervise_activation_signals(
            || waits.pop_front().unwrap_or(Ok(false)),
            || {
                activations += 1;
                if activations == 1 {
                    Err("dispatch failed".into())
                } else {
                    Ok(())
                }
            },
            |error| errors.push(error.to_string()),
            |_| {},
        );
        assert_eq!(activations, 2);
        assert_eq!(errors, vec!["dispatch failed", "wait failed"]);
    }

    #[test]
    fn wait_failure_backs_off_then_later_signal_is_activated() {
        let mut waits = VecDeque::from([
            Err("wait failed".to_string()),
            Err("wait failed again".to_string()),
            Ok(true),
            Err("wait failed after signal".to_string()),
            Ok(false),
        ]);
        let mut errors = Vec::new();
        let mut sleeps = Vec::new();
        let mut activations = 0;
        supervise_activation_signals(
            || waits.pop_front().unwrap_or(Ok(false)),
            || {
                activations += 1;
                Ok(())
            },
            |error| errors.push(error.to_string()),
            |delay| sleeps.push(delay),
        );
        assert_eq!(
            errors,
            vec![
                "wait failed",
                "wait failed again",
                "wait failed after signal",
            ]
        );
        assert_eq!(
            sleeps,
            vec![
                ACTIVATION_WAIT_RETRY_BASE,
                ACTIVATION_WAIT_RETRY_BASE * 2,
                ACTIVATION_WAIT_RETRY_BASE,
            ]
        );
        assert_eq!(activations, 1);
    }

    #[test]
    fn persistent_wait_failures_use_bounded_backoff_without_busy_loop() {
        let failure_count = 8;
        let mut remaining = failure_count;
        let mut sleeps = Vec::new();
        supervise_activation_signals(
            || {
                if remaining == 0 {
                    Ok(false)
                } else {
                    remaining -= 1;
                    Err("wait failed".into())
                }
            },
            || panic!("no activation is available"),
            |_| {},
            |delay| sleeps.push(delay),
        );
        assert_eq!(sleeps.len(), failure_count);
        assert!(sleeps.iter().all(|delay| *delay >= ACTIVATION_WAIT_RETRY_BASE));
        assert_eq!(sleeps.last().copied(), Some(ACTIVATION_WAIT_RETRY_MAX));
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
    fn primary_activation_waits_for_page_load_when_dashboard_is_missing() {
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
        assert_eq!((create_calls, show_calls, focus_calls), (1, 0, 0));

        assert!(perform_dashboard_activation(
            true,
            || panic!("existing dashboard must not be recreated"),
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
