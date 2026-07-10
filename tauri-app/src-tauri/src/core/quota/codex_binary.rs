use std::ffi::OsStr;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CodexBinaryPlatform {
    Macos,
    Windows,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum CodexBinaryCandidate {
    Explicit(PathBuf),
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
    let candidates = codex_binary_candidates(
        home.as_deref(),
        local_app_data.as_deref(),
        program_files.as_deref(),
        program_files_x86.as_deref(),
        explicit.as_deref(),
        platform,
    );
    let checked = describe_candidates(&candidates);
    if let Some(path) = find_codex_binary_from(&candidates, path_env.as_deref(), |path| path.is_file()) {
        Ok(CodexBinaryResolution { path, checked })
    } else {
        Err(format!(
            "未找到 Codex，可在 CODEX_CLI_PATH 指定 codex.exe。已检查：{}",
            checked.join("；")
        ))
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
) -> Vec<CodexBinaryCandidate> {
    let mut candidates = Vec::new();
    if let Some(explicit) = explicit {
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(explicit)));
    }

    if platform == CodexBinaryPlatform::Macos {
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        )));
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(
            "/Applications/Codex.app/Contents/Resources/codex",
        )));
        if let Some(home) = home {
            candidates.push(CodexBinaryCandidate::Explicit(
                Path::new(home)
                    .join("Applications")
                    .join("ChatGPT.app")
                    .join("Contents")
                    .join("Resources")
                    .join("codex"),
            ));
            candidates.push(CodexBinaryCandidate::Explicit(
                Path::new(home)
                    .join("Applications")
                    .join("Codex.app")
                    .join("Contents")
                    .join("Resources")
                    .join("codex"),
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

    #[test]
    fn macos_codex_binary_candidates_include_app_bundle_brew_and_path_command() {
        let candidates = codex_binary_candidates(
            Some(OsStr::new("/Users/local")),
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
        );

        assert_eq!(
            candidates,
            vec![
                CodexBinaryCandidate::Explicit(PathBuf::from(
                    "/Applications/ChatGPT.app/Contents/Resources/codex"
                )),
                CodexBinaryCandidate::Explicit(PathBuf::from(
                    "/Applications/Codex.app/Contents/Resources/codex"
                )),
                CodexBinaryCandidate::Explicit(PathBuf::from(
                    "/Users/local/Applications/ChatGPT.app/Contents/Resources/codex"
                )),
                CodexBinaryCandidate::Explicit(PathBuf::from(
                    "/Users/local/Applications/Codex.app/Contents/Resources/codex"
                )),
                CodexBinaryCandidate::Explicit(PathBuf::from("/opt/homebrew/bin/codex")),
                CodexBinaryCandidate::Explicit(PathBuf::from("/usr/local/bin/codex")),
                CodexBinaryCandidate::PathCommand("codex"),
            ]
        );
    }

    #[test]
    fn macos_codex_binary_resolution_finds_chatgpt_app_bundle_before_brew_fallbacks() {
        let candidates = codex_binary_candidates(
            Some(OsStr::new("/Users/local")),
            None,
            None,
            None,
            None,
            CodexBinaryPlatform::Macos,
        );
        let expected = PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex");

        let found = find_codex_binary_from(&candidates, None, |path| path == expected).unwrap();

        assert_eq!(found, expected);
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
        );

        assert_eq!(
            candidates.first(),
            Some(&CodexBinaryCandidate::Explicit(PathBuf::from("/custom/codex")))
        );
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
