### Servis Günlükleri

WireGuard servis günlük kayıtlarını döndürür.

```bash
phantom-api core service_logs
```

```bash
phantom-api core service_logs lines=100
```

**Parametreler:**

| Parametre | Zorunlu | Varsayılan | Açıklama              |
|-----------|---------|------------|-----------------------|
| `lines`   | Hayır   | 50         | Günlük satır sayısı   |

**Yanıt Modeli:** [`ServiceLogs`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L140)

| Alan              | Tip     | Açıklama                     |
|-------------------|---------|------------------------------|
| `logs`            | array   | Günlük kayıtları             |
| `count`           | integer | Döndürülen satır sayısı      |
| `service`         | string  | Servis adı                   |
| `lines_requested` | integer | İstenen satır sayısı         |
| `source`          | string  | Günlük kaynağı (journald/dosya) |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "logs": [
          "Sep 09 01:11:47 server wg-quick[1234]: [#] ip link add wg_main type wireguard",
          "Sep 09 01:11:47 server wg-quick[1234]: [#] wg setconf wg_main /dev/fd/63"
        ],
        "count": 2,
        "service": "wg-quick@wg_main",
        "lines_requested": 50,
        "source": "journald"
      },
      "metadata": {
        "module": "core",
        "action": "service_logs",
        "timestamp": "2025-09-09T01:15:10.000000Z",
        "version": "core-v1"
      }
    }
    ```
