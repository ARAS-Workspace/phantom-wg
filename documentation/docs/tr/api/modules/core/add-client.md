### İstemci Ekle

Sunucuya yeni bir WireGuard istemcisi ekler.

```bash
phantom-api core add_client client_name="john-laptop"
```

**Parametreler:**

| Parametre     | Zorunlu | Açıklama                                       |
|---------------|---------|------------------------------------------------|
| `client_name` | Evet    | Alfanümerik karakterler, tire ve alt çizgi     |

**Yanıt Modeli:** [`ClientAddResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L58)

| Alan                | Tip      | Açıklama                 |
|---------------------|----------|--------------------------|
| `client.name`       | string   | İstemci adı              |
| `client.ip`         | string   | Atanan IP adresi         |
| `client.public_key` | string   | WireGuard genel anahtarı |
| `client.created`    | datetime | Oluşturulma zamanı       |
| `client.enabled`    | boolean  | Aktiflik durumu          |
| `message`           | string   | İşlem sonuç mesajı       |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "client": {
          "name": "john-laptop",
          "ip": "10.8.0.2",
          "public_key": "SKv9YRp0MgHuMCthVIMBRs4Jfwb+mO3vbfvm9jOrLSY=",
          "created": "2025-09-09T01:14:22.076656",
          "enabled": true
        },
        "message": "Client added successfully"
      },
      "metadata": {
        "module": "core",
        "action": "add_client",
        "timestamp": "2025-09-09T01:14:22.119132Z",
        "version": "core-v1"
      }
    }
    ```
