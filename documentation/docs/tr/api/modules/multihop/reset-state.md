### Multihop Durumunu Sıfırla

Arayüzleri, yönlendirme kurallarını ve izleyici süreçlerini temizleyerek multihop durumunu sıfırlar.

```bash
phantom-api multihop reset_state
```

**Yanıt Modeli:** [`ResetStateResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L166)

| Alan                | Tip     | Açıklama                                 |
|---------------------|---------|------------------------------------------|
| `reset_complete`    | boolean | Sıfırlama başarıyla tamamlandı           |
| `cleanup_successful`| boolean | Temizleme işlemleri başarılı             |
| `cleaned_up`        | array   | Temizlenen öğelerin listesi              |
| `message`           | string  | Sonuç mesajı                             |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "reset_complete": true,
        "cleanup_successful": true,
        "cleaned_up": [
          "wg-multihop interface",
          "routing rules",
          "monitor process"
        ],
        "message": "Multihop state reset successfully"
      }
    }
    ```
