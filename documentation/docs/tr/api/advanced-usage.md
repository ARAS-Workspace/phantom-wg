## Gelişmiş Kullanım

API'nin JSON çıktısı, `jq` gibi araçlarla kolayca ayrıştırılarak izleme betikleri,
otomasyon iş akışları ve özel panolar oluşturulabilir.

### JSON Yanıtlarını Ayrıştır

```bash
# İstemci sayısını al
phantom-api core list_clients | jq '.data.total'

# Aktif bağlantıları al
phantom-api core server_status | jq '.data.clients.active_connections'

# Ghost Mode'un aktif olup olmadığını kontrol et
phantom-api ghost status | jq '.data.enabled'
```

### Sağlık İzleme

Aşağıdaki betik, tüm kritik bileşenlerin durumunu kontrol ederek sorun algılandığında
uyarı verir. Bir cron görevi olarak çalıştırılarak sürekli izleme sağlanabilir.

```bash
#!/bin/bash
# Sistem sağlığını izle

# WireGuard servisini kontrol et
if ! phantom-api core server_status | jq -e '.data.service.running' > /dev/null; then
    echo "UYARI: WireGuard servisi çalışmıyor!"
fi

# DNS sağlığını kontrol et
if ! phantom-api dns test_dns_servers | jq -e '.data.all_passed' > /dev/null; then
    echo "UYARI: DNS sunucuları yanıt vermiyor!"
fi

# Multihop etkinse kontrol et
if phantom-api multihop status | jq -e '.data.enabled' > /dev/null; then
    if ! phantom-api multihop test_vpn | jq -e '.data.all_tests_passed' > /dev/null; then
        echo "UYARI: Multihop VPN testi başarısız!"
    fi
fi
```

---

## Sürüm Bilgisi

Bu dokümantasyon Phantom-WG API **core-v1** sürümünü kapsar.

> **Not:** Dokümantasyondaki CLI önizleme kayıtlarında görünen sunucu bilgileri, IP
> adresleri ve istemci verileri, yalnızca bu içeriklerin oluşturulması amacıyla geçici
> olarak kurulan ve sonrasında kalıcı olarak kapatılan bir test sunucusunda üretilmiştir.
