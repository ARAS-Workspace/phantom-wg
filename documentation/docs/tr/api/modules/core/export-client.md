### İstemci Yapılandırmasını Dışa Aktar

Bir istemcinin WireGuard yapılandırma dosyasını dışa aktarır.

```bash
phantom-api core export_client client_name="john-laptop"

# IPv6 endpoint ile dışa aktar
phantom-api core export_client client_name="john-laptop" use_ipv6=true
```

**Parametreler:**

| Parametre     | Zorunlu | Açıklama                     |
|---------------|---------|------------------------------|
| `client_name` | Evet    | Dışa aktarılacak istemci adı |
| `use_ipv6`    | Hayır   | IPv6 endpoint kullan (`true`/`false`, varsayılan: `false`) |

**Yanıt Modeli:** [`ClientExportResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L147)

| Alan                   | Tip      | Açıklama                      |
|------------------------|----------|-------------------------------|
| `client.name`          | string   | İstemci adı                   |
| `client.ip`            | string   | Atanan IP adresi              |
| `client.created`       | datetime | Oluşturulma zamanı            |
| `client.enabled`       | boolean  | Aktiflik durumu               |
| `client.private_key`   | string   | WireGuard özel anahtarı       |
| `client.public_key`    | string   | WireGuard genel anahtarı      |
| `client.preshared_key` | string   | WireGuard paylaşılan anahtar  |
| `config`               | string   | Tam WireGuard yapılandırması  |

!!! note
    Yapılandırma, veritabanından ve mevcut DNS ayarlarından dinamik olarak üretilir.
    QR kod oluşturma CLI arayüzünde mevcuttur.

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "client": {
          "name": "john-laptop",
          "ip": "10.8.0.2",
          "created": "2025-09-09T01:14:22.076656",
          "enabled": true,
          "private_key": "INPOjXGUqhzPsS4rE65U7Ao6UXdhXNqwDoQz8HgD53s=",
          "public_key": "SKv9YRp0MgHuMCthVIMBRs4Jfwb+mO3vbfvm9jOrLSY=",
          "preshared_key": "y43/xUvLJBHe7RvsGFoHnURcTzWwrEOcJxx/tT+GQVo="
        },
        "config": "[Interface]\nPrivateKey = ...\nAddress = 10.8.0.2/24\n..."
      },
      "metadata": {
        "module": "core",
        "action": "export_client",
        "timestamp": "2025-09-09T01:14:43.740027Z",
        "version": "core-v1"
      }
    }
    ```
