### Ghost Mode'u Devre Dışı Bırak

Ghost Mode'u devre dışı bırakır ve port 51820'de standart WireGuard bağlantısını geri yükler.

```bash
phantom-api ghost disable
```

**Yanıt Modeli:** [`DisableGhostResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/ghost/models/ghost_models.py#L46)

| Alan       | Tip     | Açıklama                                    |
|------------|---------|---------------------------------------------|
| `status`   | string  | Ghost Mode durumu (inactive)                |
| `message`  | string  | Sonuç mesajı                                |
| `restored` | boolean | Doğrudan WireGuard bağlantısı geri yüklendi |

!!! info "Notlar"
    - Port 51820'de doğrudan WireGuard bağlantısını geri yükler
    - Tüm istemciler otomatik olarak standart WireGuard yapılandırmasına döner

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "status": "inactive",
        "message": "Ghost Mode disabled successfully",
        "restored": true
      }
    }
    ```
