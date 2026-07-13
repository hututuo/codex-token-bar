use std::ffi::OsStr;
use std::path::{Path, PathBuf};

const CODEX_BUNDLE_IDENTIFIER: &str = "com.openai.codex";
const CODEX_APP_RESOURCE_PATH: [&str; 3] = ["Contents", "Resources", "codex"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CodexBinaryPlatform {
    Macos,
    Windows,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum CodexBinaryCandidate {
    Explicit(PathBuf),
    AppBundle(PathBuf),
    ApplicationBundles { root: PathBuf },
    ChildCommand { parent: PathBuf, command: &'static str },
    DescendantCommand { root: PathBuf, command: &'static str },
    PathCommand(&'static str),
}

pub fn find_codex_binary_with_report() -> Result<CodexBinaryResolution, String> {
    let platform = current_codex_binary_platform();
    let home = if platform == CodexBinaryPlatform::Windows {
        std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))
    } else {
        std::env::var_os("HOME")
    };
    let local_app_data = std::env::var_os("LOCALAPPDATA");
    let program_files = std::env::var_os("ProgramFiles");
    let program_files_x86 = std::env::var_os("ProgramFiles(x86)");
    let explicit = std::env::var_os("CODEX_CLI_PATH");
    let path_env = std::env::var_os("PATH");
    let launch_service_app_bundles = launch_services_codex_app_bundles();
    let candidates = codex_binary_candidates(
        home.as_deref(),
        local_app_data.as_deref(),
        program_files.as_deref(),
        program_files_x86.as_deref(),
        explicit.as_deref(),
        platform,
        &launch_service_app_bundles,
        Path::new("/Applications"),
    );
    let checked = describe_candidates(&candidates);
    if let Some(path) = find_codex_binary_from(&candidates, path_env.as_deref(), is_executable_file)
    {
        Ok(CodexBinaryResolution { path, checked })
    } else {
        Err(missing_codex_error(platform, &checked))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexBinaryResolution {
    pub path: PathBuf,
    pub checked: Vec<String>,
}

fn current_codex_binary_platform() -> CodexBinaryPlatform {
    if cfg!(target_os = "macos") {
        CodexBinaryPlatform::Macos
    } else if cfg!(target_os = "windows") {
        CodexBinaryPlatform::Windows
    } else {
        CodexBinaryPlatform::Other
    }
}

fn codex_binary_candidates(
    home: Option<&OsStr>,
    local_app_data: Option<&OsStr>,
    program_files: Option<&OsStr>,
    program_files_x86: Option<&OsStr>,
    explicit: Option<&OsStr>,
    platform: CodexBinaryPlatform,
    launch_service_app_bundles: &[PathBuf],
    macos_system_applications: &Path,
) -> Vec<CodexBinaryCandidate> {
    let mut candidates = Vec::new();
    if let Some(explicit) = explicit {
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(explicit)));
    }

    if platform == CodexBinaryPlatform::Macos {
        candidates.extend(
            launch_service_app_bundles
                .iter()
                .cloned()
                .map(CodexBinaryCandidate::AppBundle),
        );
        candidates.push(CodexBinaryCandidate::ApplicationBundles {
            root: macos_system_applications.to_path_buf(),
        });
        if let Some(home) = home {
            candidates.push(CodexBinaryCandidate::ApplicationBundles {
                root: Path::new(home).join("Applications"),
            });
        }
        candidates.push(CodexBinaryCandidate::AppBundle(
            macos_system_applications.join("ChatGPT.app"),
        ));
        candidates.push(CodexBinaryCandidate::AppBundle(
            macos_system_applications.join("Codex.app"),
        ));
        if let Some(home) = home {
            candidates.push(CodexBinaryCandidate::AppBundle(
                Path::new(home)
                    .join("Applications")
                    .join("ChatGPT.app"),
            ));
            candidates.push(CodexBinaryCandidate::AppBundle(
                Path::new(home)
                    .join("Applications")
                    .join("Codex.app"),
            ));
        }
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(
            "/opt/homebrew/bin/codex",
        )));
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(
            "/usr/local/bin/codex",
        )));
    } else if platform == CodexBinaryPlatform::Windows {
        if let Some(home) = home {
            candidates.push(CodexBinaryCandidate::Explicit(
                Path::new(home)
                    .join(".codex")
                    .join("plugins")
                    .join(".plugin-appserver")
                    .join("codex.exe"),
            ));
        }
        if let Some(local_app_data) = local_app_data {
            candidates.push(CodexBinaryCandidate::ChildCommand {
                parent: Path::new(local_app_data)
                    .join("OpenAI")
                    .join("Codex")
                    .join("bin"),
                command: "codex.exe",
            });
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(local_app_data).join("Programs").join("Codex"),
                command: "codex.exe",
            });
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(local_app_data).join("OpenAI").join("Codex"),
                command: "codex.exe",
            });
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(local_app_data).join("Codex"),
                command: "codex.exe",
            });
        }
        if let Some(program_files) = program_files {
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(program_files).join("Codex"),
                command: "codex.exe",
            });
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(program_files).join("OpenAI").join("Codex"),
                command: "codex.exe",
            });
        }
        if let Some(program_files_x86) = program_files_x86 {
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(program_files_x86).join("Codex"),
                command: "codex.exe",
            });
            candidates.push(CodexBinaryCandidate::DescendantCommand {
                root: Path::new(program_files_x86).join("OpenAI").join("Codex"),
                command: "codex.exe",
            });
        }
    }

    candidates.push(CodexBinaryCandidate::PathCommand(match platform {
        CodexBinaryPlatform::Windows => "codex.exe",
        CodexBinaryPlatform::Macos | CodexBinaryPlatform::Other => "codex",
    }));
    candidates
}

fn codex_resource_in_app_bundle(bundle: &Path) -> PathBuf {
    CODEX_APP_RESOURCE_PATH
        .iter()
        .fold(bundle.to_path_buf(), |path, component| path.join(component))
}

#[cfg(target_os = "macos")]
fn launch_services_codex_app_bundles() -> Vec<PathBuf> {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;

    let bundle_identifier = NSString::from_str(CODEX_BUNDLE_IDENTIFIER);
    NSWorkspace::sharedWorkspace()
        .URLsForApplicationsWithBundleIdentifier(&bundle_identifier)
        .to_vec()
        .into_iter()
        .filter_map(|url| url.path())
        .map(|path| PathBuf::from(path.to_string()))
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn launch_services_codex_app_bundles() -> Vec<PathBuf> {
    Vec::new()
}

fn missing_codex_error(platform: CodexBinaryPlatform, checked: &[String]) -> String {
    let executable = if platform == CodexBinaryPlatform::Windows {
        "codex.exe"
    } else {
        "codex"
    };
    format!(
        "未找到 Codex，可在 CODEX_CLI_PATH 指定 {executable}。已检查：{}",
        checked.join("；")
    )
}

fn find_codex_binary_from<F>(
    candidates: &[CodexBinaryCandidate],
    path_env: Option<&OsStr>,
    file_exists: F,
) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    candidates.iter().find_map(|candidate| match candidate {
        CodexBinaryCandidate::Explicit(path) if file_exists(path) => Some(existing_path(path)),
        CodexBinaryCandidate::AppBundle(bundle) => {
            codex_command_in_app_bundle(bundle, &file_exists).map(|path| existing_path(&path))
        }
        CodexBinaryCandidate::ApplicationBundles { root } => {
            application_bundle_command(root, &file_exists).map(|path| existing_path(&path))
        }
        CodexBinaryCandidate::ChildCommand { parent, command } => {
            child_command(parent, command, &file_exists).map(|path| existing_path(&path))
        }
        CodexBinaryCandidate::DescendantCommand { root, command } => {
            descendant_command(root, command, 8, &file_exists).map(|path| existing_path(&path))
        }
        CodexBinaryCandidate::PathCommand(command) => {
            command_path_in_path(command, path_env, &file_exists)
        }
        _ => None,
    })
}

fn existing_path(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

fn describe_candidates(candidates: &[CodexBinaryCandidate]) -> Vec<String> {
    candidates
        .iter()
        .map(|candidate| match candidate {
            CodexBinaryCandidate::Explicit(path) => path.display().to_string(),
            CodexBinaryCandidate::AppBundle(bundle) => {
                codex_resource_in_app_bundle(bundle).display().to_string()
            }
            CodexBinaryCandidate::ApplicationBundles { root } => format!(
                "{}/*.app/Contents/Resources/codex",
                root.display()
            ),
            CodexBinaryCandidate::ChildCommand { parent, command } => {
                format!("{}\\*\\{}", parent.display(), command)
            }
            CodexBinaryCandidate::DescendantCommand { root, command } => {
                format!("{}\\**\\{}", root.display(), command)
            }
            CodexBinaryCandidate::PathCommand(command) => format!("PATH:{command}"),
        })
        .collect()
}

fn application_bundle_command<F>(root: &Path, file_exists: &F) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    let mut matches = std::fs::read_dir(root)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|path| path.is_dir())
        .filter_map(|bundle| codex_command_in_app_bundle(&bundle, file_exists))
        .collect::<Vec<_>>();
    matches.sort();
    matches.into_iter().next()
}

fn codex_command_in_app_bundle<F>(bundle: &Path, file_exists: &F) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    if !is_codex_app_bundle(bundle) {
        return None;
    }
    let command = codex_resource_in_app_bundle(bundle);
    file_exists(&command).then_some(command)
}

#[cfg(target_os = "macos")]
fn is_codex_app_bundle(bundle: &Path) -> bool {
    plist::Value::from_file(bundle.join("Contents").join("Info.plist"))
        .ok()
        .and_then(|value| {
            value
                .as_dictionary()
                .and_then(|dictionary| dictionary.get("CFBundleIdentifier"))
                .and_then(plist::Value::as_string)
                .map(str::to_owned)
        })
        .is_some_and(|bundle_identifier| bundle_identifier == CODEX_BUNDLE_IDENTIFIER)
}

#[cfg(not(target_os = "macos"))]
fn is_codex_app_bundle(_bundle: &Path) -> bool {
    false
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }

    #[cfg(not(unix))]
    {
        true
    }
}

fn command_path_in_path<F>(
    command: &str,
    path_env: Option<&OsStr>,
    file_exists: &F,
) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    let paths = path_env?;
    std::env::split_paths(paths)
        .map(|path| path.join(command))
        .find(|path| file_exists(path))
        .map(|path| existing_path(&path))
}

fn child_command<F>(parent: &Path, command: &str, file_exists: &F) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    let mut matches = std::fs::read_dir(parent)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path().join(command))
        .filter(|path| file_exists(path))
        .collect::<Vec<_>>();
    matches.sort();
    matches.pop()
}

fn descendant_command<F>(
    root: &Path,
    command: &str,
    max_depth: usize,
    file_exists: &F,
) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    let mut matches = Vec::new();
    collect_descendant_commands(root, command, max_depth, &mut matches, file_exists);
    matches.sort();
    matches.pop()
}

fn collect_descendant_commands<F>(
    root: &Path,
    command: &str,
    remaining_depth: usize,
    matches: &mut Vec<PathBuf>,
    file_exists: &F,
) where
    F: Fn(&Path) -> bool,
{
    if remaining_depth == 0 {
        return;
    }

    let candidate = root.join(command);
    if file_exists(&candidate) {
        matches.push(candidate);
    }

    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            collect_descendant_commands(
                &entry.path(),
                command,
                remaining_depth.saturating_sub(1),
                matches,
                file_exists,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    #[cfg(unix)]
    fn write_executable(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, []).unwrap();
        let mut permissions = std::fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).unwrap();
    }

    #[cfg(target_os = "macos")]
    fn write_bundle_identifier(app: &Path, bundle_identifier: Option<&str>) {
        let contents = app.join("Contents");
        std::fs::create_dir_all(&contents).unwrap();
        let plist = match bundle_identifier {
            Some(bundle_identifier) => format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>{bundle_identifier}</string></dict></plist>"
            ),
            None => "not a plist".to_string(),
        };
        std::fs::write(contents.join("Info.plist"), plist).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_application_scan_skips_wrong_missing_and_invalid_bundle_identifiers() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-bundle-identity-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let fake_app = root.join("A-Fake.app");
        let missing_app = root.join("B-Missing.app");
        let invalid_app = root.join("C-Invalid.app");
        let target_app = root.join("D-Renamed.app");
        for app in [&fake_app, &missing_app, &invalid_app, &target_app] {
            write_executable(&codex_resource_in_app_bundle(app));
        }
        write_bundle_identifier(&fake_app, Some("example.fake"));
        write_bundle_identifier(&invalid_app, None);
        write_bundle_identifier(&target_app, Some(CODEX_BUNDLE_IDENTIFIER));
        let candidates = vec![CodexBinaryCandidate::ApplicationBundles { root: root.clone() }];

        let found = find_codex_binary_from(&candidates, None, is_executable_file);
        let expected = codex_resource_in_app_bundle(&target_app)
            .canonicalize()
            .unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, Some(expected));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_codex_binary_resolution_finds_renamed_user_application_bundle() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-renamed-user-app-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root
            .join("Applications")
            .join("Renamed Desktop Client.app");
        let binary = codex_resource_in_app_bundle(&app);
        write_bundle_identifier(&app, Some(CODEX_BUNDLE_IDENTIFIER));
        write_executable(&binary);
        let candidates = codex_binary_candidates(
            Some(root.as_os_str()),
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[],
            Path::new("/Applications"),
        );

        let found = find_codex_binary_from(&candidates, None, |path| path == binary);
        let expected = binary.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, Some(expected));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_codex_binary_resolution_finds_renamed_system_application_bundle() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-renamed-system-app-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root.join("Another Name.app");
        let binary = codex_resource_in_app_bundle(&app);
        write_bundle_identifier(&app, Some(CODEX_BUNDLE_IDENTIFIER));
        write_executable(&binary);
        let candidates = codex_binary_candidates(
            None,
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[],
            &root,
        );

        let found = find_codex_binary_from(&candidates, None, |path| path == binary);
        let expected = binary.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, Some(expected));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_launch_services_candidate_supports_nonstandard_app_location() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-launch-services-app-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root.join("Renamed OpenAI Client.app");
        let expected = codex_resource_in_app_bundle(&app);
        write_bundle_identifier(&app, Some(CODEX_BUNDLE_IDENTIFIER));
        write_executable(&expected);
        let candidates = codex_binary_candidates(
            None,
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[app],
            Path::new("/Applications"),
        );

        let found = find_codex_binary_from(&candidates, None, is_executable_file).unwrap();
        let canonical_expected = expected.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, canonical_expected);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_launch_services_candidate_rejects_wrong_bundle_identifier() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-launch-services-wrong-app-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root.join("Fake.app");
        let app_binary = codex_resource_in_app_bundle(&app);
        write_bundle_identifier(&app, Some("example.fake"));
        write_executable(&app_binary);
        let fallback = PathBuf::from("/opt/homebrew/bin/codex");
        let candidates = codex_binary_candidates(
            None,
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[app],
            &root.join("EmptyApplications"),
        );

        let found = find_codex_binary_from(&candidates, None, |path| {
            path == app_binary || path == fallback
        });
        let expected_fallback = fallback
            .canonicalize()
            .unwrap_or_else(|_| fallback.clone());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, Some(expected_fallback));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_known_app_candidate_rejects_wrong_bundle_identifier() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-known-wrong-app-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root.join("ChatGPT.app");
        let app_binary = codex_resource_in_app_bundle(&app);
        write_bundle_identifier(&app, Some("example.fake"));
        write_executable(&app_binary);
        let fallback = PathBuf::from("/opt/homebrew/bin/codex");
        let candidates = codex_binary_candidates(
            None,
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[],
            &root,
        );

        let found = find_codex_binary_from(&candidates, None, |path| {
            path == app_binary || path == fallback
        });
        let expected_fallback = fallback
            .canonicalize()
            .unwrap_or_else(|_| fallback.clone());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, Some(expected_fallback));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_application_bundle_scan_does_not_recurse_beyond_direct_children() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-bounded-app-scan-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let hidden_binary = root
            .join("Nested")
            .join("Hidden.app")
            .join("Contents")
            .join("Resources")
            .join("codex");
        write_executable(&hidden_binary);
        let candidates = vec![CodexBinaryCandidate::ApplicationBundles { root: root.clone() }];

        let found = find_codex_binary_from(&candidates, None, |path| path == hidden_binary);
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, None);
    }

    #[cfg(unix)]
    #[test]
    fn codex_binary_resolution_skips_non_executable_and_broken_symlink() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-codex-executable-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let non_executable = root.join("not-executable");
        std::fs::write(&non_executable, []).unwrap();
        let broken = root.join("broken-codex");
        symlink(root.join("missing-codex"), &broken).unwrap();
        let real = root.join("real-codex");
        write_executable(&real);
        let linked = root.join("linked-codex");
        symlink(&real, &linked).unwrap();
        let candidates = vec![
            CodexBinaryCandidate::Explicit(non_executable),
            CodexBinaryCandidate::Explicit(broken),
            CodexBinaryCandidate::Explicit(linked),
        ];

        let found = find_codex_binary_from(&candidates, None, is_executable_file);
        let expected = real.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, Some(expected));
    }

    #[test]
    fn missing_codex_error_uses_platform_executable_name() {
        let checked = vec!["PATH:codex".to_string()];

        let macos = missing_codex_error(CodexBinaryPlatform::Macos, &checked);
        let windows = missing_codex_error(CodexBinaryPlatform::Windows, &checked);

        assert!(macos.contains("指定 codex。"));
        assert!(!macos.contains("codex.exe"));
        assert!(windows.contains("指定 codex.exe。"));
    }

    #[test]
    fn macos_codex_binary_candidates_include_app_bundle_brew_and_path_command() {
        let candidates = codex_binary_candidates(
            Some(OsStr::new("/Users/local")),
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[],
            Path::new("/Applications"),
        );

        assert_eq!(
            candidates,
            vec![
                CodexBinaryCandidate::ApplicationBundles {
                    root: PathBuf::from("/Applications"),
                },
                CodexBinaryCandidate::ApplicationBundles {
                    root: PathBuf::from("/Users/local/Applications"),
                },
                CodexBinaryCandidate::AppBundle(PathBuf::from(
                    "/Applications/ChatGPT.app"
                )),
                CodexBinaryCandidate::AppBundle(PathBuf::from("/Applications/Codex.app")),
                CodexBinaryCandidate::AppBundle(PathBuf::from(
                    "/Users/local/Applications/ChatGPT.app"
                )),
                CodexBinaryCandidate::AppBundle(PathBuf::from(
                    "/Users/local/Applications/Codex.app"
                )),
                CodexBinaryCandidate::Explicit(PathBuf::from("/opt/homebrew/bin/codex")),
                CodexBinaryCandidate::Explicit(PathBuf::from("/usr/local/bin/codex")),
                CodexBinaryCandidate::PathCommand("codex"),
            ]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_codex_binary_resolution_finds_chatgpt_app_bundle_before_brew_fallbacks() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-known-app-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let app = root.join("ChatGPT.app");
        let expected = codex_resource_in_app_bundle(&app);
        write_bundle_identifier(&app, Some(CODEX_BUNDLE_IDENTIFIER));
        write_executable(&expected);
        let candidates = codex_binary_candidates(
            None,
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
            &[],
            &root,
        );

        let found = find_codex_binary_from(&candidates, None, is_executable_file).unwrap();
        let canonical_expected = expected.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(found, canonical_expected);
    }

    #[test]
    fn macos_codex_binary_candidates_keep_explicit_path_first() {
        let candidates = codex_binary_candidates(
            Some(OsStr::new("/Users/local")),
            None,
            None,
            None,
            Some(OsStr::new("/custom/codex")),
            CodexBinaryPlatform::Macos,
            &[],
            Path::new("/Applications"),
        );

        assert_eq!(
            candidates.first(),
            Some(&CodexBinaryCandidate::Explicit(PathBuf::from("/custom/codex")))
        );

        let found = find_codex_binary_from(&candidates, None, |path| {
            path == Path::new("/custom/codex")
                || path == Path::new("/Applications/ChatGPT.app/Contents/Resources/codex")
        });
        assert_eq!(found, Some(PathBuf::from("/custom/codex")));
    }

    #[test]
    fn windows_codex_binary_candidates_include_desktop_install_locations() {
        let user_home = PathBuf::from(r"C:\Users\local");
        let local_app_data = PathBuf::from(r"C:\Users\local\AppData\Local");
        let candidates = codex_binary_candidates(
            Some(user_home.as_os_str()),
            Some(local_app_data.as_os_str()),
            Some(OsStr::new(r"C:\Program Files")),
            Some(OsStr::new(r"C:\Program Files (x86)")),
            Some(OsStr::new(r"C:\custom\codex.exe")),
            CodexBinaryPlatform::Windows,
            &[],
            Path::new("/Applications"),
        );

        assert_eq!(
            candidates,
            vec![
                CodexBinaryCandidate::Explicit(PathBuf::from(r"C:\custom\codex.exe")),
                CodexBinaryCandidate::Explicit(
                    user_home
                        .join(".codex")
                        .join("plugins")
                        .join(".plugin-appserver")
                        .join("codex.exe")
                ),
                CodexBinaryCandidate::ChildCommand {
                    parent: local_app_data.join("OpenAI").join("Codex").join("bin"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: local_app_data.join("Programs").join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: local_app_data.join("OpenAI").join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: local_app_data.join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: PathBuf::from(r"C:\Program Files").join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: PathBuf::from(r"C:\Program Files")
                        .join("OpenAI")
                        .join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: PathBuf::from(r"C:\Program Files (x86)").join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::DescendantCommand {
                    root: PathBuf::from(r"C:\Program Files (x86)")
                        .join("OpenAI")
                        .join("Codex"),
                    command: "codex.exe",
                },
                CodexBinaryCandidate::PathCommand("codex.exe"),
            ]
        );
    }

    #[test]
    fn codex_binary_resolution_prefers_existing_explicit_candidate() {
        let candidates = vec![
            CodexBinaryCandidate::Explicit(PathBuf::from("/missing/codex")),
            CodexBinaryCandidate::Explicit(PathBuf::from(
                "/Applications/Codex.app/Contents/Resources/codex",
            )),
            CodexBinaryCandidate::PathCommand("codex"),
        ];
        let expected = PathBuf::from("/Applications/Codex.app/Contents/Resources/codex");

        let found = find_codex_binary_from(&candidates, None, |path| path == expected).unwrap();

        assert_eq!(found, expected);
    }

    #[test]
    fn codex_binary_resolution_finds_command_in_supplied_path() {
        let command_dir = PathBuf::from("/tmp/codex-token-bar-bin");
        let command_path = command_dir.join("codex");
        let path_env = std::env::join_paths([OsString::from(command_dir.as_os_str())]).unwrap();
        let candidates = vec![CodexBinaryCandidate::PathCommand("codex")];

        let found = find_codex_binary_from(&candidates, Some(path_env.as_os_str()), |path| {
            path == command_path
        })
        .unwrap();

        assert_eq!(found, command_path);
    }

    #[test]
    fn codex_binary_resolution_canonicalizes_existing_files_when_possible() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-codex-canonical-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let nested = root.join("nested");
        let binary = nested.join("codex");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(&binary, []).unwrap();
        let candidate = root.join("nested").join("..").join("nested").join("codex");
        let candidates = vec![CodexBinaryCandidate::Explicit(candidate)];

        let found = find_codex_binary_from(&candidates, None, |path| path.is_file()).unwrap();
        let expected = binary.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(found, expected);
    }

    #[test]
    fn codex_binary_resolution_finds_nested_windows_desktop_binary() {
        let root = std::env::temp_dir().join(format!(
            "codex-token-bar-codex-binary-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let nested = root
            .join("resources")
            .join("app.asar.unpacked")
            .join("bin")
            .join("codex.exe");
        std::fs::create_dir_all(nested.parent().unwrap()).unwrap();
        std::fs::write(&nested, []).unwrap();

        let candidates = vec![CodexBinaryCandidate::DescendantCommand {
            root: root.clone(),
            command: "codex.exe",
        }];

        let found = find_codex_binary_from(&candidates, None, |path| path.is_file()).unwrap();
        let expected = nested.canonicalize().unwrap();
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(found, expected);
    }

    #[test]
    fn missing_codex_report_lists_checked_windows_paths() {
        let candidates = codex_binary_candidates(
            Some(OsStr::new(r"C:\Users\local")),
            Some(OsStr::new(r"C:\Users\local\AppData\Local")),
            None,
            None,
            None,
            CodexBinaryPlatform::Windows,
            &[],
            Path::new("/Applications"),
        );

        let checked = describe_candidates(&candidates).join("；");

        assert!(checked.contains(r"C:\Users\local"));
        assert!(checked.contains(".codex"));
        assert!(checked.contains(".plugin-appserver"));
        assert!(checked.contains(r"C:\Users\local\AppData\Local"));
        assert!(checked.contains("Programs"));
        assert!(checked.contains("Codex"));
        assert!(checked.contains("**"));
        assert!(checked.contains("codex.exe"));
        assert!(checked.contains("PATH:codex.exe"));
    }
}
