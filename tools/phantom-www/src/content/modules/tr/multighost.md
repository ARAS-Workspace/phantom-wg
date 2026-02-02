---
id: multighost
label: MultiGhost
mini_desc: Maksimum Gizlilik
title: MultiGhost Senaryosu
subtitle: Görünmezlik Katmanlarının Senfonisi
icon: multighost
order: 4
---

MultiGhost, **Multihop** ve **Ghost** modüllerinin birlikte kullanıldığı gelişmiş bir güvenlik senaryosudur.
Bu senaryoda bağlantınız HTTPS trafiği olarak maskelenir ve trafiğiniz harici bir VPN sunucusu üzerinden
yönlendirilerek çift katman oluşturulur. İki modülün güçlü yönlerini birleştiren bu yaklaşım, maksimum gizlilik
ve sansür direnci gerektiren kullanımlar için ideal çözüm sunar.

**Phantom-WG** sunucusuna yapılan bağlantı Ghost modülü ile gizlenir ve standart HTTPS trafiği gibi
görünür. Sunucuya ulaştıktan sonra trafiğiniz Multihop modülü ile harici bir VPN sunucusuna yönlendirilir.
Bu sayede hem DPI sistemlerini atlarsınız hem de çift VPN katmanı ile yüksek düzeyde anonimlik elde edersiniz.

Her iki modül de bağımsız olarak çalışır ve dilediğiniz zaman devre dışı bırakılabilir.

## Nasıl Çalışır?

MultiGhost ile trafiğiniz şu yolu izler:

- **Normal Akış**: İstemciler → Phantom-WG → İnternet
- **Ghost Akışı**: İstemciler → HTTPS/WebSocket (Port 443) → Phantom-WG → İnternet
- **MultiGhost Akışı**: İstemciler → HTTPS/WebSocket (Port 443) → Phantom-WG → VPN Çıkış → İnternet

Bu katmanlı yapı, hem DPI sistemlerini atlatır hem de trafik analizini zorlaştırır. Bağlantınız HTTPS gibi
görünürken, gerçek hedefiniz ve IP adresiniz çift VPN katmanı arkasında gizli kalır.

## Temel Özellikler

### Maksimum Güvenlik

- **Çift Koruma**: DPI atlatma + çift VPN katmanı birlikte çalışır
- **Sansür Direnci**: HTTPS maskeleme ile ağ engellemelerini aşar
- **Trafik Analizi Zorluğu**: Katmanlı yapı izlemeyi çok zorlaştırır

### Modüler Yapı

- **Bağımsız Modüller**: Ghost ve Multihop ayrı ayrı yönetilebilir
- **Esnek Kullanım**: Her modülü dilediğiniz zaman etkinleştirebilir veya devre dışı bırakabilirsiniz
- **Otomatik Orkestrasyon**: Phantom-WG modüllerin bağımsız ve uyumlu çalışmasını sağlar

## Hızlı Başlangıç

### Ön Gereksinimler

1. Bir domain adı (A kaydı sunucunuza yönlendirilmiş) veya sslip.io
2. Harici VPN sunucusu WireGuard istemci konfigürasyonu

### MultiGhost Aktivasyonu

**Adım 1:** Ghost modunu etkinleştirin:

```bash
phantom-api ghost enable domain="cdn.example.com"
```

**Adım 2:** Harici VPN konfigürasyonunu içe aktarın:

```bash
phantom-api multihop import_vpn_config config_path="/home/user/exit-wg.conf"
```

**Adım 3:** Multihop modunu etkinleştirin:

```bash
phantom-api multihop enable_multihop exit_name="exit-wg"
```

### Durum Kontrolü ve Test

Ghost modülü durumunu kontrol edin:

```bash
phantom-api ghost status
```

Multihop modülü durumunu kontrol edin:

```bash
phantom-api multihop status
```

VPN çıkış bağlantısını test edin:

```bash
phantom-api multihop test_vpn
```

### Modülleri Devre Dışı Bırakma

Multihop modunu devre dışı bırakın:

```bash
phantom-api multihop disable_multihop
```

Ghost modunu devre dışı bırakın:

```bash
phantom-api ghost disable
```
