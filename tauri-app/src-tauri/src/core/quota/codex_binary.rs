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
    PathCommand(&'static str),
}

pub fn find_codex_binary() -> Option<PathBuf> {
    let platform = current_codex_binary_platform();
    let home = if platform == CodexBinaryPlatform::Windows {
        std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))
    } else {
        std::env::var_os("HOME")
    };
    let local_app_data = std::env::var_os("LOCALAPPDATA");
    let explicit = std::env::var_os("CODEX_CLI_PATH");
    let path_env = std::env::var_os("PATH");
    let candidates = codex_binary_candidates(
        home.as_deref(),
        local_app_data.as_deref(),
        explicit.as_deref(),
        platform,
    );
    find_codex_binary_from(&candidates, path_env.as_deref(), |path| path.is_file())
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
    explicit: Option<&OsStr>,
    platform: CodexBinaryPlatform,
) -> Vec<CodexBinaryCandidate> {
    let mut candidates = Vec::new();
    if let Some(explicit) = explicit {
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(explicit)));
    }

    if platform == CodexBinaryPlatform::Macos {
        candidates.push(CodexBinaryCandidate::Explicit(PathBuf::from(
            "/Applications/Codex.app/Contents/Resources/codex",
        )));
        if let Some(home) = home {
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
        CodexBinaryCandidate::Explicit(path) if file_exists(path) => Some(path.clone()),
        CodexBinaryCandidate::ChildCommand { parent, command } => {
            child_command(parent, command, &file_exists)
        }
        CodexBinaryCandidate::PathCommand(command)
            if command_exists_in_path(command, path_env, &file_exists) =>
        {
            Some(PathBuf::from(command))
        }
        _ => None,
    })
}

fn command_exists_in_path<F>(command: &str, path_env: Option<&OsStr>, file_exists: &F) -> bool
where
    F: Fn(&Path) -> bool,
{
    let Some(paths) = path_env else {
        return false;
    };
    std::env::split_paths(paths).any(|path| file_exists(&path.join(command)))
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
            CodexBinaryPlatform::Macos,
        );

        assert_eq!(
            candidates,
            vec![
                CodexBinaryCandidate::Explicit(PathBuf::from(
                    "/Applications/Codex.app/Contents/Resources/codex"
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
    fn windows_codex_binary_candidates_include_desktop_install_locations() {
        let user_home = PathBuf::from(r"C:\Users\local");
        let local_app_data = PathBuf::from(r"C:\Users\local\AppData\Local");
        let candidates = codex_binary_candidates(
            Some(user_home.as_os_str()),
            Some(local_app_data.as_os_str()),
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

        assert_eq!(found, PathBuf::from("codex"));
    }
}
