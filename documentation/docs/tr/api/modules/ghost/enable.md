### Ghost Mode'u Etkinleştir

WireGuard trafiğini HTTPS/WebSocket üzerinden tünelleyerek normal web trafiği gibi görünmesini sağlayan Ghost Mode'u etkinleştirir.

```bash
phantom-api ghost enable domain="cdn.example.com"
```

```bash
phantom-api ghost enable domain="157-230-114-231.sslip.io"
```

**Parametreler:**

| Parametre | Zorunlu | Açıklama                                                    |
|-----------|---------|-------------------------------------------------------------|
| `domain`  | Evet    | Sunucuya işaret eden A kaydına sahip alan adı (sslip.io/nip.io destekler) |

**Yanıt Modeli:** [`EnableGhostResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/ghost/models/ghost_models.py#L22)

| Alan                 | Tip      | Açıklama                                  |
|----------------------|----------|-------------------------------------------|
| `status`             | string   | Ghost Mode durumu (active)                |
| `server_ip`          | string   | Sunucunun genel IP adresi                 |
| `domain`             | string   | Tünelleme için kullanılan alan adı        |
| `secret`             | string   | WebSocket kimlik doğrulaması için benzersiz token |
| `protocol`           | string   | Tünel protokolü (wss)                     |
| `port`               | integer  | HTTPS portu (443)                         |
| `activated_at`       | datetime | Etkinleştirme zamanı                      |
| `connection_command` | string   | İstemciler için tam wstunnel komutu       |

!!! info "Notlar"
    - `secret` güvenli WebSocket tünelleme için oluşturulan benzersiz bir token'dır
    - `connection_command` istemcilerin çalıştırması gereken tam wstunnel komutunu gösterir

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "status": "active",
        "server_ip": "157.230.114.231",
        "domain": "157-230-114-231.sslip.io",
        "secret": "Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac",
        "protocol": "wss",
        "port": 443,
        "activated_at": "2025-09-09T01:41:24.079841",
        "connection_command": "wstunnel client --http-upgrade-path-prefix \"Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac\" -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://157-230-114-231.sslip.io:443"
      }
    }
    ```
