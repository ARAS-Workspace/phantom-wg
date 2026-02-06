### Enable Multihop

Enables multihop routing through the specified VPN exit point, creating a dual-layer VPN tunnel.

```bash
phantom-api multihop enable_multihop exit_name="xeovo-uk"
```

**Parameters:**

| Parameter   | Required | Description                    |
|-------------|----------|--------------------------------|
| `exit_name` | Yes      | Name of the VPN exit to use    |

**Response Model:** [`EnableMultihopResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L76)

| Field                   | Type    | Description                              |
|-------------------------|---------|------------------------------------------|
| `exit_name`             | string  | Active exit point name                   |
| `multihop_enabled`      | boolean | Multihop successfully enabled            |
| `handshake_established` | boolean | WireGuard handshake completed            |
| `connection_verified`   | boolean | VPN connection verified                  |
| `monitor_started`       | boolean | Connection monitor started               |
| `traffic_flow`          | string  | Traffic routing path description         |
| `peer_access`           | string  | Peer accessibility status                |
| `message`               | string  | Result message                           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "exit_name": "xeovo-uk",
        "multihop_enabled": true,
        "handshake_established": true,
        "connection_verified": true,
        "monitor_started": true,
        "traffic_flow": "Clients → Phantom → VPN Exit (185.213.155.134:51820)",
        "peer_access": "Peers can still connect directly",
        "message": "Multihop successfully enabled via xeovo-uk"
      }
    }
    ```
