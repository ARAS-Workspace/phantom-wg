### VPN Yapılandırmasını Kaldır

İçe aktarılmış bir VPN çıkış yapılandırmasını sistemden kaldırır.

```bash
phantom-api multihop remove_vpn_config exit_name="xeovo-uk"
```

**Parametreler:**

| Parametre   | Zorunlu | Açıklama                                 |
|-------------|---------|------------------------------------------|
| `exit_name` | Evet    | Kaldırılacak VPN yapılandırmasının adı   |

**Yanıt Modeli:** [`RemoveConfigResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L116)

| Alan         | Tip     | Açıklama                                 |
|--------------|---------|------------------------------------------|
| `removed`    | string  | Kaldırılan yapılandırmanın adı           |
| `was_active` | boolean | Kaldırmadan önce yapılandırma aktif miydi|
| `message`    | string  | Sonuç mesajı                             |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "removed": "xeovo-uk",
        "was_active": false,
        "message": "VPN configuration removed successfully"
      }
    }
    ```
