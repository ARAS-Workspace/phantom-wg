### Firewall Status
```bash
phantom-api core get_firewall_status
```

**Response:**
```json
{
  "success": true,
  "data": {
    "ufw": {
      "enabled": true,
      "rules": [
        "51820/udp                  ALLOW IN    Anywhere",
        "51820/udp (v6)             ALLOW IN    Anywhere (v6)"
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
        "MASQUERADE  0    --  10.8.0.0/24          0.0.0.0/0"
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
