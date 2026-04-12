use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Three mutually-exclusive ways Quip can expose its WebSocket server to the phone:
/// via a Cloudflare quick tunnel, via Tailscale, or local-only (LAN + mDNS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkMode {
    CloudflareTunnel,
    Tailscale,
    LocalOnly,
}

impl Default for NetworkMode {
    fn default() -> Self {
        NetworkMode::CloudflareTunnel
    }
}

impl NetworkMode {
    pub fn display_name(self) -> &'static str {
        match self {
            NetworkMode::CloudflareTunnel => "Cloudflare Tunnel",
            NetworkMode::Tailscale => "Tailscale",
            NetworkMode::LocalOnly => "Local only",
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            NetworkMode::CloudflareTunnel => "cloudflare_tunnel",
            NetworkMode::Tailscale => "tailscale",
            NetworkMode::LocalOnly => "local_only",
        }
    }
}

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
    #[serde(default)]
    pub show_all_windows: bool,
    #[serde(default)]
    pub local_only_mode: bool,
    #[serde(default)]
    pub network_mode: Option<NetworkMode>,
    #[serde(default)]
    pub tailscale_hostname_override: String,
    #[serde(default)]
    pub require_pin_for_local: bool,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        Self {
            default_terminal: "kitty".into(),
            websocket_port: 8765,
            bonjour_name: hostname::get()
                .ok()
                .and_then(|h| h.into_string().ok())
                .filter(|h| !h.is_empty() && !h.starts_with("localhost"))
                .unwrap_or_else(|| "Quip Linux".into()),
            show_all_windows: false,
            local_only_mode: false,
            network_mode: None,
            tailscale_hostname_override: String::new(),
            require_pin_for_local: false,
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
        let mut settings: Self = if path.exists() {
            let content = std::fs::read_to_string(&path).unwrap_or_default();
            toml::from_str(&content).unwrap_or_default()
        } else {
            Self::default()
        };
        // One-time migration from legacy local_only_mode bool to network_mode enum.
        if settings.general.network_mode.is_none() {
            settings.general.network_mode = Some(if settings.general.local_only_mode {
                NetworkMode::LocalOnly
            } else {
                NetworkMode::CloudflareTunnel
            });
            settings.save();
        }
        settings
    }

    /// Current network mode, resolving the legacy bool if migration hasn't run yet.
    pub fn network_mode(&self) -> NetworkMode {
        self.general
            .network_mode
            .unwrap_or(if self.general.local_only_mode {
                NetworkMode::LocalOnly
            } else {
                NetworkMode::CloudflareTunnel
            })
    }

    pub fn set_network_mode(&mut self, mode: NetworkMode) {
        self.general.network_mode = Some(mode);
        // Keep the legacy boolean roughly in sync so older builds don't suddenly
        // decide to start the tunnel if the user downgrades.
        self.general.local_only_mode = matches!(mode, NetworkMode::LocalOnly);
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
