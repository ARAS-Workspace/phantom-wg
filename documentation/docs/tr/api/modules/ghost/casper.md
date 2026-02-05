**Casper Aracı ile İstemci Yapılandırması Dışa Aktarma:**

Ghost Mode aktifken istemcilerin bağlantı kurabilmesi için hem wstunnel istemcisini
çalıştırmaları hem de özel bir WireGuard yapılandırması kullanmaları gerekir. `phantom-casper`
aracı bu iki bileşeni bir arada, adım adım talimatlarla sunan bağımsız bir yardımcı araçtır:

```bash
# Ghost Mode için istemci yapılandırmasını dışa aktar
phantom-casper [kullanıcıadı]

# Gerçek bir istemci ile örnek
phantom-casper demo-casper
```

**Örnek Çıktı:**
```
================================================================================
PHANTOM-WG - GHOST MODE İSTEMCİ YAPILANDIRMASI
================================================================================

İstemci: demo-casper
Sunucu: 157-230-114-231.sslip.io
Oluşturulma: 2025-09-09 01:41:50

--------------------------------------------------------------------------------
ADIM 1: wstunnel istemcisini başlat
--------------------------------------------------------------------------------

Bu komutu ayrı bir terminalde çalıştırın (çalışır durumda tutun):

    wstunnel client --http-upgrade-path-prefix "Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac" \
        -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://157-230-114-231.sslip.io:443

--------------------------------------------------------------------------------
ADIM 2: WireGuard Yapılandırması
--------------------------------------------------------------------------------

Aşağıdaki yapılandırmayı bir dosyaya kaydedin (örn: phantom-ghost.conf):

[Interface]
PrivateKey = SI5AXDC9e5ERFwUKBr391MAwSeHIebG4l7R+N7xssVg=
Address = 10.8.0.2/24
DNS = 8.8.8.8, 8.8.4.4
MTU = 1420

[Peer]
PublicKey = Y/V6vf2w+AWpqz3h6DYAOHuW3ZJ3vZ0jSc8D0edVthw=
PresharedKey = giiS7QdcN708ovmXPfrikpC+TI4lqQcXTJ5JFfqL06k=
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/1, 128.0.0.0/4, 144.0.0.0/5, 152.0.0.0/6, 156.0.0.0/8,
            157.0.0.0/9, 157.128.0.0/10, 157.192.0.0/11, 157.224.0.0/14,
            157.228.0.0/15, 157.230.0.0/18, 157.230.64.0/19, 157.230.96.0/20,
            157.230.112.0/23, 157.230.114.0/25, 157.230.114.128/26,
            157.230.114.192/27, 157.230.114.224/30, 157.230.114.228/31,
            157.230.114.230/32, 157.230.114.232/29, 157.230.114.240/28,
            157.230.115.0/24, 157.230.116.0/22, 157.230.120.0/21,
            157.230.128.0/17, 157.231.0.0/16, 157.232.0.0/13, 157.240.0.0/12,
            158.0.0.0/7, 160.0.0.0/3, 192.0.0.0/2, 10.8.0.0/24
PersistentKeepalive = 25

--------------------------------------------------------------------------------
ADIM 3: Bağlan
--------------------------------------------------------------------------------

Linux/macOS:
    sudo wg-quick up /path/to/phantom-ghost.conf

Windows:
    WireGuard istemcisinde yapılandırma dosyasını içe aktar

Bağlantıyı kesmek için:
    sudo wg-quick down /path/to/phantom-ghost.conf

================================================================================
NOT: Bağlı iken wstunnel komutunu çalışır durumda tutun!
================================================================================
```

**Casper Aracının Temel Özellikleri:**

- Sunucu IP'sini hariç tutmak için otomatik split routing (AllowedIPs) hesaplar --
  bu sayede wstunnel bağlantısının kendisi VPN tünelinden geçmez ve döngüsel
  yönlendirme önlenir
- Doğru secret path ile wstunnel istemci komutunu üretir
- Platform bazında (Linux/macOS) adım adım bağlantı talimatları sağlar
- Ghost Mode'da yapılandırılan herhangi bir alan adı ile çalışır (sslip.io/nip.io dahil)
- Endpoint 127.0.0.1:51820 olarak ayarlanır; trafik yerel wstunnel istemcisi üzerinden
  uzak sunucuya iletilir
