---
id: multihop
label: Multihop
mini_desc: Çift VPN
title: Multihop Modülü
subtitle: Katmanlı Çoklu VPN Mimarisi
icon: server
order: 2
---

Multihop modülü, trafiğinizi harici bir WireGuard sunucusu üzerinden yönlendirerek **çift VPN katmanı** oluşturur.
Bu harici sunucu, ister ticari bir VPN sağlayıcısı ister kendi kurduğunuz başka bir sunucu olabilir.
**Phantom-WG**, verdiğiniz WireGuard istemci konfigürasyonunu kullanarak harici sunucuya bağlanır ve kendi
üzerindeki tüm trafiği bu bağlantı üzerinden yönlendirir. Sadece istemci konfigürasyonunu içe aktarın, geri kalan
tüm süreç ve yönlendirme sistem tarafından otomatik olarak yönetilir.

Bu gelişmiş mimari trafiğinizin analiz edilmesini zorlaştırarak yüksek düzeyde anonimlik ve güvenlik katmanları
sunar. **Phantom-WG**, bu süreci tamamen otomatik olarak yönetir ve herhangi bir üçüncü tarafa veya hizmete
bağlı kalmadan size tam esneklik ve kontrol olanağı sağlar.

Sistemin esnekliği sayesinde, birden fazla **Phantom-WG** sunucunuzu da zincirleyebilir ve trafiğinizi bu
sunucular üzerinden sırayla aktarabilirsiniz. Kurduğunuz her **Phantom-WG** sunucusundan aldığınız WireGuard
istemci konfigürasyonunu, bir önceki sunucunun Multihop modülünde çıkış sunucusu konfigürasyonu olarak içe aktararak,
katmanlı bir zincir yapısı oluşturabilirsiniz. Her sunucu, kendinden sonraki sunucuya istemci olarak bağlanır ve
trafiği o sunucu üzerinden yönlendirir. Bu yaklaşım sayesinde tamamen kendi kontrol ettiğiniz çoklu sunucu zinciri
kurabilir, ticari VPN sağlayıcılarına bağımlı kalmadan kullanım senaryolarınıza uygun güvenilir bir altyapı
oluşturabilirsiniz.

## Nasıl Çalışır?

Multihop ile trafiğiniz şu yolu izler:

- **Normal Akış**: İstemciler → Phantom-WG → İnternet
- **Multihop Akışı**: İstemciler → Phantom-WG → VPN Çıkış → İnternet

Bu katmanlı yaklaşım, **çift VPN katmanı** ile gerçek IP adresinizi gizler ve trafiğinizin izini sürmeyi zorlaştırır.

## Temel Özellikler

### Güvenlik Avantajları

- **IP Gizleme**: Gerçek IP adresiniz çift katman arkasında
- **Katmanlı Yönlendirme**: Trafik analizi zorlaşır
- **Çıkış Noktası Esnekliği**: Kendi sunucunuz veya istediğiniz VPN sağlayıcısı - tercih sizin
- **Özel VPN Ağı**: Multihop aktifken eşler arasında güvenli, kesintisiz bağlantı

## Hızlı Başlangıç

### VPN Konfigürasyon Yönetimi

WireGuard istemci konfigürasyonunu içe aktarın:

```bash
phantom-api multihop import_vpn_config config_path="/home/user/exit-wg.conf"
```

Mevcut çıkış noktalarını listeleyin:

```bash
phantom-api multihop list_exits
```

Çıkış noktası konfigürasyonunu kaldırın:

```bash
phantom-api multihop remove_vpn_config exit_name="exit-wg"
```

### Multihop Aktivasyonu

Multihop modunu etkinleştirin:

```bash
phantom-api multihop enable_multihop exit_name="exit-wg"
```

Multihop bağlantı durumunu kontrol edin:

```bash
phantom-api multihop status
```

VPN çıkış bağlantısını test edin:

```bash
phantom-api multihop test_vpn
```

Multihop modunu devre dışı bırakın:

```bash
phantom-api multihop disable_multihop
```

### İleri Seviye İşlemler

Multihop oturum günlüklerini görüntüleyin:

```bash
phantom-api multihop get_session_log lines=50
```

Multihop durumunu tamamen sıfırlayın:

```bash
phantom-api multihop reset_state
```