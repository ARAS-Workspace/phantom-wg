### Multihop Durumu

VPN arayüz durumu ve trafik yönlendirme bilgileri dahil mevcut multihop durumunu alır.

```bash
phantom-api multihop status
```

**Yanıt Modeli:** [`MultihopStatusResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L216)

| Alan                       | Tip     | Açıklama                                 |
|----------------------------|---------|------------------------------------------|
| `enabled`                  | boolean | Multihop şu anda etkin                   |
| `active_exit`              | string  | Şu anda aktif çıkış adı                  |
| `available_configs`        | integer | Mevcut yapılandırma sayısı               |
| `vpn_interface.active`     | boolean | VPN arayüzü aktif                        |
| `vpn_interface.error`      | string  | Hata mesajı (pasifse)                    |
| `monitor_status.monitoring`| boolean | Bağlantı izleme aktif                    |
| `monitor_status.type`      | string  | İzleyici türü                            |
| `monitor_status.pid`       | integer | İzleyici süreç ID'si                     |
| `traffic_routing`          | string  | Yönlendirme modu (Direct/Multihop)       |
| `traffic_flow`             | string  | Trafik akışı açıklaması                  |

??? example "Örnek Yanıt (Pasif)"
    ```json
    {
      "success": true,
      "data": {
        "enabled": false,
        "active_exit": null,
        "available_configs": 1,
        "vpn_interface": {
          "active": false,
          "error": "VPN arayüzü aktif değil"
        },
        "monitor_status": {
          "monitoring": false,
          "type": null,
          "pid": null
        },
        "traffic_routing": "Doğrudan",
        "traffic_flow": "İstemciler -> Phantom Sunucusu -> İnternet (doğrudan)"
      }
    }
    ```

??? example "Örnek Yanıt (Aktif)"
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
        "traffic_flow": "İstemciler -> Phantom -> VPN Çıkışı (185.213.155.134:51820)"
      }
    }
    ```
