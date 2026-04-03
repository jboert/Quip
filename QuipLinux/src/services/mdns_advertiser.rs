use mdns_sd::{ServiceDaemon, ServiceInfo};
use tracing::{error, info};

const SERVICE_TYPE: &str = "_quip._tcp.local.";

/// Get the first non-loopback IPv4 address on this machine.
fn local_ipv4() -> Option<String> {
    if_addrs::get_if_addrs().ok()?.into_iter()
        .find(|iface| !iface.is_loopback() && iface.addr.ip().is_ipv4())
        .map(|iface| iface.addr.ip().to_string())
}

pub struct MdnsAdvertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl MdnsAdvertiser {
    /// Create and register an mDNS service advertisement.
    pub fn start(name: &str, port: u16) -> Result<Self, String> {
        let daemon = ServiceDaemon::new().map_err(|e| format!("Failed to create mDNS daemon: {e}"))?;

        let raw_hostname = hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .unwrap_or_else(|| "quip-host".into());
        // Use just the short hostname, and fall back to "quip-host" if it's localhost
        let short_host = raw_hostname.split('.').next().unwrap_or("quip-host");
        let host = if short_host == "localhost" || short_host.is_empty() {
            "quip-host.local.".to_string()
        } else {
            format!("{short_host}.local.")
        };

        let ip = local_ipv4().unwrap_or_default();
        info!("Advertising mDNS with host={host} ip={ip}");

        let service = ServiceInfo::new(
            SERVICE_TYPE,
            name,
            &host,
            &ip,
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
