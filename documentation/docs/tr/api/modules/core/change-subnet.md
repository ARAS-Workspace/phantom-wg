### Varsayılan Subnet'i Değiştir

Mevcut subnet bilgisini görüntüle, değişiklikleri doğrula ve yeni bir subnet'e geçiş yap.

```bash
phantom-api core get_subnet_info
```

```bash
phantom-api core validate_subnet_change new_subnet="192.168.100.0/24"
```

```bash
phantom-api core change_subnet new_subnet="192.168.100.0/24" confirm=true
```

**change_subnet için parametreler:**

| Parametre    | Zorunlu | Açıklama                       |
|--------------|---------|--------------------------------|
| `new_subnet` | Evet    | CIDR notasyonunda yeni subnet  |
| `confirm`    | Evet    | Çalıştırmak için `true` olmalı |

**Yanıt Modeli:** [`NetworkMigrationResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/network_models.py#L155)

| Alan              | Tip     | Açıklama                     |
|-------------------|---------|------------------------------|
| `success`         | boolean | Geçiş tamamlandı             |
| `old_subnet`      | string  | Önceki subnet                |
| `new_subnet`      | string  | Yeni subnet                  |
| `clients_updated` | integer | Güncellenen istemci sayısı   |
| `backup_id`       | string  | Yedekleme tanımlayıcısı      |
| `ip_mapping`      | object  | Eski → yeni IP eşleştirmesi  |

!!! warning "Önemli Notlar"
    - Ghost Mode veya Multihop aktifken subnet değişikliği engellenir
    - Değişiklik sırasında tüm istemcilerin bağlantısı kesilir
    - İstemci yapılandırmaları otomatik olarak güncellenir
    - Güvenlik duvarı kuralları (iptables ve UFW) otomatik olarak güncellenir
    - Değişikliklerden önce tam yedekleme oluşturulur
    - Hata durumunda otomatik geri alma yapılır

??? example "Örnek Yanıt (get_subnet_info)"
    ```json
    {
      "success": true,
      "data": {
        "current_subnet": "10.8.0.0/24",
        "subnet_size": 254,
        "server_ip": "10.8.0.1",
        "can_change": true,
        "blockers": {
          "ghost_mode": false,
          "multihop": false
        }
      }
    }
    ```

??? example "Örnek Yanıt (change_subnet)"
    ```json
    {
      "success": true,
      "data": {
        "success": true,
        "old_subnet": "10.8.0.0/24",
        "new_subnet": "192.168.100.0/24",
        "clients_updated": 5,
        "backup_id": "subnet_change_1738257600",
        "ip_mapping": {
          "10.8.0.1": "192.168.100.1",
          "10.8.0.2": "192.168.100.2"
        }
      }
    }
    ```
