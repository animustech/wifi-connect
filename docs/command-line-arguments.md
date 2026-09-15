# WiFi Connect Command Line Arguments

## Flags

*   **-h, --help**

    Prints help information

*   **-V, --version**

    Prints version information

## Options

Command line options have environment variable counterpart. If both a command line option and its environment variable counterpart are defined, the command line option will take higher precedence.

*   **-d, --portal-dhcp-range** dhcp_range, **$PORTAL_DHCP_RANGE**

    DHCP range of the captive portal WiFi network

    Default: _192.168.42.2,192.168.42.254_

*   **-g, --portal-gateway** gateway, **$PORTAL_GATEWAY**

    Gateway of the captive portal WiFi network

    Default: _192.168.42.1_

*   **-o, --portal-listening-port** listening_port, **$PORTAL_LISTENING_PORT**

    Listening port of the captive portal web server

    Default: _80_

*   **-i, --portal-interface** interface, **$PORTAL_INTERFACE**

    Wireless network interface to be used by WiFi Connect

*   **-p, --portal-passphrase** passphrase, **$PORTAL_PASSPHRASE**

    WPA2 Passphrase of the captive portal WiFi network

    Default: _no passphrase_

*   **-s, --portal-ssid** ssid, **$PORTAL_SSID**

    SSID of the captive portal WiFi network

    Default: _WiFi Connect_

*   **-a, --activity-timeout** timeout, **$ACTIVITY_TIMEOUT**

    Exit if no activity for the specified timeout (seconds)

    Default: _0 - no timeout_

*   **-u, --ui-directory** ui_directory, **$UI_DIRECTORY**

    Web UI directory location

    Default: _ui_

*   **--reconnect-enabled** reconnect_enabled, **$RECONNECT_ENABLED**

    Periodically retry saved WiFi networks in range while the captive portal is active (true/false)

    Default: _true_

*   **--reconnect-interval-minutes** reconnect_interval_minutes, **$RECONNECT_INTERVAL_MINUTES**

    Minutes between periodic reconnect attempts

    Default: _30_

*   **--reconnect-rescan-every** reconnect_rescan_every, **$RECONNECT_RESCAN_EVERY**

    Force a fresh WiFi scan every Nth periodic reconnect attempt, regardless of cached candidates; 0 disables forced rescanning

    Default: _2_
