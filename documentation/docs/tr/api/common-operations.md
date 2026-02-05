## Yaygın İşlemler

Aşağıdaki örnekler, API'nin kabuk betikleri ve standart Unix araçlarıyla nasıl
birleştirilerek günlük yönetim görevlerinin otomatikleştirilebileceğini gösterir.

### Birden Fazla İstemci Oluştur

```bash
# 100 test istemcisi oluştur
for i in {1..100}; do
    phantom-api core add_client client_name="test-client-$i"
done
```

### Tüm İstemci Yapılandırmalarını Dışa Aktar

```bash
# Tüm istemcileri yapılandırma dosyası olarak dışa aktar
phantom-api core list_clients per_page=1000 | jq -r '.data.clients[].name' | while read client; do
    phantom-api core export_client client_name="$client"
done
```

### Tam Sansür Dayanıklılığını Etkinleştir

Ghost Mode ve Multihop birlikte kullanılarak en yüksek düzeyde sansür dayanıklılığı
sağlanır. Bu senaryoda trafik önce HTTPS tünelinden geçer, ardından harici bir VPN
çıkışı üzerinden internete ulaşır.

```bash
# 1. Ghost Mode'u etkinleştir
phantom-api ghost enable domain="cdn.example.com"

# 2. Harici VPN'i içe aktar
phantom-api multihop import_vpn_config config_path="/path/to/vpn-exit.conf"

# 3. Multihop'u etkinleştir
phantom-api multihop enable_multihop exit_name="vpn-exit"
```

### Tam Sistem Kontrolü

```bash
# Tüm bileşenleri kontrol et
phantom-api core server_status
phantom-api dns status
phantom-api ghost status
phantom-api multihop status
```
