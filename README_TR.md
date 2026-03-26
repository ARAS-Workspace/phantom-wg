<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-vertical-master-stellar-silver.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-vertical-master-midnight-phantom.svg">
  <img alt="Phantom-WG" src="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-vertical-master-midnight-phantom.svg" width="600">
</picture>

[![CI](https://img.shields.io/github/actions/workflow/status/ARAS-Workspace/phantom-wg/release-modern.yml?label=CI)](https://github.com/ARAS-Workspace/phantom-wg/actions/workflows/release-modern.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/Docs-www.phantom.tc-black)](https://www.phantom.tc/docs)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/dashboard-screenshot-dark-tr.png">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/dashboard-screenshot-light-tr.png">
  <img alt="Phantom-WG Dashboard" src="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/dashboard-screenshot-light-tr.png">
</picture>

</div>

---

## Phantom-WG Modern Nedir?

***Phantom-WG***, kendi sunucunuzda WireGuard VPN altyapısı kurmanızı ve yönetmenizi sağlayan modüler bir araçtır. Temel VPN yönetiminin ötesinde; sansüre dayanıklı bağlantılar, çok katmanlı şifreleme ve gelişmiş gizlilik senaryoları sunar.

***Phantom-WG Modern***, bu vizyonun container-native implementasyonudur. Tüm bileşenler Docker yapısı içerisinde çalışır ve host sistemden izole edilir:

- **Userspace WireGuard** — Go FFI bridge ile container-scoped TUN device. Kernel modülü gerektirmez, host'un network namespace'ine dokunmaz.
- **nftables netlink FFI** — Rust backend doğrudan kernel ile konuşur. Subprocess çağrısı yoktur, firewall kuralları programatik olarak yönetilir.
- **SQLite State Persistence** — Tüm state SQLite veritabanlarında tutulur. Crash sonrası daemon restart yeterlidir — kernel state DB'den yeniden oluşturulur.
- **Dual-Stack IPv6** — Host'ta IPv6 olmasa bile container içinde IPv6 subnet atanır, tünel içinde trafik taşınabilir.
- **Container İzolasyonu** — `NET_ADMIN` + `NET_RAW` yeterlidir. WireGuard arayüzleri container namespace içerisinde yaşar. `SYS_ADMIN`, `privileged` veya `host` network mode gibi host güvenliğini zayıflatan konfigürasyonlar kullanılmaz.

---

## Topoloji

Üç container, Docker Compose ile yönetilir. Yönetim trafiği TLS + JWT kimlik doğrulamadan geçer, WireGuard trafiği doğrudan daemon'a ulaşır.

```mermaid
flowchart
    A[Internet] -->|"HTTPS :443"| B[nginx]
    B --> C[auth-service]
    C <-->|"UDS"| D[daemon]
    A -->|"WireGuard :51820/udp"| D
```

| Bileşen          | Görev                                                                                                |
|------------------|------------------------------------------------------------------------------------------------------|
| **nginx**        | TLS sonlandırma, React SPA (Statik Derlenmiş Dosyalar), Reverse Proxy Yapılandırması                 |
| **auth-service** | Kapsamlı Kimlik Doğrulama (Authentication) Sistemi, UDS üzerinden daemon'a API proxy                 |
| **daemon**       | Userspace WireGuard (Go FFI), nftables firewall (Rust FFI), İstemci ve Tünel yönetimi, Veritabanları |

---

## Temel Özellikler

### Bridge Mimarisi

Daemon, sistem düzeyindeki işlemleri iki native bridge aracılığıyla gerçekleştirir. Python iş mantığını yönetir, bridge'ler kernel ile doğrudan iletişim kurar.

```mermaid
graph 
    D["Daemon (Python)"] -->|"ctypes FFI"| WG["wireguard-go-bridge (Go)"]
    D -->|"ctypes FFI"| FW["firewall-bridge (Rust)"]
    WG --> TUN["TUN device"]
    FW --> NFT["nftables kernel"]
```

| Bridge                  | Dil  | Sorumluluk                                              |
|-------------------------|------|---------------------------------------------------------|
| **wireguard-go-bridge** | Go   | Userspace WireGuard, TUN device, IPC state persistence  |
| **firewall-bridge**     | Rust | nftables kural grupları, policy routing, preset sistemi |

### Multihop Exit Routing

Trafiğinizi harici bir WireGuard VPN sunucusu üzerinden aktarmak için exit tünelinizi tanımlayabilirsiniz. IPv4 ve IPv6 tünelleri eş zamanlı olarak desteklenir.

```mermaid
flowchart LR
    C[Client] -->|"WireGuard"| M["wg_main"] -->|"forward + masquerade"| E["wg_exit"] --> X[Exit Server]
```

### IPv6 Dual-Stack

IPv6 desteği tüm katmanlarda — firewall kuralları, policy routing, masquerade ve multihop preset'leri `family: 10` (AF_INET6) ile çalışır. Host'ta IPv6 adresi olmadan da container içinden IPv6 tünel trafiği taşınabilir.

### Crash Recovery

Servis başlatıldığında kernel state (nftables kuralları, routing policy'leri) SQLite durum veritabanlarından yeniden oluşturulur. Beklenmeyen kapanma sonrası veri kaybı yaşanmaz.


---

## Kurulum

**Gereksinimler:** Docker Engine 20.10+, Docker Compose v2, bash.

```bash
curl -sSL get.phantom.tc | bash
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-wg-install-dark.gif">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-wg-install-light.gif">
  <img alt="Phantom-WG Kurulum" src="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-wg-install-light.gif">
</picture>

### Yapılandırma

```bash
cd phantom-wg

# İlk kurulum 
./tools/prod.sh setup

# Endpoint yapılandırması
IPV4=$(curl -4 -sSL https://get.phantom.tc/ip)
IPV6=$(curl -6 -sSL https://get.phantom.tc/ip)
sed -i "s/^WIREGUARD_ENDPOINT_V4=.*/WIREGUARD_ENDPOINT_V4=${IPV4}/" .env.daemon
sed -i "s/^WIREGUARD_ENDPOINT_V6=.*/WIREGUARD_ENDPOINT_V6=${IPV6}/" .env.daemon

# Başlatma
./tools/prod.sh up
```

**Erişim:**
- Kontrol Paneli: `https://<sunucu-ip>`
- WireGuard: UDP port `51820`
- Admin şifresi: `cat container-data/secrets/production/.admin_password`

> [!TIP]
> VPN'e bağlıyken kontrol paneline erişmek için nginx container'ın Docker network adresini kullanabilirsiniz:
> ```bash
> docker inspect phantom-nginx --format '{{range .NetworkSettings.Networks}}IPv4: {{.IPAddress}} | IPv6: {{.GlobalIPv6Address}}{{end}}'
> ```
> Tünel içerisinden `https://<IPv4>` veya `https://[<IPv6>]` adresi ile erişilebilir. Dilerseniz `docker-compose.yml` dosyasından `ports: "443:443"` satırını kaldırarak kontrol panelini yalnızca VPN tüneli üzerinden erişilebilir hale getirebilirsiniz.

---

## Ortam Değişkenleri

Yapılandırma, kurulum sırasında şablonlardan oluşturulan env dosyaları ile yönetilir:

| Dosya               | Servis       |
|---------------------|--------------|
| `.env.daemon`       | daemon       |
| `.env.auth-service` | auth-service |

Tüm seçenekler için `.example` dosyalarına bakın.

---

## Yönetim

Yönetim için `./tools/prod.sh` konumunda kullanışlı bir araç bulunur.

| Komut                   | Açıklama                                        |
|-------------------------|-------------------------------------------------|
| `setup`                 | Tam Kurulum                                     |
| `up`                    | Başlat                                          |
| `down`                  | Durdur                                          |
| `restart [service]`     | Yeniden Başlat (Tümü veya Belirli Servis)       |
| `build`                 | İmaj Derle                                      |
| `rebuild`               | Sıfırdan İmaj Derle (no-cache)                  |
| `update`                | Güncelle (git pull + restart)                   |
| `update --skip-compose` | Güncelle (docker-compose.yml hariç tut)         |
| `logs [service]`        | Log Takibi (Tümü veya Belirli Servis)           |
| `status`                | Docker Compose Durumu                           |
| `show-versions`         | Bileşen Versiyonları (Daemon, Vendor Paketleri) |
| `shell [service]`       | Shell (varsayılan: daemon)                      |
| `exec <svc> <cmd>`      | Komut Çalıştır                                  |
| `hard-reset`            | Tüm Veriyi Sil                                  |

### Kurulum

`setup` komutu ilk kurulumda gerekli tüm bileşenleri oluşturur:

1. `.env.daemon` ve `.env.auth-service` dosyalarını `.example` şablonlarından oluşturur.
2. WireGuard sunucu anahtar çifti üretir. (Curve25519 — `wg_private_key`, `wg_public_key`)
3. Auth-Service için bootstrap döngüsü:
   - Ed25519 imzalama anahtar çifti üretir. (`auth_signing_key`, `auth_verify_key`)
   - Auth veritabanını oluşturur. (`auth.db` — kullanıcılar, oturumlar, TOTP, audit log)
   - Admin hesabı oluşturur. (Argon2id hash ile şifrelenen 32 karakterlik rastgele şifre)
4. Nginx için self-signed TLS sertifikası üretir. (`tls_cert`, `tls_key`)

Tüm bu işlemler container içerisinde gerçekleşir — host tarafında ek bir bağımlılık veya araç kurulumu gerekmez.

> [!TIP]
> Gizli anahtarlar `container-data/secrets/production/` altında saklanır. Admin şifresi aynı dizindeki `.admin_password` dosyasına yazılır — giriş yaptıktan sonra güvenle kaldırabilirsiniz.

### Güncelleme

```bash
./tools/prod.sh update                 # git pull + restart
./tools/prod.sh update --skip-compose  # Compose dosyasını koru
```

> [!TIP]
> `docker-compose.yml` üzerinde bir yapılandırma değişikliği yaptıysanız ve güncellemeleri almak istiyorsanız `--skip-compose` kullanın.

Tekrardan container derlemesi gerektirecek paket bağımlılıkları değişikliklerinde (Dockerfile, requirements.txt):

```bash
./tools/prod.sh rebuild
./tools/prod.sh up
```

> [!TIP]
> Dockerfile'lar yalnızca yapının çalışması için gereken sistem bağımlılıklarını sağlar. Kod güncellemeleri `update` komutuyla alınır — `rebuild` yalnızca bu bağımlılıklar değiştiğinde (container yapılarında tekrar derleme gereken güncellemelerde) gereklidir.

---

## Mimari

Detaylı mimari dokümantasyonu için [www.phantom.tc/docs/architecture](https://www.phantom.tc/docs/architecture) adresini ziyaret edin.

| Kaynak          | URL                                                                          |
|-----------------|------------------------------------------------------------------------------|
| Web Sitesi      | [www.phantom.tc](https://www.phantom.tc)                                     |
| Mimari          | [www.phantom.tc/docs/architecture](https://www.phantom.tc/docs/architecture) |
| API Referansı   | [www.phantom.tc/docs/api](https://www.phantom.tc/docs/api)                   |
| Kurulum Rehberi | [SETUP](SETUP)                                                               |

---

## Geliştirme

Aktif geliştirme [`dev/daemon`](https://github.com/ARAS-Workspace/phantom-wg/tree/dev/daemon) branch'inde yapılmaktadır. `main` branch'i yalnızca üretime hazır sürümleri içerir.

---

## Phantom-WG Retro

<img alt="Phantom-WG Retro" src="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/phantom-retro-banner.png">

Gelişmiş gizlilik özellikleri ve yalnızca sistem servisleri ile çalışan bir çözüm arıyorsanız [Phantom-WG Retro](https://github.com/ARAS-Workspace/phantom-wg/tree/retro) sürümü ilginizi çekebilir.

### MultiGhost - Maksimum Gizlilik

Ghost ve Multihop modüllerini birlikte kullanarak en yüksek düzeyde gizlilik ve sansür
direnci elde edin. Bağlantınız HTTPS olarak maskelenir ve çift VPN katmanı üzerinden
yönlendirilir.

![MultiGhost Flow](https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/press-kit/assets/connection-flow-multighost.svg)

**Etkinleştirme:**
```bash
# 1. Ghost Mode'u etkinleştir
phantom-api ghost enable domain="cdn.example.com"

# 2. Harici VPN'i içe aktar
phantom-api multihop import_vpn_config config_path="/path/to/vpn.conf"

# 3. Multihop'u etkinleştir
phantom-api multihop enable_multihop exit_name="vpn-exit"
```

### Keşfet

|    | Kaynak        | Bağlantı                                                                       |
|----|---------------|--------------------------------------------------------------------------------|
| 🌐 | Ana Sayfa     | [www.phantom.tc](https://www.phantom.tc)                                       |
| 📖 | Dokümantasyon | [retro-docs.phantom.tc](https://retro-docs.phantom.tc)                         |
| 💻 | Kaynak Kod    | [GitHub Repository](https://github.com/ARAS-Workspace/phantom-wg/tree/retro)   |
| 🍎 | Mac Client    | [v1.0.0](https://github.com/ARAS-Workspace/phantom-wg/releases/tag/mac-v1.0.0) |

---

## Ticari Marka Bildirimi

WireGuard® Jason A. Donenfeld'in tescilli ticari markasıdır.

Bu proje; Jason A. Donenfeld, ZX2C4 veya Edge Security ile herhangi bir şekilde bağlantılı, ortaklı, yetkili veya onaylı değildir.

---

## Lisans

Telif Hakkı (c) 2025 Rıza Emre ARAS

[AGPL-3.0](LICENSE) lisansı altında lisanslanmıştır. Bağımlılık lisansları için [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) dosyasına bakın.
