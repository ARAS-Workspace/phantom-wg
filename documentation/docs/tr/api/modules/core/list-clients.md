### İstemcileri Listele

Sayfalama ve arama desteği ile tüm WireGuard istemcilerini listeler.

```bash
phantom-api core list_clients
```

```bash
phantom-api core list_clients page=2 per_page=20
```

```bash
phantom-api core list_clients search="john"
```

**Parametreler:**

| Parametre  | Zorunlu | Varsayılan | Açıklama             |
|------------|---------|------------|----------------------|
| `page`     | Hayır   | 1          | Sayfa numarası       |
| `per_page` | Hayır   | 10         | Sayfa başına öğe     |
| `search`   | Hayır   | -          | Arama terimi         |

**Yanıt Modeli:** [`ClientListResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L119)

| Alan                       | Tip      | Açıklama                    |
|----------------------------|----------|-----------------------------|
| `clients`                  | array    | İstemci nesneleri listesi   |
| `clients[].name`           | string   | İstemci adı                 |
| `clients[].ip`             | string   | Atanan IP adresi            |
| `clients[].enabled`        | boolean  | Aktiflik durumu             |
| `clients[].created`        | datetime | Oluşturulma zamanı          |
| `clients[].connected`      | boolean  | Mevcut bağlantı durumu      |
| `total`                    | integer  | Toplam istemci sayısı       |
| `pagination.page`          | integer  | Mevcut sayfa numarası       |
| `pagination.per_page`      | integer  | Sayfa başına öğe sayısı     |
| `pagination.total_pages`   | integer  | Toplam sayfa sayısı         |
| `pagination.has_next`      | boolean  | Sonraki sayfa var mı        |
| `pagination.has_prev`      | boolean  | Önceki sayfa var mı         |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "total": 1,
        "clients": [
          {
            "name": "john-laptop",
            "ip": "10.8.0.2",
            "enabled": true,
            "created": "2025-09-09T01:14:22.076656",
            "connected": false
          }
        ],
        "pagination": {
          "page": 1,
          "per_page": 10,
          "total_pages": 1,
          "has_next": false,
          "has_prev": false,
          "showing_from": 1,
          "showing_to": 1
        }
      },
      "metadata": {
        "module": "core",
        "action": "list_clients",
        "timestamp": "2025-09-09T01:14:32.551562Z",
        "version": "core-v1"
      }
    }
    ```
