### Tweak Ayarları

Sistem davranış ayarlarını görüntüle ve değiştir.

```bash
phantom-api core get_tweak_settings
```

```bash
phantom-api core update_tweak_setting setting_name="restart_service_after_client_creation" value=false
```

**update_tweak_setting için parametreler:**

| Parametre      | Zorunlu | Açıklama                                      |
|----------------|---------|-----------------------------------------------|
| `setting_name` | Evet    | Güncellenecek ayarın adı                      |
| `value`        | Evet    | Yeni değer (string olarak boolean: "true"/"false") |

**Mevcut Ayarlar:**

| Ayar                                    | Varsayılan | Açıklama                                        |
|-----------------------------------------|------------|-------------------------------------------------|
| `restart_service_after_client_creation` | false      | İstemci ekledikten sonra WireGuard servisini yeniden başlat |

!!! info
    `false` olduğunda: İstemcileri dinamik olarak eklemek için `wg set` komutunu kullanır (servis yeniden başlatılmaz).
    `true` olduğunda: Tüm WireGuard servisini yeniden başlatır (tüm istemciler için geçici bağlantı kesilmesine neden olur).

**Yanıt Modeli (get):** [`TweakSettingsResponse`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/config_models.py#L22)

**Yanıt Modeli (update):** [`TweakModificationResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/config_models.py#L36)

| Alan          | Tip     | Açıklama           |
|---------------|---------|--------------------|
| `setting`     | string  | Ayar adı           |
| `new_value`   | boolean | Yeni değer         |
| `old_value`   | boolean | Önceki değer       |
| `message`     | string  | Sonuç mesajı       |
| `description` | string  | Ayar açıklaması    |

??? example "Örnek Yanıt (get)"
    ```json
    {
      "success": true,
      "data": {
        "restart_service_after_client_creation": false,
        "restart_service_after_client_creation_description": "Restart WireGuard service after adding & removing clients"
      }
    }
    ```

??? example "Örnek Yanıt (update)"
    ```json
    {
      "success": true,
      "data": {
        "setting": "restart_service_after_client_creation",
        "new_value": true,
        "old_value": false,
        "message": "Setting updated successfully",
        "description": "Restart WireGuard service after adding & removing clients"
      }
    }
    ```
