## Multihop Modülü

Multihop modülü, istemci trafiğini Phantom sunucusundan çıkmadan önce bir harici VPN
sağlayıcısı üzerinden geçirerek çift katmanlı şifreleme ve konum gizleme sağlar.
Trafik akışı şu şekilde gerçekleşir:

```
İstemci → Phantom Sunucusu (1. şifreleme) → Harici VPN Çıkışı (2. şifreleme) → İnternet
```

Bu yapı sayesinde hedef sunucu yalnızca harici VPN çıkış noktasının IP adresini görür;
Phantom sunucusunun veya istemcinin gerçek adresi gizli kalır. Multihop, standart
WireGuard yapılandırma dosyalarını içe aktararak çalışır; bu nedenle WireGuard destekleyen
herhangi bir VPN sağlayıcısıyla uyumludur.

### VPN Yapılandırmasını İçe Aktar

Çıkış noktası olarak kullanmak üzere harici bir VPN sağlayıcısından WireGuard yapılandırma dosyası içe aktarır.

```bash
phantom-api multihop import_vpn_config config_path="/home/user/xeovo-uk.conf"
```

```bash
phantom-api multihop import_vpn_config config_path="/home/user/vpn.conf" custom_name="xeovo-uk"
```

**Parametreler:**

| Parametre     | Zorunlu | Açıklama                              |
|---------------|---------|---------------------------------------|
| `config_path` | Evet    | WireGuard yapılandırma dosyasının yolu|
| `custom_name` | Hayır   | Yapılandırma için özel isim           |

**Yanıt Modeli:** [`ImportResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L58)

| Alan            | Tip     | Açıklama                                 |
|-----------------|---------|------------------------------------------|
| `success`       | boolean | İçe aktarma tamamlandı                   |
| `exit_name`     | string  | Yapılandırmaya atanan isim               |
| `message`       | string  | Sonuç mesajı                             |
| `optimizations` | array   | Uygulanan optimizasyonlar (varsa)        |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "success": true,
        "exit_name": "xeovo-uk",
        "message": "VPN configuration imported successfully",
        "optimizations": [
          "MTU optimized for multihop",
          "PersistentKeepalive enabled"
        ]
      }
    }
    ```
