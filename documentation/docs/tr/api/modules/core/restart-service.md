### Servisi Yeniden Başlat

WireGuard servisini yeniden başlatır.

!!! warning
    Yeniden başlatma sırasında bağlı tüm istemcilerin bağlantısı geçici olarak kesilir.

```bash
phantom-api core restart_service
```

**Yanıt Modeli:** [`RestartResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L166)

| Alan             | Tip     | Açıklama                     |
|------------------|---------|------------------------------|
| `restarted`      | boolean | Yeniden başlatma tamamlandı  |
| `service_active` | boolean | Servis şimdi aktif           |
| `interface_up`   | boolean | Arayüz çalışıyor             |
| `service`        | string  | Servis adı                   |
| `message`        | string  | Sonuç mesajı                 |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "restarted": true,
        "service_active": true,
        "interface_up": true,
        "service": "wg-quick@wg_main",
        "message": "Service restarted successfully"
      },
      "metadata": {
        "module": "core",
        "action": "restart_service",
        "timestamp": "2025-09-09T01:16:00.000000Z",
        "version": "core-v1"
      }
    }
    ```
