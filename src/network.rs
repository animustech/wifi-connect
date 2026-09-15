use std::collections::HashSet;
use std::net::Ipv4Addr;
use std::path::Path;
use std::process;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;
use std::time::Duration;

use network_manager::{
    AccessPoint, AccessPointCredentials, Connection, ConnectionState, Connectivity, Device,
    DeviceState, DeviceType, NetworkManager, Security, ServiceState,
};

use config::Config;
use dnsmasq::{start_dnsmasq, stop_dnsmasq};
use errors::*;
use exit::{exit, trap_exit_signals, ExitResult};
use reconnect_history::{ReconnectHistory, HISTORY_FILE_PATH};
use server::start_server;

pub enum NetworkCommand {
    Activate,
    Timeout,
    Exit,
    Reconnect,
    Connect {
        ssid: String,
        identity: String,
        passphrase: String,
    },
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Network {
    ssid: String,
    security: String,
}

pub enum NetworkCommandResponse {
    Networks(Vec<Network>),
}

struct NetworkCommandHandler {
    manager: NetworkManager,
    device: Device,
    access_points: Vec<AccessPoint>,
    portal_connection: Option<Connection>,
    config: Config,
    dnsmasq: process::Child,
    server_tx: Sender<NetworkCommandResponse>,
    network_rx: Receiver<NetworkCommand>,
    activated: bool,
    reconnect_history: ReconnectHistory,
    reconnect_tick_count: u64,
}

impl NetworkCommandHandler {
    fn new(config: &Config, exit_tx: &Sender<ExitResult>) -> Result<Self> {
        let (network_tx, network_rx) = channel();

        Self::spawn_trap_exit_signals(exit_tx, network_tx.clone());

        let manager = NetworkManager::new();
        debug!("NetworkManager connection initialized");

        let device = find_device(&manager, &config.interface)?;

        let access_points = get_access_points(&device)?;

        let portal_connection = Some(create_portal(&device, config)?);

        let dnsmasq = start_dnsmasq(config, &device)?;

        let (server_tx, server_rx) = channel();

        Self::spawn_server(config, exit_tx, server_rx, network_tx.clone());

        Self::spawn_activity_timeout(config, network_tx.clone());

        Self::spawn_periodic_reconnect(config, network_tx);

        let config = config.clone();
        let activated = false;
        let reconnect_history = ReconnectHistory::load(Path::new(HISTORY_FILE_PATH));
        let reconnect_tick_count = 0;

        Ok(NetworkCommandHandler {
            manager,
            device,
            access_points,
            portal_connection,
            config,
            dnsmasq,
            server_tx,
            network_rx,
            activated,
            reconnect_history,
            reconnect_tick_count,
        })
    }

    fn spawn_server(
        config: &Config,
        exit_tx: &Sender<ExitResult>,
        server_rx: Receiver<NetworkCommandResponse>,
        network_tx: Sender<NetworkCommand>,
    ) {
        let gateway = config.gateway;
        let listening_port = config.listening_port;
        let exit_tx_server = exit_tx.clone();
        let ui_directory = config.ui_directory.clone();

        thread::spawn(move || {
            start_server(
                gateway,
                listening_port,
                server_rx,
                network_tx,
                exit_tx_server,
                &ui_directory,
            );
        });
    }

    fn spawn_activity_timeout(config: &Config, network_tx: Sender<NetworkCommand>) {
        let activity_timeout = config.activity_timeout;

        if activity_timeout == 0 {
            return;
        }

        thread::spawn(move || {
            thread::sleep(Duration::from_secs(activity_timeout));

            if let Err(err) = network_tx.send(NetworkCommand::Timeout) {
                error!(
                    "Sending NetworkCommand::Timeout failed: {}",
                    err.to_string()
                );
            }
        });
    }

    // Boot-time-only wired-connection awareness lives entirely in `scripts/start.sh`
    // (see docs/specs/2026-08-10-conditional-wifi-reconnect.md) — this handler has no
    // wired-awareness and never checks it. Treating wired-state changes as boot-time-only
    // is a deliberate simplification that may be worth revisiting later.
    fn spawn_periodic_reconnect(config: &Config, network_tx: Sender<NetworkCommand>) {
        if !config.reconnect_enabled || config.reconnect_interval_minutes == 0 {
            return;
        }

        let interval = Duration::from_secs(config.reconnect_interval_minutes.saturating_mul(60));

        thread::spawn(move || loop {
            thread::sleep(interval);

            if let Err(err) = network_tx.send(NetworkCommand::Reconnect) {
                error!(
                    "Sending NetworkCommand::Reconnect failed: {}",
                    err.to_string()
                );
                return;
            }
        });
    }

    fn spawn_trap_exit_signals(exit_tx: &Sender<ExitResult>, network_tx: Sender<NetworkCommand>) {
        let exit_tx_trap = exit_tx.clone();

        thread::spawn(move || {
            if let Err(e) = trap_exit_signals() {
                exit(&exit_tx_trap, e);
                return;
            }

            if let Err(err) = network_tx.send(NetworkCommand::Exit) {
                error!("Sending NetworkCommand::Exit failed: {}", err.to_string());
            }
        });
    }

    fn run(&mut self, exit_tx: &Sender<ExitResult>) {
        let result = self.run_loop();
        self.stop(exit_tx, result);
    }

    fn run_loop(&mut self) -> ExitResult {
        loop {
            let command = self.receive_network_command()?;

            match command {
                NetworkCommand::Activate => {
                    self.activate()?;
                }
                NetworkCommand::Timeout => {
                    if !self.activated {
                        info!("Timeout reached. Exiting...");
                        return Ok(());
                    }
                }
                NetworkCommand::Reconnect => {
                    if self.reconnect()? {
                        return Ok(());
                    }
                }
                NetworkCommand::Exit => {
                    info!("Exiting...");
                    return Ok(());
                }
                NetworkCommand::Connect {
                    ssid,
                    identity,
                    passphrase,
                } => {
                    if self.connect(&ssid, &identity, &passphrase)? {
                        return Ok(());
                    }
                }
            }
        }
    }

    fn receive_network_command(&self) -> Result<NetworkCommand> {
        match self.network_rx.recv() {
            Ok(command) => Ok(command),
            Err(e) => {
                // Sleep for a second, so that other threads may log error info.
                thread::sleep(Duration::from_secs(1));
                Err(e).chain_err(|| ErrorKind::RecvNetworkCommand)
            }
        }
    }

    fn stop(&mut self, exit_tx: &Sender<ExitResult>, result: ExitResult) {
        let _ = stop_dnsmasq(&mut self.dnsmasq);

        if let Some(ref connection) = self.portal_connection {
            let _ = stop_portal_impl(connection, &self.config);
        }

        let _ = exit_tx.send(result);
    }

    fn activate(&mut self) -> ExitResult {
        self.activated = true;

        let networks = get_networks(&self.access_points);

        self.server_tx
            .send(NetworkCommandResponse::Networks(networks))
            .chain_err(|| ErrorKind::SendAccessPointSSIDs)
    }

    fn connect(&mut self, ssid: &str, identity: &str, passphrase: &str) -> Result<bool> {
        delete_existing_connections_to_same_network(&self.manager, ssid);

        self.tear_down_portal_if_up()?;

        self.access_points = get_access_points(&self.device)?;

        if let Some(access_point) = find_access_point(&self.access_points, ssid) {
            let wifi_device = self.device.as_wifi_device().unwrap();

            info!("Connecting to access point '{}'...", ssid);

            let credentials = init_access_point_credentials(access_point, identity, passphrase);

            match wifi_device.connect(access_point, &credentials) {
                Ok((connection, state)) => {
                    if state == ConnectionState::Activated {
                        self.reconnect_history
                            .record_success(ssid, Path::new(HISTORY_FILE_PATH));

                        confirm_connectivity_and_log(&self.manager);

                        return Ok(true);
                    }

                    if let Err(err) = connection.delete() {
                        error!("Deleting connection object failed: {}", err)
                    }

                    warn!(
                        "Connection to access point not activated '{}': {:?}",
                        ssid, state
                    );
                }
                Err(e) => {
                    warn!("Error connecting to access point '{}': {}", ssid, e);
                }
            }
        }

        self.access_points = get_access_points(&self.device)?;

        self.portal_connection = Some(create_portal(&self.device, &self.config)?);

        Ok(false)
    }

    /// Stops and clears the AP portal connection if one is currently up. A no-op if
    /// it's already down (e.g. already torn down earlier in the same tick).
    fn tear_down_portal_if_up(&mut self) -> Result<()> {
        if let Some(ref connection) = self.portal_connection {
            stop_portal(connection, &self.config)?;
        }

        self.portal_connection = None;

        Ok(())
    }

    /// Periodically-triggered reconnect: try saved WiFi networks that are currently
    /// visible in range, most-recently-connected first. Only touches the AP if there
    /// is at least one candidate to try — except on a forced-rescan tick (every
    /// `config.reconnect_rescan_every`th call), which refreshes the scan unconditionally
    /// so a network that wasn't visible at boot (or the last successful scan) is
    /// eventually noticed without requiring a manual captive-portal visit.
    fn reconnect(&mut self) -> Result<bool> {
        self.reconnect_tick_count = self.reconnect_tick_count.wrapping_add(1);

        let force_rescan = is_forced_rescan_tick(
            self.reconnect_tick_count,
            self.config.reconnect_rescan_every,
        );

        if force_rescan {
            info!(
                "Forced periodic rescan (every {} ticks)",
                self.config.reconnect_rescan_every
            );

            self.tear_down_portal_if_up()?;
            self.access_points = get_access_points(&self.device)?;
        }

        let candidates = self.get_reconnect_candidates()?;

        if candidates.is_empty() {
            debug!("No saved networks currently in range - skipping periodic reconnect");

            if force_rescan {
                self.portal_connection = Some(create_portal(&self.device, &self.config)?);
            }

            return Ok(false);
        }

        info!(
            "Periodic reconnect: attempting {} saved network(s) in range",
            candidates.len()
        );

        self.tear_down_portal_if_up()?;

        for candidate in &candidates {
            let ssid = connection_ssid_as_str(candidate)
                .unwrap_or("<unknown>")
                .to_string();

            info!("Reconnecting to saved network '{}'...", ssid);

            match candidate.activate() {
                Ok(ConnectionState::Activated) => {
                    self.reconnect_history
                        .record_success(&ssid, Path::new(HISTORY_FILE_PATH));

                    confirm_connectivity_and_log(&self.manager);

                    return Ok(true);
                }
                Ok(state) => {
                    warn!(
                        "Reconnecting to saved network not activated '{}': {:?}",
                        ssid, state
                    );
                }
                Err(e) => {
                    warn!("Error reconnecting to saved network '{}': {}", ssid, e);
                }
            }
        }

        self.access_points = get_access_points(&self.device)?;

        self.portal_connection = Some(create_portal(&self.device, &self.config)?);

        Ok(false)
    }

    /// Saved WiFi station profiles (excludes wifi-connect's own AP/hotspot profile)
    /// whose SSID is currently visible in the last known scan, ordered by wifi-connect's
    /// own reconnect-history cache of last-successful-connection time, most recent first
    /// (networks never recorded there sort last).
    fn get_reconnect_candidates(&self) -> Result<Vec<Connection>> {
        let visible_ssids: HashSet<&str> = self
            .access_points
            .iter()
            .filter_map(|ap| ap.ssid().as_str().ok())
            .collect();

        let mut candidates: Vec<Connection> = self
            .manager
            .get_connections()?
            .into_iter()
            .filter(|c| is_wifi_connection(c) && !is_access_point_connection(c))
            .filter(|c| {
                connection_ssid_as_str(c)
                    .map(|ssid| visible_ssids.contains(ssid))
                    .unwrap_or(false)
            })
            .collect();

        let history = &self.reconnect_history;
        candidates.sort_by(|a, b| {
            let a_ts = connection_ssid_as_str(a)
                .and_then(|ssid| history.last_connected(ssid))
                .unwrap_or(0);
            let b_ts = connection_ssid_as_str(b)
                .and_then(|ssid| history.last_connected(ssid))
                .unwrap_or(0);
            b_ts.cmp(&a_ts)
        });

        Ok(candidates)
    }
}

fn init_access_point_credentials(
    access_point: &AccessPoint,
    identity: &str,
    passphrase: &str,
) -> AccessPointCredentials {
    if access_point.security.contains(Security::ENTERPRISE) {
        AccessPointCredentials::Enterprise {
            identity: identity.to_string(),
            passphrase: passphrase.to_string(),
        }
    } else if access_point.security.contains(Security::WPA2)
        || access_point.security.contains(Security::WPA)
    {
        AccessPointCredentials::Wpa {
            passphrase: passphrase.to_string(),
        }
    } else if access_point.security.contains(Security::WEP) {
        AccessPointCredentials::Wep {
            passphrase: passphrase.to_string(),
        }
    } else {
        AccessPointCredentials::None
    }
}

pub fn process_network_commands(config: &Config, exit_tx: &Sender<ExitResult>) {
    let mut command_handler = match NetworkCommandHandler::new(config, exit_tx) {
        Ok(command_handler) => command_handler,
        Err(e) => {
            exit(exit_tx, e);
            return;
        }
    };

    command_handler.run(exit_tx);
}

pub fn init_networking(config: &Config) -> Result<()> {
    start_network_manager_service()?;

    delete_exising_wifi_connect_ap_profile(&config.ssid).chain_err(|| ErrorKind::DeleteAccessPoint)
}

pub fn find_device(manager: &NetworkManager, interface: &Option<String>) -> Result<Device> {
    if let Some(ref interface) = *interface {
        let device = manager
            .get_device_by_interface(interface)
            .chain_err(|| ErrorKind::DeviceByInterface(interface.clone()))?;

        info!("Targeted WiFi device: {}", interface);

        if *device.device_type() != DeviceType::WiFi {
            bail!(ErrorKind::NotAWiFiDevice(interface.clone()))
        }

        if device.get_state()? == DeviceState::Unmanaged {
            bail!(ErrorKind::UnmanagedDevice(interface.clone()))
        }

        Ok(device)
    } else {
        let devices = manager.get_devices()?;

        if let Some(device) = find_wifi_managed_device(devices)? {
            info!("WiFi device: {}", device.interface());
            Ok(device)
        } else {
            bail!(ErrorKind::NoWiFiDevice)
        }
    }
}

fn find_wifi_managed_device(devices: Vec<Device>) -> Result<Option<Device>> {
    for device in devices {
        if *device.device_type() == DeviceType::WiFi
            && device.get_state()? != DeviceState::Unmanaged
        {
            return Ok(Some(device));
        }
    }

    Ok(None)
}

fn get_access_points(device: &Device) -> Result<Vec<AccessPoint>> {
    get_access_points_impl(device).chain_err(|| ErrorKind::NoAccessPoints)
}

fn get_access_points_impl(device: &Device) -> Result<Vec<AccessPoint>> {
    let retries_allowed = 10;
    let mut retries = 0;

    // After stopping the hotspot we may have to wait a bit for the list
    // of access points to become available
    while retries < retries_allowed {
        let wifi_device = device.as_wifi_device().unwrap();
        let mut access_points = wifi_device.get_access_points()?;

        access_points.retain(|ap| ap.ssid().as_str().is_ok());

        // Purge access points with duplicate SSIDs
        let mut inserted = HashSet::new();
        access_points.retain(|ap| inserted.insert(ap.ssid.clone()));

        // Remove access points without SSID (hidden)
        access_points.retain(|ap| !ap.ssid().as_str().unwrap().is_empty());

        if !access_points.is_empty() {
            info!(
                "Access points: {:?}",
                get_access_points_ssids(&access_points)
            );
            return Ok(access_points);
        }

        retries += 1;
        debug!("No access points found - retry #{}", retries);
        thread::sleep(Duration::from_secs(1));
    }

    warn!("No access points found - giving up...");
    Ok(vec![])
}

fn get_access_points_ssids(access_points: &[AccessPoint]) -> Vec<&str> {
    access_points
        .iter()
        .map(|ap| ap.ssid().as_str().unwrap())
        .collect()
}

fn get_networks(access_points: &[AccessPoint]) -> Vec<Network> {
    access_points.iter().map(get_network_info).collect()
}

fn get_network_info(access_point: &AccessPoint) -> Network {
    Network {
        ssid: access_point.ssid().as_str().unwrap().to_string(),
        security: get_network_security(access_point).to_string(),
    }
}

fn get_network_security(access_point: &AccessPoint) -> &str {
    if access_point.security.contains(Security::ENTERPRISE) {
        "enterprise"
    } else if access_point.security.contains(Security::WPA2)
        || access_point.security.contains(Security::WPA)
    {
        "wpa"
    } else if access_point.security.contains(Security::WEP) {
        "wep"
    } else {
        "none"
    }
}

fn find_access_point<'a>(access_points: &'a [AccessPoint], ssid: &str) -> Option<&'a AccessPoint> {
    for access_point in access_points.iter() {
        if let Ok(access_point_ssid) = access_point.ssid().as_str() {
            if access_point_ssid == ssid {
                return Some(access_point);
            }
        }
    }

    None
}

fn create_portal(device: &Device, config: &Config) -> Result<Connection> {
    let portal_passphrase = config.passphrase.as_ref().map(|p| p as &str);

    create_portal_impl(device, &config.ssid, &config.gateway, &portal_passphrase)
        .chain_err(|| ErrorKind::CreateCaptivePortal)
}

fn create_portal_impl(
    device: &Device,
    ssid: &str,
    gateway: &Ipv4Addr,
    passphrase: &Option<&str>,
) -> Result<Connection> {
    info!("Starting access point...");
    let wifi_device = device.as_wifi_device().unwrap();
    let (portal_connection, _) = wifi_device.create_hotspot(ssid, *passphrase, Some(*gateway))?;
    info!("Access point '{}' created", ssid);
    Ok(portal_connection)
}

fn stop_portal(connection: &Connection, config: &Config) -> Result<()> {
    stop_portal_impl(connection, config).chain_err(|| ErrorKind::StopAccessPoint)
}

fn stop_portal_impl(connection: &Connection, config: &Config) -> Result<()> {
    info!("Stopping access point '{}'...", config.ssid);
    connection.deactivate()?;
    connection.delete()?;
    thread::sleep(Duration::from_secs(1));
    info!("Access point '{}' stopped", config.ssid);
    Ok(())
}

fn confirm_connectivity_and_log(manager: &NetworkManager) {
    match wait_for_connectivity(manager, 20) {
        Ok(has_connectivity) => {
            if has_connectivity {
                info!("Internet connectivity established");
            } else {
                warn!("Cannot establish Internet connectivity");
            }
        }
        Err(err) => error!("Getting Internet connectivity failed: {}", err),
    }
}

fn wait_for_connectivity(manager: &NetworkManager, timeout: u64) -> Result<bool> {
    let mut total_time = 0;

    loop {
        let connectivity = manager.get_connectivity()?;

        if connectivity == Connectivity::Full || connectivity == Connectivity::Limited {
            debug!(
                "Connectivity established: {:?} / {}s elapsed",
                connectivity, total_time
            );

            return Ok(true);
        } else if total_time >= timeout {
            debug!(
                "Timeout reached in waiting for connectivity: {:?} / {}s elapsed",
                connectivity, total_time
            );

            return Ok(false);
        }

        ::std::thread::sleep(::std::time::Duration::from_secs(1));

        total_time += 1;

        debug!(
            "Still waiting for connectivity: {:?} / {}s elapsed",
            connectivity, total_time
        );
    }
}

pub fn start_network_manager_service() -> Result<()> {
    let state = match NetworkManager::get_service_state() {
        Ok(state) => state,
        _ => {
            info!("Cannot get the NetworkManager service state");
            return Ok(());
        }
    };

    if state != ServiceState::Active {
        let state =
            NetworkManager::start_service(15).chain_err(|| ErrorKind::StartNetworkManager)?;
        if state != ServiceState::Active {
            bail!(ErrorKind::StartActiveNetworkManager);
        } else {
            info!("NetworkManager service started successfully");
        }
    } else {
        debug!("NetworkManager service already running");
    }

    Ok(())
}

fn delete_exising_wifi_connect_ap_profile(ssid: &str) -> Result<()> {
    let manager = NetworkManager::new();

    for connection in &manager.get_connections()? {
        if is_access_point_connection(connection) && is_same_ssid(connection, ssid) {
            info!(
                "Deleting already created by WiFi Connect access point connection profile: {:?}",
                connection.settings().ssid,
            );
            connection.delete()?;
        }
    }

    Ok(())
}

fn delete_existing_connections_to_same_network(manager: &NetworkManager, ssid: &str) {
    let connections = match manager.get_connections() {
        Ok(connections) => connections,
        Err(e) => {
            error!("Getting existing connections failed: {}", e);
            return;
        }
    };

    for connection in &connections {
        if is_wifi_connection(connection) && is_same_ssid(connection, ssid) {
            info!(
                "Deleting existing WiFi connection to the same network: {:?}",
                connection.settings().ssid,
            );

            if let Err(e) = connection.delete() {
                error!("Deleting existing WiFi connection failed: {}", e);
            }
        }
    }
}

fn is_same_ssid(connection: &Connection, ssid: &str) -> bool {
    connection_ssid_as_str(connection) == Some(ssid)
}

fn connection_ssid_as_str(connection: &Connection) -> Option<&str> {
    // An access point SSID could be random bytes and not a UTF-8 encoded string
    connection.settings().ssid.as_str().ok()
}

fn is_access_point_connection(connection: &Connection) -> bool {
    is_wifi_connection(connection) && connection.settings().mode == "ap"
}

fn is_wifi_connection(connection: &Connection) -> bool {
    connection.settings().kind == "802-11-wireless"
}

/// Whether this periodic-reconnect tick should force a fresh WiFi scan
/// regardless of what the cached scan showed. `rescan_every == 0` disables
/// forced rescanning entirely (always `false`). `tick_count` is expected to
/// already be incremented (1-based) by the caller before this is checked.
fn is_forced_rescan_tick(tick_count: u64, rescan_every: u64) -> bool {
    rescan_every > 0 && tick_count % rescan_every == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rescan_every_zero_never_forces() {
        assert!(!is_forced_rescan_tick(1, 0));
        assert!(!is_forced_rescan_tick(2, 0));
        assert!(!is_forced_rescan_tick(100, 0));
    }

    #[test]
    fn rescan_every_one_forces_every_tick() {
        assert!(is_forced_rescan_tick(1, 1));
        assert!(is_forced_rescan_tick(2, 1));
        assert!(is_forced_rescan_tick(3, 1));
    }

    #[test]
    fn rescan_every_two_forces_every_other_tick_starting_at_the_second() {
        assert!(!is_forced_rescan_tick(1, 2));
        assert!(is_forced_rescan_tick(2, 2));
        assert!(!is_forced_rescan_tick(3, 2));
        assert!(is_forced_rescan_tick(4, 2));
    }
}
