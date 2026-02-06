### Güvenlik Duvarı Durumu

Kapsamlı güvenlik duvarı yapılandırma durumunu döndürür.

```bash
phantom-api core get_firewall_status
```

**Yanıt Modeli:** [`FirewallConfiguration`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L95)

| Alan                   | Tip     | Açıklama                     |
|------------------------|---------|------------------------------|
| `ufw.enabled`          | boolean | UFW durumu                   |
| `ufw.rules`            | array   | UFW kuralları listesi        |
| `iptables.has_rules`   | boolean | iptables kuralları mevcut    |
| `iptables.nat_rules`   | array   | NAT kuralları                |
| `iptables.filter_rules`| array   | Filtre kuralları             |
| `nat.enabled`          | boolean | NAT etkin                    |
| `nat.rules`            | array   | MASQUERADE kuralları         |
| `ports.wireguard_port` | integer | WireGuard dinleme portu      |
| `ports.listening`      | boolean | Port dinleniyor              |
| `status`               | string  | Genel güvenlik duvarı durumu |

??? example "Örnek Yanıt"
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
