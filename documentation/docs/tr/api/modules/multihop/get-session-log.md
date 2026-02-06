### Oturum Günlüğünü Al

Bağlantı olayları ve durum değişiklikleri içeren multihop oturum günlüğünü alır.

```bash
phantom-api multihop get_session_log
```

```bash
phantom-api multihop get_session_log lines=100
```

**Parametreler:**

| Parametre | Zorunlu | Açıklama                                    |
|-----------|---------|---------------------------------------------|
| `lines`   | Hayır   | Alınacak satır sayısı (varsayılan: 50)      |

**Yanıt Modeli:** [`SessionLog`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L182)

| Alan                 | Tip    | Açıklama                                 |
|----------------------|--------|------------------------------------------|
| `logs[].timestamp`   | string | Olay zamanı                              |
| `logs[].exit_name`   | string | Çıkış noktası adı                        |
| `logs[].event`       | string | Olay türü                                |
| `logs[].details`     | object | Ek olay detayları                        |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "logs": [
          {
            "timestamp": "2025-09-09T01:20:00.000000",
            "exit_name": "xeovo-uk",
            "event": "enabled",
            "details": {
              "endpoint": "uk.gw.xeovo.com:51820",
              "handshake": true
            }
          },
          {
            "timestamp": "2025-09-09T01:25:00.000000",
            "exit_name": "xeovo-uk",
            "event": "health_check",
            "details": {
              "status": "healthy"
            }
          }
        ]
      }
    }
    ```
