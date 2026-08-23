# air-Q for Omarchy

A Quickshell bar widget for local [air-Q](https://www.air-q.com/) air quality
monitors. Two dots show the health index first and performance index second.
Each dot is green at or above 80%, yellow from 60% to 80%, and red below 60%;
unavailable or stale readings are gray.

Clicking the widget opens a panel with all measurements exposed by the device,
sensor status, measurement age, health, and performance. The last good reading
remains visible and is marked stale during connection failures while the plugin
retries automatically.

## Requirements

- Omarchy with the Quickshell desktop shell
- An air-Q device reachable on the local network
- `curl`
- `secret-tool` and an available desktop Secret Service
- `xdg-open` to open the device page from the widget

## Install

```bash
omarchy plugin add https://github.com/sgruendel/omarchy-airq.git --enable
omarchy bar set sgruendel.airq host YOUR_AIRQ_HOST
omarchy bar set sgruendel.airq serial YOUR_AIRQ_SERIAL
```

Use the hostname or IP address only for `host`, without `http://` or a trailing
slash.

Store the device password in the desktop keyring without adding it to shell
history:

```bash
AIRQ_SERIAL="YOUR_AIRQ_SERIAL"
read -rsp "air-Q password: " AIRQ_DEVICE_PASSWORD
printf '\n'
printf '%s' "$AIRQ_DEVICE_PASSWORD" | secret-tool store \
  --label='air-Q device password' \
  application omarchy-airq serial "$AIRQ_SERIAL"
unset AIRQ_DEVICE_PASSWORD
```

## Controls

- Left click: open or close the detail panel
- Middle click: refresh now
- Right click: open the air-Q device page
- `R` in the panel: refresh now
- `O` in the panel: open the device page
- `Esc`: close the panel

## Configuration

Settings can be changed through the Omarchy bar widget settings or with
`omarchy bar set sgruendel.airq KEY VALUE`.

| Key | Default | Purpose |
| --- | ---: | --- |
| `host` | empty | Device hostname or IP address |
| `serial` | empty | Device serial number |
| `refreshSeconds` | `30` | Polling interval in seconds (minimum 10) |
| `radonWarning` | `100` | Radon warning threshold in Bq/m³ |
| `indexGreenThreshold` | `80` | Minimum green health/performance index |
| `indexYellowThreshold` | `60` | Minimum yellow health/performance index |

## Security and privacy

The plugin talks directly to the air-Q device over the local network and does
not use a cloud service. The device password is looked up in the desktop Secret
Service and is never stored in Omarchy's `shell.json` or passed in process
arguments. The encrypted API response is decrypted inside the plugin.

Like other Quickshell plugins, this plugin is not sandboxed. Review the source
before installing it.

## Remove

```bash
omarchy plugin remove sgruendel.airq
secret-tool clear application omarchy-airq serial YOUR_AIRQ_SERIAL
```

The second command is optional and removes the saved device password from the
desktop keyring.

## License

[MIT](LICENSE)
