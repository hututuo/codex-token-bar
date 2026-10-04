// Keep cleanup strictly behind successful ShellExecute launch.
pub(crate) fn after_launch(code: isize, cleanup: impl FnOnce()) -> std::io::Result<()> {
    if code <= 32 {
        return Err(std::io::Error::other(format!(
            "Windows installer launch failed (ShellExecuteW={code})"
        )));
    }
    cleanup();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shell_errors_leave_the_live_application_untouched() {
        for code in [0, 2, 5, 8, 26, 31, 32] {
            let mut cleaned = false;
            let result = after_launch(code, || cleaned = true);
            assert!(result.unwrap_err().to_string().contains(&format!("={code}")));
            assert!(!cleaned);
        }
    }
    #[test]
    fn success_cleans_up_exactly_once() {
        let mut count = 0;
        after_launch(33, || count += 1).unwrap();
        assert_eq!(count, 1);
    }
}
