### Ghost Mode Durumu

Ghost Mode'un mevcut durumunu ve yapılandırma detaylarını alır.

```bash
phantom-api ghost status
```

**Yanıt Modeli:** [`GhostStatusResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/ghost/models/ghost_models.py#L72)

| Alan                 | Tip     | Açıklama                                 |
|----------------------|---------|------------------------------------------|
| `status`             | string  | Mevcut durum (active/inactive)           |
| `enabled`            | boolean | Ghost Mode etkin                         |
| `message`            | string  | Durum mesajı (pasifken)                  |
| `server_ip`          | string  | Sunucunun genel IP'si (aktifken)         |
| `domain`             | string  | Yapılandırılmış alan adı (aktifken)      |
| `secret`             | string  | WebSocket secret (aktifken)              |
| `protocol`           | string  | Tünel protokolü (aktifken)               |
| `port`               | integer | HTTPS portu (aktifken)                   |
| `services.wstunnel`  | string  | wstunnel servis durumu (aktifken)        |
| `activated_at`       | string  | Etkinleştirme zamanı (aktifken)          |
| `connection_command` | string  | wstunnel komutu (aktifken)               |
| `client_export_info` | string  | İstemci dışa aktarma bilgisi (aktifken)  |

??? example "Örnek Yanıt (Pasif)"
    ```json
    {
      "success": true,
      "data": {
        "status": "inactive",
        "enabled": false,
        "message": "Ghost Mode is not active"
      }
    }
    ```

??? example "Örnek Yanıt (Aktif)"
    ```json
    {
      "success": true,
      "data": {
        "status": "active",
        "enabled": true,
        "server_ip": "157.230.114.231",
        "domain": "157-230-114-231.sslip.io",
        "secret": "Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac",
        "protocol": "wss",
        "port": 443,
        "services": {
          "wstunnel": "active"
        },
        "activated_at": "2025-09-09T01:41:24.079841",
        "connection_command": "wstunnel client --http-upgrade-path-prefix \"Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac\" -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://157-230-114-231.sslip.io:443",
        "client_export_info": "Use 'phantom-casper <client_name>' to export client configurations"
      }
    }
    ```
