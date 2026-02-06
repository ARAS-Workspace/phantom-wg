### Multihop Status

Retrieves the current multihop status including VPN interface state and traffic routing information.

```bash
phantom-api multihop status
```

**Response Model:** [`MultihopStatusResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L216)

| Field                      | Type    | Description                              |
|----------------------------|---------|------------------------------------------|
| `enabled`                  | boolean | Multihop currently enabled               |
| `active_exit`              | string  | Currently active exit name               |
| `available_configs`        | integer | Number of available configurations       |
| `vpn_interface.active`     | boolean | VPN interface is active                  |
| `vpn_interface.error`      | string  | Error message (if inactive)              |
| `monitor_status.monitoring`| boolean | Connection monitoring active             |
| `monitor_status.type`      | string  | Monitor type                             |
| `monitor_status.pid`       | integer | Monitor process ID                       |
| `traffic_routing`          | string  | Routing mode (Direct/Multihop)           |
| `traffic_flow`             | string  | Traffic flow description                 |

??? example "Example Response (Inactive)"
    ```json
    {
      "success": true,
      "data": {
        "enabled": false,
        "active_exit": null,
        "available_configs": 1,
        "vpn_interface": {
          "active": false,
          "error": "VPN interface not active"
        },
        "monitor_status": {
          "monitoring": false,
          "type": null,
          "pid": null
        },
        "traffic_routing": "Direct",
        "traffic_flow": "Clients -> Phantom Server -> Internet (direct)"
      }
    }
    ```

??? example "Example Response (Active)"
    ```json
    {
      "success": true,
      "data": {
        "enabled": true,
        "active_exit": "xeovo-uk",
        "available_configs": 1,
        "vpn_interface": {
          "active": true,
          "interface": "wg-multihop",
          "handshake": "recent"
        },
        "monitor_status": {
          "monitoring": true,
          "type": "health_check",
          "pid": 12345
        },
        "traffic_routing": "Multihop",
        "traffic_flow": "Clients -> Phantom -> VPN Exit (185.213.155.134:51820)"
      }
    }
    ```
