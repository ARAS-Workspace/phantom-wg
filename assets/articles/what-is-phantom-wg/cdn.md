# Phantom-WG: Kendi Sunucunuzda Sansüre Dirençli WireGuard VPN Kurun

## Phantom-WG Nedir?

**Kendi Sunucun. Kendi Ağın. Kendi Gizliliğin.**

[Phantom-WG](https://github.com/ARAS-Workspace/phantom-wg), kendi sunucunuzda WireGuard VPN altyapısı kurmanızı ve yönetmenizi sağlayan modüler bir araçtır.
Temel VPN yönetiminin ötesinde; sansüre dayanıklı bağlantılar, çok katmanlı trafik aktarımı ve gelişmiş gizlilik senaryoları sunar.

| Modül  / Kullanım Senaryosu | Açıklama                                                                                                                               |
|-----------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| **Core**                    | İstemci yönetimi, kriptografik anahtar üretimi, otomatik IP tahsisi ve servis kontrolü                                                 |
| **Ghost**                   | [wstunnel](https://github.com/erebe/wstunnel) ile WireGuard trafiğini WSS üzerinden maskeleyerek DPI sistemlerini atlayan hayalet modu |
| **Multihop**                | Harici WireGuard sunucuları üzerinden trafik aktarımı ve çıkış noktası zincirleme                                                      |
| **MultiGhost**              | Ghost ve Multihop'un birleşimi; maksimum gizlilik ve sansür dayanıklılığı                                                              |

> **Not:** Phantom-WG bir konfigürasyon orkestrasyon aracıdır; sunucunuz üzerinde manuel olarak yapacağınız konfigürasyon adımlarını uygulayarak otomatize eder. Herhangi bir web arayüzü veya dışarıya açık saldırı yüzeyi bulundurmaz.

---

## Reza'nın Hikayesi

***Reza***, Tahran'da yaşayan bir yazılım geliştiricisi. İki farklı şirkette uzaktan çalışıyor:

- **NovaBridge** — San Francisco merkezli bir **Fin-Tech** şirketi. Reza burada *Backend Developer* olarak çalışıyor.
- **MapleSoft** — Toronto merkezli bir **SaaS** şirketi. Reza burada *DevOps Engineer* olarak katkıda bulunuyor.

> *Reza, NovaBridge ve MapleSoft anlatımı güçlendirmek için kullanılan kurgusal isimlerdir.*

Her iki şirket de geliştirme ortamlarına erişim için WireGuard konfigürasyonları kullanıyor. CI/CD süreçlerine, dahili servislere ve staging ortamlarına bağlanabilmek için WireGuard tüneli, Reza'nın günlük iş akışında temel bir gereksinim.

Ancak İran, gelişmiş internet filtreleme ve sansür altyapısına sahip. Ulusal ağ geçitlerinde çalışan DPI sistemleri, WireGuard
dahil bilinen VPN protokollerini **imza analizi**, **davranışsal parmak izi** ve **paket boyutu korelasyonu** yöntemleriyle tespit
edip engelliyor.

Bu durum, Reza'nın çalışma ortamlarına erişimini doğrudan etkiliyor.

### Phantom-WG Öncesi: Karmaşık ve Kırılgan Çözümler

Reza, NovaBridge ve MapleSoft ortamlarına bağlanabilmek için çeşitli yöntemler denedi:

- V2Ray / VMess / VLESS
- SSH Tünelleme
- Shadowsocks
- Proxy Zincirleri

Her yöntem ya karmaşık yapılandırma, ya ek araç bağımlılığı, ya da bağlantı kararsızlığı getiriyordu. Her gün NovaBridge veya MapleSoft'a bağlanmadan önce altyapıyı ayakta tutmak başlı başına bir iş haline gelmişti.

---

## Phantom-WG ile Tanışma

Reza, Phantom-WG'yi keşfettiğinde senaryosu kökten değişti.

Reza, çalıştığı şirketlerden ödemesini kripto ve alternatif ödeme kanalları aracılığıyla alıyor ve varlığını yerel bir borsada tutuyor. Bu da ona uluslararası hizmet satın alma imkanı tanıyor.

Türkiye'de bulunan bir sağlayıcıdan **kripto ödeme** yaparak bir VPS kiraladı:

- **Debian 13** kurulu
- **Public IPv4** adresine sahip
- **Türkiye lokasyonu** — İran'a düşük gecikme süresi, Avrupa ve Kuzey Amerika'ya doğrudan bağlantı

> 🎰 **Sağlayıcı mı arıyorsunuz?** Hangi sağlayıcıyı seçeceğinize karar veremediyseniz [Spin & Deploy](https://www.phantom.tc/wheel/index-tr.html) aracını deneyin — gizlilik odaklı, kripto dostu VPS sağlayıcıları arasından rastgele seçim yapın!

Phantom-WG'yi bu sunucuya kurduktan sonra Reza'nın mimarisi şöyle oluştu:

- **Ghost Mode** — wstunnel ile WireGuard trafiğini WSS üzerinden tünelleyerek port 443'ten (HTTPS) geçiriyor. DPI sistemleri bu trafiği standart bir web bağlantısından ayırt edemiyor.
- **Multihop Exit: NovaBridge** — San Francisco'daki şirketin WireGuard konfigürasyonunu exit olarak ekliyor. Geliştirme ortamına tek komutla geçiş.
- **Multihop Exit: MapleSoft** — Toronto'daki şirketin WireGuard konfigürasyonunu exit olarak ekliyor. Ortamlar arası geçiş tek komut.
- **Doğrudan Çıkış** — Multihop devre dışıyken trafik Türkiye üzerinden internete çıkıyor. WireGuard trafiği tespit edilmeden standart bir Türkiye çıkışlı bağlantı.

### Kurulum

```bash
curl -sSL https://install.phantom.tc | bash
```

![Phantom-WG Kurulum](https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/main/assets/articles/what-is-phantom-wg/assets/installation-dark.gif)

Yapılandırma ve kullanım detayları için:

| Kaynak        | Bağlantı                                                                             |
|---------------|--------------------------------------------------------------------------------------|
| GitHub        | [github.com/ARAS-Workspace/phantom-wg](https://github.com/ARAS-Workspace/phantom-wg) |
| Dokümantasyon | [docs.phantom.tc](https://docs.phantom.tc)                                           |
| Web Sitesi    | [www.phantom.tc](https://www.phantom.tc)                                             |

---

## Reza'nın İnternet Trafik Akışı

Tam akış mimarisi:

![Trafik Akışı](https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/main/assets/articles/what-is-phantom-wg/assets/traffic-flow.png)

Reza'nın trafiği Tahran'dan Türkiye'deki Phantom-WG sunucusuna, oradan hedef ortamlara ulaşıyor. Peki günlük çalışmasında bu ortamlar arasında nasıl geçiş yapıyor?

![Günlük Akış](https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/main/assets/articles/what-is-phantom-wg/assets/daily-workflow.png)

---

## Kimler İçin?

- Reza gibi şirket/organizasyon VPN'lerine güvenilir erişim ihtiyacı olan **uzaktan çalışan geliştiriciler**
- Üçüncü taraf VPN sağlayıcılarına bağımlı olmak istemeyen **self-hosted çözüm arayan gizlilik odaklı kullanıcılar**
- VPN trafiğini kendi altyapısı üzerinden yönetmek isteyen, çoklu kullanıcı paneline değil **temel fonksiyonlara odaklı kullanıcılar**
- İletişim güvenliğine ihtiyaç duyan **aktivistler, gazeteciler ve fikir savunucuları**

---

## Lisans

Phantom-WG, [AGPL-3.0](https://github.com/ARAS-Workspace/phantom-wg/blob/main/LICENSE) lisansı altında açık kaynak olarak sunulmaktadır.

*WireGuard, Jason A. Donenfeld'in tescilli ticari markasıdır. Bu proje WireGuard ile bağlantılı, ortaklı veya onaylı değildir.*

---

## Destek

Phantom-WG açık kaynak bir projedir. Projeyi desteklemek isterseniz:

**Bitcoin (BTC):**
```
bc1qnjjrsfdatnc2qtjpkzwpgxpmnj3v4tdduykz57
```

**Monero (XMR):**
```
84KzoZga5r7avaAqrWD4JhXaM6t69v3qe2gyCGNNxAaaJgFizt1NzAQXtYoBk1xJPXEHNi6GKV1SeDZWUX7rxzaAQeYyZwQ
```
