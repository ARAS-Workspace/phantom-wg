---
id: ghost
label: Ghost
mini_desc: Hayalet Modu
title: Ghost Modülü
subtitle: Sansür Dirençli Tünel Mimarisi
icon: ghost
order: 3
---

Ghost modülü, temel anlamda WireGuard trafiğinizi standart **HTTPS web trafiği** olarak gizleyerek DPI
sistemlerini ve firewall engellemelerini atlatmanıza yardımcı olur. Bunu yaparken arka planda
[**wstunnel**](https://github.com/erebe/wstunnel) servisi kullanılır.
**Phantom-WG**, wstunnel servisinin yapılandırılmasını, SSL sertifikalarının yönetimini, firewall
kurallarını ve systemd servislerini otomatik olarak halleder. Sadece A kaydını sunucunuza yönlendirdiğiniz
bir domain verin, geri kalan tüm teknik süreci sistem sizin için yönetsin.

Hem kendi alan adınızı hem de sslip.io veya nip.io gibi ücretsiz servisleri kullanabilirsiniz.

## Nasıl Çalışır?

Ghost ile trafiğiniz şu yolu izler:

- **Normal Akış**: İstemciler → WireGuard (Port 51820) → İnternet
- **Ghost Akışı**: İstemciler → HTTPS/WebSocket (Port 443) → WireGuard → İnternet

Bu dönüşüm sayesinde, sansür sistemleri VPN trafiği görmez, sadece meşru HTTPS bağlantısı görür.

## Temel Özellikler

### Sansür Direnci

- **DPI Atlama**: WireGuard trafiği WebSocket ile sarmalanarak HTTPS olarak görünür
- **Port 443 Kullanımı**: Engellenemeyen standart HTTPS portu üzerinden operasyon

### Kurulum Kolaylığı

- **Otomatik Yapılandırma**: Firewall kuralları, wstunnel yapılandırması, Wireguard yapılandırması tamamen
  otomatik
- **Kolay İstemci Kurulumu**: phantom-casper ile adım adım talimatlarla beraber kullanıma hazır istemci
  konfigürasyonları

## Hızlı Başlangıç

### Domain Hazırlığı

Domain'inizin A kaydını sunucu IP'nize yönlendirin veya sslip.io kullanın.

### Ghost Modül Yönetimi

Ghost modunu etkinleştirin (domain ile):

```bash
phantom-api ghost enable domain="cdn.example.com"
```

Ghost modunu etkinleştirin (sslip.io ile):

```bash
phantom-api ghost enable domain="157-230-114-231.sslip.io"
```

Ghost modülü bağlantı durumunu kontrol edin:

```bash
phantom-api ghost status
```

Ghost modunu devre dışı bırakın:

```bash
phantom-api ghost disable
```

### İstemci Konfigürasyonu

Ghost istemci yapılandırmasını phantom-casper ile alın:

```bash
phantom-casper [kullanici-adi]
```