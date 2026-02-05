### Tweak Ayarları

```bash
# Tüm tweak ayarlarını al
phantom-api core get_tweak_settings

# Belirli bir ayarı güncelle
phantom-api core update_tweak_setting setting_name="restart_service_after_client_creation" value=false
```

**update_tweak_setting için parametreler:**

- `setting_name` (zorunlu): Güncellenecek ayarın adı
- `value` (zorunlu): Yeni değer (string olarak boolean: "true"/"false")

**Mevcut Ayarlar:**

- `restart_service_after_client_creation`: İstemci eklerken WireGuard servisini yeniden başlatır mı
  (varsayılan: false)
  - `false` olduğunda: İstemcileri dinamik olarak eklemek için `wg set` komutunu kullanır
    (servis yeniden başlatılmaz)
  - `true` olduğunda: Tüm WireGuard servisini yeniden başlatır (tüm istemciler için geçici bağlantı
    kesilmesine neden olur)

**get_tweak_settings için yanıt:**

```json
{
  "success": true,
  "data": {
    "restart_service_after_client_creation": false,
    "restart_service_after_client_creation_description": "Restart WireGuard service after adding & removing clients (causes connection drops)"
  }
}
```
