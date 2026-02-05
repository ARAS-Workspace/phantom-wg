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

```bash
# Otomatik isim algılama ile içe aktar
phantom-api multihop import_vpn_config config_path="/home/user/xeovo-uk.conf"

# Özel isim ile içe aktar
phantom-api multihop import_vpn_config config_path="/home/user/vpn.conf" custom_name="xeovo-uk"
```

**Parametreler:**
- `config_path` (zorunlu): WireGuard yapılandırma dosyasının yolu
- `custom_name` (opsiyonel): Yapılandırma için özel isim
