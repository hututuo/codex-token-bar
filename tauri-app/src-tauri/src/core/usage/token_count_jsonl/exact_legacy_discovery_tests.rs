use super::*;

fn collect(path: &Path) -> Result<Vec<(PathBuf, PathBuf)>, String> {
    let mut inputs = Vec::new();
    collect_exact_legacy_inputs(path, path, &mut inputs, &mut Vec::new())?;
    Ok(inputs)
}

#[test]
fn absent_exact_legacy_root_is_a_valid_empty_install() {
    let root = tempfile::tempdir().unwrap();
    assert!(collect(&root.path().join("absent")).unwrap().is_empty());
    let file = root.path().join("not-a-directory");
    fs::write(&file, b"evidence").unwrap();
    assert!(collect(&file).is_err());
}

#[cfg(unix)]
#[test]
fn exact_discovery_rejects_unreadable_root_nested_and_ancestor() {
    use std::os::unix::fs::PermissionsExt;
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let root = tempfile::tempdir().unwrap();
    for layout in ["root", "nested", "ancestor"] {
        let base = root.path().join(layout);
        let input = base.join("nested");
        fs::create_dir_all(&input).unwrap();
        let raw = input.join("old.sqlite3");
        fs::write(&raw, b"unchanged legacy evidence").unwrap();
        let (blocked, source_root) = match layout {
            "root" => (&base, &base),
            "nested" => (&input, &base),
            _ => (&base, &input),
        };
        fs::set_permissions(blocked, fs::Permissions::from_mode(0o000)).unwrap();
        let result = collect(source_root);
        fs::set_permissions(blocked, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            result.is_err(),
            "{layout} must not become an empty ready index"
        );
        assert_eq!(fs::read(raw).unwrap(), b"unchanged legacy evidence");
    }
}

#[cfg(unix)]
#[test]
fn configured_exact_directory_symlink_remains_supported_but_dangling_root_fails() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let actual = root.path().join("actual");
    fs::create_dir(&actual).unwrap();
    fs::write(actual.join("old.sqlite3"), b"evidence").unwrap();
    let alias = root.path().join("configured-root");
    symlink(&actual, &alias).unwrap();
    assert_eq!(collect(&alias).unwrap().len(), 1);
    let dangling = root.path().join("dangling");
    symlink(root.path().join("does-not-exist"), &dangling).unwrap();
    assert!(collect(&dangling).is_err());
}
