use base::config::keys;
use hbb_common::config;

const APP_NAME: &str = "RufraDesk";

/// Applies the RufraDesk name and its built-in server.
///
/// The server address and key are read from the build environment
/// (`RUFRA_SERVER`, `RUFRA_KEY`) so they never live in the repository. They go
/// into the overwrite settings, which the settings page cannot change, so every
/// install stays pinned to the RufraDesk server.
pub fn apply() {
    *config::APP_NAME.write().unwrap() = APP_NAME.to_owned();
    let server = option_env!("RUFRA_SERVER").unwrap_or_default().trim();
    let key = option_env!("RUFRA_KEY").unwrap_or_default().trim();
    if server.is_empty() || key.is_empty() {
        return;
    }
    let mut settings = config::OVERWRITE_SETTINGS.write().unwrap();
    for k in [keys::OPTION_CUSTOM_RENDEZVOUS_SERVER, keys::OPTION_RELAY_SERVER] {
        settings.insert(k.to_owned(), server.to_owned());
    }
    settings.insert(keys::OPTION_KEY.to_owned(), key.to_owned());
}
