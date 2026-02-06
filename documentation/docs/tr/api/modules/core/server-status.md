### Sunucu Durumu

Kapsamlı sunucu sağlık ve yapılandırma bilgilerini döndürür.

```bash
phantom-api core server_status
```

**Yanıt Modeli:** [`ServiceHealth`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L184)

| Alan                             | Tip     | Açıklama                       |
|----------------------------------|---------|--------------------------------|
| `service.running`                | boolean | Servis çalışma durumu          |
| `service.service_name`           | string  | Systemd servis adı             |
| `service.started_at`             | string  | Servis başlangıç zamanı        |
| `interface.active`               | boolean | WireGuard arayüz durumu        |
| `interface.interface`            | string  | Arayüz adı                     |
| `interface.public_key`           | string  | Sunucu genel anahtarı          |
| `interface.port`                 | integer | Dinleme portu                  |
| `interface.peers`                | array   | Bağlı eşler listesi            |
| `configuration.network`          | string  | VPN alt ağı                    |
| `configuration.dns`              | array   | DNS sunucuları                 |
| `clients.total_configured`       | integer | Toplam yapılandırılmış istemci |
| `clients.enabled_clients`        | integer | Etkin istemci sayısı           |
| `clients.active_connections`     | integer | Mevcut aktif bağlantılar       |
| `system.firewall.status`         | string  | Güvenlik duvarı durumu         |
| `system.wireguard_module`        | boolean | Çekirdek modülü yüklü mü       |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "service": {
          "running": true,
          "service_name": "wg-quick@wg_main",
          "started_at": "Tue 2025-09-09 01:11:47 UTC"
        },
        "interface": {
          "active": true,
          "interface": "wg_main",
          "public_key": "Y/V6vf2w+AWpqz3h6DYAOHuW3ZJ3vZ0jSc8D0edVthw=",
          "port": 51820,
          "peers": [...]
        },
        "configuration": {
          "network": "10.8.0.0/24",
          "dns": ["8.8.8.8", "8.8.4.4"]
        },
        "clients": {
          "total_configured": 1,
          "enabled_clients": 1,
          "active_connections": 0
        },
        "system": {
          "firewall": {"status": "active"},
          "wireguard_module": true
        }
      },
      "metadata": {
        "module": "core",
        "action": "server_status",
        "timestamp": "2025-09-09T01:15:03.512070Z",
        "version": "core-v1"
      }
    }
    ```
