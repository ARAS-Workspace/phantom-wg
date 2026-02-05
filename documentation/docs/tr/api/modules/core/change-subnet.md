### Varsayılan Subnet'i Değiştir

```bash
# Mevcut subnet bilgisini al
phantom-api core get_subnet_info

# Yeni bir subnet'i doğrula
phantom-api core validate_subnet_change new_subnet="192.168.100.0/24"

# Subnet'i değiştir (onay gerekir)
phantom-api core change_subnet new_subnet="192.168.100.0/24" confirm=true
```

**get_subnet_info için yanıt:**
```json
{
  "success": true,
  "data": {
    "current_subnet": "10.8.0.0/24",
    "subnet_size": 254,
    "usable_ips": 254,
    "network_address": "10.8.0.0",
    "broadcast_address": "10.8.0.255",
    "netmask": "255.255.255.0",
    "prefixlen": 24,
    "clients": {
      "total": 1,
      "active": 0,
      "ip_usage_percentage": 0.39
    },
    "server_ip": "10.8.0.1",
    "first_client_ip": "10.8.0.2",
    "last_client_ip": "10.8.0.254",
    "can_change": true,
    "blockers": {
      "ghost_mode": false,
      "multihop": false,
      "active_connections": false
    },
    "main_interface": {
      "interface": "eth0",
      "ip": "165.227.146.222",
      "network": "165.227.146.222/20"
    },
    "warnings": [
      "WireGuard service will be restarted",
      "Firewall rules will be updated",
      "Brief connectivity interruption expected"
    ]
  },
  "metadata": {
    "module": "core",
    "action": "get_subnet_info",
    "timestamp": "2025-07-11T05:17:09.346288Z",
    "version": "core-v1"
  }
}
```

**validate_subnet_change için yanıt:**
```json
{
  "success": true,
  "data": {
    "valid": true,
    "new_subnet": "192.168.100.0/24",
    "current_subnet": "10.8.0.0/24",
    "checks": {
      "subnet_size": {
        "valid": true,
        "usable_ips": 254,
        "prefixlen": 24
      },
      "private_subnet": {
        "valid": true,
        "private_range": "192.168.0.0/16"
      },
      "network_conflicts": {
        "valid": true,
        "conflicts": []
      },
      "capacity": {
        "valid": true,
        "usable_ips": 254,
        "required_ips": 2,
        "utilization_after": 0.39
      }
    },
    "warnings": [],
    "errors": [],
    "ip_mapping_preview": {
      "total_mappings": 2,
      "mappings": {
        "server": {
          "old": "10.8.0.1",
          "new": "192.168.100.1"
        },
        "test-api-demo": {
          "old": "10.8.0.2",
          "new": "192.168.100.2"
        }
      }
    }
  },
  "metadata": {
    "module": "core",
    "action": "validate_subnet_change",
    "timestamp": "2025-07-11T05:17:17.124283Z",
    "version": "core-v1"
  }
}
```

**change_subnet için yanıt:**
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
      "10.8.0.2": "192.168.100.2",
      "10.8.0.3": "192.168.100.3"
    },
    "message": "Successfully changed subnet from 10.8.0.0/24 to 192.168.100.0/24"
  }
}
```

**Önemli Notlar:**

- Ghost Mode veya Multihop aktifken subnet değişikliği engellenir
- Değişiklik sırasında tüm istemcilerin bağlantısı kesilir
- İstemci yapılandırmaları otomatik olarak güncellenir
- Güvenlik duvarı kuralları (iptables ve UFW) otomatik olarak güncellenir
- Değişikliklerden önce tam yedekleme oluşturulur
- Hata durumunda otomatik geri alma yapılır
