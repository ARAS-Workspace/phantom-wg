### Çıkış Noktalarını Listele

Tüm içe aktarılmış VPN çıkış yapılandırmalarını listeler ve mevcut multihop durumunu gösterir.

```bash
phantom-api multihop list_exits
```

**Yanıt Modeli:** [`ListExitsResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L200)

| Alan                           | Tip     | Açıklama                                 |
|--------------------------------|---------|------------------------------------------|
| `exits[].name`                 | string  | Çıkış yapılandırma adı                   |
| `exits[].endpoint`             | string  | VPN sunucu uç noktası                    |
| `exits[].active`               | boolean | Şu anda aktif çıkış                      |
| `exits[].provider`             | string  | VPN sağlayıcı adı                        |
| `exits[].imported_at`          | string  | İçe aktarma zamanı                       |
| `exits[].multihop_enhanced`    | boolean | Multihop için optimize edilmiş yapılandırma |
| `multihop_enabled`             | boolean | Multihop şu anda etkin                   |
| `active_exit`                  | string  | Şu anda aktif çıkış adı                  |
| `total`                        | integer | Toplam yapılandırma sayısı               |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "exits": [
          {
            "name": "xeovo-uk",
            "endpoint": "uk.gw.xeovo.com:51820",
            "active": false,
            "provider": "Unknown Provider",
            "imported_at": "2025-09-09T01:16:21.977967",
            "multihop_enhanced": true
          }
        ],
        "multihop_enabled": false,
        "active_exit": null,
        "total": 1
      }
    }
    ```
