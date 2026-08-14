//! Persisted preferences. The macOS app uses `@AppStorage`; here it is a JSON file
//! beside the models, with the same keys and defaults.

use free_scribe_core::cleanup::DictationStyle;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Ctrl+Alt+D, matching ⌘⌥D on macOS.
pub const DEFAULT_SHORTCUT: &str = "CmdOrCtrl+Alt+D";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub shortcut: String,
    /// Empty means "decide from the hardware".
    pub model: String,
    /// Empty means "detect the language".
    pub language: String,
    /// Empty means the system default input.
    pub input_device: String,
    pub style: DictationStyle,
    /// Scribe mode only: honour "command capital y".
    pub spoken_capitals: bool,
    pub launch_at_login: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            shortcut: DEFAULT_SHORTCUT.to_string(),
            model: String::new(),
            language: "en".to_string(),
            input_device: String::new(),
            style: DictationStyle::Tidy,
            spoken_capitals: true,
            launch_at_login: false,
        }
    }
}

impl Settings {
    pub fn file_path() -> PathBuf {
        free_scribe_core::data_directory().join("settings.json")
    }

    pub fn load() -> Settings {
        std::fs::read_to_string(Self::file_path())
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        let path = Self::file_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }

    /// One setter rather than one command per field, so adding a preference does not
    /// mean adding an IPC command.
    pub fn set(&mut self, key: &str, value: serde_json::Value) -> Result<(), String> {
        let as_string = || value.as_str().unwrap_or_default().to_string();
        let as_bool = || value.as_bool().unwrap_or(false);

        match key {
            "shortcut" => self.shortcut = as_string(),
            "model" => self.model = as_string(),
            "language" => self.language = as_string(),
            "inputDevice" => self.input_device = as_string(),
            "spokenCapitals" => self.spoken_capitals = as_bool(),
            "launchAtLogin" => self.launch_at_login = as_bool(),
            "style" => {
                self.style = serde_json::from_value(value)
                    .map_err(|_| "Unknown dictation style".to_string())?
            }
            other => return Err(format!("Unknown setting {other}")),
        }

        Ok(())
    }
}
