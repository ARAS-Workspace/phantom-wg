## Multihop Module

The Multihop module routes client traffic through an external VPN provider before
exiting the Phantom server, providing dual-layer encryption and location concealment.
Traffic flow is as follows:

```
Client → Phantom Server (1st encryption) → External VPN Exit (2nd encryption) → Internet
```

This architecture ensures that the destination server only sees the IP address of the
external VPN exit point; the real address of the Phantom server or client remains hidden.
Multihop works by importing standard WireGuard configuration files, making it compatible
with any VPN provider that supports WireGuard.

### Import VPN Configuration

Imports a WireGuard configuration file from an external VPN provider for use as an exit point.

```bash
phantom-api multihop import_vpn_config config_path="/home/user/xeovo-uk.conf"
```

```bash
phantom-api multihop import_vpn_config config_path="/home/user/vpn.conf" custom_name="xeovo-uk"
```

**Parameters:**

| Parameter     | Required | Description                           |
|---------------|----------|---------------------------------------|
| `config_path` | Yes      | Path to WireGuard configuration file  |
| `custom_name` | No       | Custom name for the configuration     |

**Response Model:** [`ImportResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L58)

| Field           | Type    | Description                              |
|-----------------|---------|------------------------------------------|
| `success`       | boolean | Import completed                         |
| `exit_name`     | string  | Name assigned to the configuration       |
| `message`       | string  | Result message                           |
| `optimizations` | array   | Applied optimizations (if any)           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "success": true,
        "exit_name": "xeovo-uk",
        "message": "VPN configuration imported successfully",
        "optimizations": [
          "MTU optimized for multihop",
          "PersistentKeepalive enabled"
        ]
      }
    }
    ```
