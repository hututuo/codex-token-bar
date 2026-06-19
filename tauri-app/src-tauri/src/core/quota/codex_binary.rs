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
    PathCommand(&'static str),
}

pub fn find_codex_binary() -> Option<PathBuf> {
    let home = std::env::var_os("HOME");
    let path_env = std::env::var_os("PATH");
    let candidates = codex_binary_candidates(home.as_deref(), current_codex_binary_platform());
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
    platform: CodexBinaryPlatform,
) -> Vec<CodexBinaryCandidate> {
    let mut candidates = Vec::new();
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    #[test]
    fn macos_codex_binary_candidates_include_app_bundle_brew_and_path_command() {
        let candidates =
            codex_binary_candidates(Some(OsStr::new("/Users/local")), CodexBinaryPlatform::Macos);

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
    fn windows_codex_binary_candidates_use_exe_path_command() {
        let candidates = codex_binary_candidates(None, CodexBinaryPlatform::Windows);

        assert_eq!(
            candidates,
            vec![CodexBinaryCandidate::PathCommand("codex.exe")]
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
