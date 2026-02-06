### Multihop'u Etkinleştir

Belirtilen VPN çıkış noktası üzerinden multihop yönlendirmeyi etkinleştirir ve çift katmanlı VPN tüneli oluşturur.

```bash
phantom-api multihop enable_multihop exit_name="xeovo-uk"
```

**Parametreler:**

| Parametre   | Zorunlu | Açıklama                              |
|-------------|---------|---------------------------------------|
| `exit_name` | Evet    | Kullanılacak VPN çıkış noktasının adı |

**Yanıt Modeli:** [`EnableMultihopResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L76)

| Alan                    | Tip     | Açıklama                                 |
|-------------------------|---------|------------------------------------------|
| `exit_name`             | string  | Aktif çıkış noktası adı                  |
| `multihop_enabled`      | boolean | Multihop başarıyla etkinleştirildi       |
| `handshake_established` | boolean | WireGuard el sıkışması tamamlandı        |
| `connection_verified`   | boolean | VPN bağlantısı doğrulandı                |
| `monitor_started`       | boolean | Bağlantı izleyicisi başlatıldı           |
| `traffic_flow`          | string  | Trafik yönlendirme yolu açıklaması       |
| `peer_access`           | string  | Eş erişilebilirlik durumu                |
| `message`               | string  | Sonuç mesajı                             |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "exit_name": "xeovo-uk",
        "multihop_enabled": true,
        "handshake_established": true,
        "connection_verified": true,
        "monitor_started": true,
        "traffic_flow": "İstemciler → Phantom → VPN Çıkışı (185.213.155.134:51820)",
        "peer_access": "Eşler hala doğrudan bağlanabilir",
        "message": "Multihop xeovo-uk üzerinden başarıyla etkinleştirildi"
      }
    }
    ```
