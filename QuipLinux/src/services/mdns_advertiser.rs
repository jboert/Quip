use mdns_sd::{ServiceDaemon, ServiceInfo};
use tracing::{error, info};

const SERVICE_TYPE: &str = "_quip._tcp.local.";

pub struct MdnsAdvertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl MdnsAdvertiser {
    /// Create and register an mDNS service advertisement.
    pub fn start(name: &str, port: u16) -> Result<Self, String> {
        let daemon = ServiceDaemon::new().map_err(|e| format!("Failed to create mDNS daemon: {e}"))?;

        let host = format!("{}.local.", hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .unwrap_or_else(|| "quip-host".into()));

        let service = ServiceInfo::new(
            SERVICE_TYPE,
            name,
            &host,
            "",
            port,
            None::<std::collections::HashMap<String, String>>,
        )
        .map_err(|e| format!("Failed to create service info: {e}"))?;

        let fullname = service.get_fullname().to_string();

        daemon
            .register(service)
            .map_err(|e| format!("Failed to register mDNS service: {e}"))?;

        info!("mDNS service registered: {name} on port {port}");

        Ok(Self { daemon, fullname })
    }

    /// Unregister the mDNS service.
    pub fn stop(&self) {
        if let Err(e) = self.daemon.unregister(&self.fullname) {
            error!("Failed to unregister mDNS service: {e}");
        } else {
            info!("mDNS service unregistered");
        }
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}
