use super::safe_fs::PinnedHome;
use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};

pub(super) struct ProviderStorageRoots {
    pub(super) codex_home: PinnedHome,
    pub(super) sqlite_home: PinnedHome,
}

impl ProviderStorageRoots {
    pub(super) fn open(codex_home: &Path) -> Result<Self, String> {
        let codex_home = PinnedHome::open(codex_home)?;
        let sqlite_home = open_sqlite_home_for_pinned(&codex_home)?;
        Ok(Self {
            codex_home,
            sqlite_home,
        })
    }

    #[cfg(test)]
    pub(super) fn open_with_environment(
        codex_home: &Path,
        sqlite_home_environment: Option<OsString>,
        current_directory: &Path,
    ) -> Result<Self, String> {
        let codex_home = PinnedHome::open(codex_home)?;
        let sqlite_path = resolve_sqlite_home_for_pinned(
            &codex_home,
            sqlite_home_environment,
            current_directory,
        )?;
        let sqlite_home = PinnedHome::open(&sqlite_path)?;
        Ok(Self {
            codex_home,
            sqlite_home,
        })
    }
}

pub(super) fn open_sqlite_home_for_pinned(
    codex_home: &PinnedHome,
) -> Result<PinnedHome, String> {
    let sqlite_path = resolve_sqlite_home_for_pinned(
        codex_home,
        std::env::var_os("CODEX_SQLITE_HOME"),
        &std::env::current_dir()
            .map_err(|error| format!("无法解析 CODEX_SQLITE_HOME 的当前目录：{error}"))?,
    )?;
    PinnedHome::open(&sqlite_path).map_err(|error| {
        format!(
            "无法固定 Codex SQLite Home {}：{error}",
            sqlite_path.display()
        )
    })
}

fn resolve_sqlite_home_for_pinned(
    codex_home: &PinnedHome,
    sqlite_home_environment: Option<OsString>,
    current_directory: &Path,
) -> Result<PathBuf, String> {
    if let Some(mut config_file) = codex_home.open_file(Path::new("config.toml"))? {
        let mut config_bytes = Vec::new();
        config_file
            .read_to_end(&mut config_bytes)
            .map_err(|error| format!("读取 config.toml 的 sqlite_home 失败：{error}"))?;
        let config_text = std::str::from_utf8(&config_bytes)
            .map_err(|error| format!("config.toml 不是有效 UTF-8：{error}"))?;
        let config = toml::from_str::<toml::Table>(config_text)
            .map_err(|error| format!("解析 config.toml 的 sqlite_home 失败：{error}"))?;
        if let Some(value) = config.get("sqlite_home") {
            let configured = value
                .as_str()
                .ok_or_else(|| "config.toml 的 sqlite_home 必须是绝对路径字符串。".to_string())?
                .trim();
            if configured.is_empty() {
                return Err("config.toml 的 sqlite_home 不能为空。".into());
            }
            let configured = PathBuf::from(configured);
            if !configured.is_absolute() {
                return Err(format!(
                    "config.toml 的 sqlite_home 必须是绝对路径：{}",
                    configured.display()
                ));
            }
            return Ok(configured);
        }
    }

    if let Some(raw) = sqlite_home_environment {
        let trimmed = raw.to_string_lossy().trim().to_string();
        if !trimmed.is_empty() {
            let configured = PathBuf::from(trimmed);
            return Ok(if configured.is_absolute() {
                configured
            } else {
                current_directory.join(configured)
            });
        }
    }

    Ok(codex_home.canonical_path().to_path_buf())
}
