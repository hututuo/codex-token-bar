pub(crate) mod auto_resume;
pub(crate) mod codex_radar;
pub(crate) mod codex_instances;
pub(crate) mod dashboard;
pub(crate) mod live;
pub(crate) mod provider_repair;
pub(crate) mod settings;
pub(crate) mod startup;
pub(crate) mod surface;
pub(crate) mod thread_delete;
pub(crate) mod update;
pub(crate) mod window_auth;

use crate::core::dashboard::LocalCodexDataSource;
use crate::platform;

pub(crate) fn local_source() -> LocalCodexDataSource {
    LocalCodexDataSource::new(platform::default_codex_home())
}
