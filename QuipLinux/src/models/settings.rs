use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Persisted application settings (TOML format in ~/.config/quip/settings.toml)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    #[serde(default)]
    pub general: GeneralSettings,
    #[serde(default)]
    pub colors: ColorSettings,
    #[serde(default)]
    pub directories: DirectorySettings,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            general: GeneralSettings::default(),
            colors: ColorSettings::default(),
            directories: DirectorySettings::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneralSettings {
    pub default_terminal: String,
    pub websocket_port: u16,
    pub bonjour_name: String,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        Self {
            default_terminal: "kitty".into(),
            websocket_port: 8765,
            bonjour_name: hostname::get()
                .ok()
                .and_then(|h| h.into_string().ok())
                .unwrap_or_else(|| "Quip".into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColorSettings {
    pub waiting_for_input: String,
    pub stt_active: String,
}

impl Default for ColorSettings {
    fn default() -> Self {
        Self {
            waiting_for_input: "#001430".into(),
            stt_active: "#240040".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectorySettings {
    pub projects: Vec<String>,
}

impl Default for DirectorySettings {
    fn default() -> Self {
        Self {
            projects: vec![],
        }
    }
}

impl AppSettings {
    pub fn config_path() -> PathBuf {
        let dirs = directories::ProjectDirs::from("dev", "quip", "quip")
            .expect("could not determine config directory");
        dirs.config_dir().join("settings.toml")
    }

    pub fn load() -> Self {
        let path = Self::config_path();
        if path.exists() {
            let content = std::fs::read_to_string(&path).unwrap_or_default();
            toml::from_str(&content).unwrap_or_default()
        } else {
            Self::default()
        }
    }

    pub fn save(&self) {
        let path = Self::config_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(content) = toml::to_string_pretty(self) {
            let _ = std::fs::write(&path, content);
        }
    }
}
