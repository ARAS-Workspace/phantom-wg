### Multihop'u Devre Dışı Bırak

Multihop yönlendirmeyi devre dışı bırakır ve Phantom sunucusundan internete doğrudan trafik akışını geri yükler.

```bash
phantom-api multihop disable_multihop
```

**Yanıt Modeli:** [`DeactivationResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L100)

| Alan                | Tip     | Açıklama                                 |
|---------------------|---------|------------------------------------------|
| `multihop_enabled`  | boolean | Multihop durumu (false)                  |
| `previous_exit`     | string  | Önceden aktif olan çıkış noktası         |
| `interface_cleaned` | boolean | VPN arayüzü temizlendi                   |
| `message`           | string  | Sonuç mesajı                             |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "multihop_enabled": false,
        "previous_exit": "xeovo-uk",
        "interface_cleaned": true,
        "message": "Multihop disabled successfully"
      }
    }
    ```
