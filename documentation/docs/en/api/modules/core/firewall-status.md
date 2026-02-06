### Firewall Status

Returns comprehensive firewall configuration status.

```bash
phantom-api core get_firewall_status
```

**Response Model:** [`FirewallConfiguration`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L95)

| Field                   | Type    | Description              |
|-------------------------|---------|--------------------------|
| `ufw.enabled`           | boolean | UFW status               |
| `ufw.rules`             | array   | UFW rules list           |
| `iptables.has_rules`    | boolean | iptables rules exist     |
| `iptables.nat_rules`    | array   | NAT rules                |
| `iptables.filter_rules` | array   | Filter rules             |
| `nat.enabled`           | boolean | NAT enabled              |
| `nat.rules`             | array   | MASQUERADE rules         |
| `ports.wireguard_port`  | integer | WireGuard listening port |
| `ports.listening`       | boolean | Port is listening        |
| `status`                | string  | Overall firewall status  |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "ufw": {
          "enabled": true,
          "rules": [
            "51820/udp ALLOW IN Anywhere"
          ]
        },
        "iptables": {
          "has_rules": true,
          "nat_rules": [],
          "filter_rules": []
        },
        "nat": {
          "enabled": true,
          "rules": [
            "MASQUERADE 0 -- 10.8.0.0/24 0.0.0.0/0"
          ]
        },
        "ports": {
          "wireguard_port": 51820,
          "listening": true
        },
        "status": "active"
      },
      "metadata": {
        "module": "core",
        "action": "get_firewall_status",
        "timestamp": "2025-07-11T05:15:59.611420Z",
        "version": "core-v1"
      }
    }
    ```
