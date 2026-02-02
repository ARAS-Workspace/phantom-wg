---
id: core
label: Core
mini_desc: Cockpit
title: Core Modülü
subtitle: Phantom-WG Cockpit
icon: rocket
order: 1
---
<!--suppress HtmlUnknownTarget -->
<div class="module-hero-image">
  <img src="/assets/images/ghost-cockpit.jpg" alt="Phantom-WG Cockpit" />
</div>

Core modülü, **Phantom-WG**'ın kalbidir ve temel WireGuard sunucu yönetim operasyonlarını sağlar.
İstemci oluşturma, konfigürasyon üretimi, güvenlik duvarı yönetimi, servis izlemesi ve sağlık takibi gibi temel 
işlevleri tek bir çatı altında toplar.

**Core Modülünün Temel İşlevleri:**

- **WireGuard Interface Yönetimi**: Ana Wireguard arayüzünün yapılandırılması ve kontrolü
- **İstemci Yönetimi**: İstemci oluşturma, silme, listeleme ve konfigürasyon dışa aktarma
- **Kriptografik Anahtar Üretimi**: WireGuard için private, public ve preshared key otomasyonu
- **IP Tahsisi**: Subnet içinden otomatik IP adresi tahsisi ve çakışma kontrolü
- **Güvenlik Duvarı Ayarları**: UFW ve iptables kurallarının yapılandırılması
- **Servis İzleme**: WireGuard servisi sağlık kontrolü
- **Ağ Yönetimi**: Subnet değişikliği ve migration işlemleri

## Nasıl Çalışır?

Core trafiğiniz şu yolu izler:

- **Core Akışı**: İstemciler → Phantom-WG (Port 51820) → İnternet

## Hızlı Başlangıç

### İstemci Yönetimi

Yeni bir istemci oluşturun:

```bash
phantom-api core add_client client_name="ghost"
```

İstemci konfigürasyonunu dışa aktarın:

```bash
phantom-api core export_client client_name="ghost"
```

İstemciyi kaldırın:

```bash
phantom-api core remove_client client_name="ghost"
```

İstemcileri listeleyin (sayfalama ve arama desteği):

```bash
phantom-api core list_clients page=1 per_page=10
```

```bash
phantom-api core list_clients search="ghost"
```

En son eklenen istemcileri görüntüleyin:

```bash
phantom-api core latest_clients count=5
```

### Sunucu ve Servis İşlemleri

Kapsamlı sunucu durumu bilgisini alın:

```bash
phantom-api core server_status
```

WireGuard servis günlüklerini görüntüleyin:

```bash
phantom-api core service_logs lines=50
```

WireGuard servisini yeniden başlatın:

```bash
phantom-api core restart_service
```

Güvenlik duvarı yapılandırma durumunu kontrol edin:

```bash
phantom-api core get_firewall_status
```

### Ağ Yapılandırması

Mevcut subnet bilgilerini görüntüleyin:

```bash
phantom-api core get_subnet_info
```

Yeni subnet'i doğrulayın (değişiklik öncesi):

```bash
phantom-api core validate_subnet_change new_subnet="192.168.100.0/24"
```

Subnet'i değiştirin (onay gerektirir):

```bash
phantom-api core change_subnet new_subnet="192.168.100.0/24" confirm=true
```