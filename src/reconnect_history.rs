use serde_json;

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub const HISTORY_FILE_PATH: &str = "/data/reconnect-history.json";

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct ReconnectHistory {
    last_connected: HashMap<String, u64>,
}

impl ReconnectHistory {
    /// Loads the cache from `path`. A missing or corrupt file is treated as
    /// empty history — never a hard error, since losing this cache must
    /// never prevent wifi-connect from running.
    pub fn load(path: &Path) -> Self {
        let contents = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(_) => {
                debug!(
                    "No reconnect history file at '{}' yet - starting fresh",
                    path.display()
                );
                return Self::default();
            }
        };

        match serde_json::from_str(&contents) {
            Ok(history) => history,
            Err(e) => {
                warn!(
                    "Reconnect history file '{}' is corrupt, starting fresh: {}",
                    path.display(),
                    e
                );
                Self::default()
            }
        }
    }

    /// Records `ssid` as successfully connected right now, and persists the
    /// updated cache to `path` (best-effort — a write failure is logged, not
    /// propagated, since it must never block the connection this just made).
    pub fn record_success(&mut self, ssid: &str, path: &Path) {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        self.last_connected.insert(ssid.to_string(), timestamp);

        self.save(path);
    }

    /// Seconds since the Unix epoch this SSID was last successfully
    /// connected to by wifi-connect, or `None` if never recorded.
    pub fn last_connected(&self, ssid: &str) -> Option<u64> {
        self.last_connected.get(ssid).copied()
    }

    fn save(&self, path: &Path) {
        let json = match serde_json::to_string(self) {
            Ok(json) => json,
            Err(e) => {
                error!("Serializing reconnect history failed: {}", e);
                return;
            }
        };

        if let Some(parent) = path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                error!(
                    "Creating reconnect history directory '{}' failed: {}",
                    parent.display(),
                    e
                );
                return;
            }
        }

        let tmp_path = path.with_extension("tmp");

        if let Err(e) = fs::write(&tmp_path, json) {
            error!(
                "Writing reconnect history temp file '{}' failed: {}",
                tmp_path.display(),
                e
            );
            return;
        }

        if let Err(e) = fs::rename(&tmp_path, path) {
            error!(
                "Renaming reconnect history temp file into place failed: {}",
                e
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;

    fn temp_history_path(test_name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "wifi-connect-test-{}-{}-{}.json",
            test_name,
            process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn load_missing_file_returns_empty_history() {
        let path = temp_history_path("missing");

        let history = ReconnectHistory::load(&path);

        assert_eq!(history.last_connected("AnySsid"), None);
    }

    #[test]
    fn load_corrupt_file_returns_empty_history() {
        let path = temp_history_path("corrupt");
        fs::write(&path, "not valid json{{{").unwrap();

        let history = ReconnectHistory::load(&path);

        assert_eq!(history.last_connected("AnySsid"), None);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn record_success_then_reload_round_trips() {
        let path = temp_history_path("roundtrip");

        let mut history = ReconnectHistory::default();
        history.record_success("HomeWifi", &path);

        let reloaded = ReconnectHistory::load(&path);
        let timestamp = reloaded.last_connected("HomeWifi");

        assert!(timestamp.is_some());
        assert!(timestamp.unwrap() > 0);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn last_connected_is_none_for_unrecorded_ssid() {
        let path = temp_history_path("unrecorded");

        let mut history = ReconnectHistory::default();
        history.record_success("HomeWifi", &path);

        assert_eq!(history.last_connected("SomeOtherSsid"), None);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn record_success_updates_existing_entry() {
        let path = temp_history_path("update");

        let mut history = ReconnectHistory::default();
        history.record_success("HomeWifi", &path);
        let first = history.last_connected("HomeWifi").unwrap();

        std::thread::sleep(std::time::Duration::from_millis(1100));
        history.record_success("HomeWifi", &path);
        let second = history.last_connected("HomeWifi").unwrap();

        assert!(second >= first);

        let _ = fs::remove_file(&path);
    }
}
