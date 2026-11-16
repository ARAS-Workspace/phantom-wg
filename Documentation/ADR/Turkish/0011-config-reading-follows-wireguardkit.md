# ADR-0011 — Yapılandırma Okuması WireGuardKit'in Kurallarını İzler, Sızıntı Korumaları Kalır

## Durum

Önerildi — 2026-11-16

Bu kayıt yeni bir karar kaydeder. Kabul edilmiş bir kaydı daraltmaz.

- Feature: .conf reading follows WireGuardKit's rules, leak guards kept ([8e2d4d4](https://github.com/ARAS-Workspace/phantom-wg/commit/8e2d4d4594d2566cc293d099a3cd3b3fe2f7f750))

- Feature: DNS search domains and ListenPort reach the tunnel ([5b3bbaa](https://github.com/ARAS-Workspace/phantom-wg/commit/5b3bbaaef4cfb36527ecbb0ae0d16bac4d2f2d56))

## Bağlam

**Kaynak:** `Phantom-WG-MacOS/Domain/Parsing/ConfParser.swift`, `Phantom-WG-MacOS/Domain/Configuration/ConfigTypes.swift`, `Phantom-WG-MacOS/Models/Drafts/TunnelDrafts.swift`, `Phantom-WG-MacOS/Domain/Configuration/TunnelConfig.swift`, `PhantomTunnel/Features/WireGuardTunnel/WireGuardConfigBuilder.swift`. Commit [`8e2d4d4`](https://github.com/ARAS-Workspace/phantom-wg/commit/8e2d4d4594d2566cc293d099a3cd3b3fe2f7f750) ve [`5b3bbaa`](https://github.com/ARAS-Workspace/phantom-wg/commit/5b3bbaaef4cfb36527ecbb0ae0d16bac4d2f2d56).

Uygulama `.conf` metnini kendi ayrıştırıcısıyla okur. İçe aktarma ekranı, düzenleme ekranı ve dişli menüsünden toplu içe aktarma aynı yoldan geçer. Metin önce `ConfParser` ile bölümlere ayrılır, sonra `TunnelDrafts` içindeki `validate()` ile doğrulanır.

WireGuard'ın resmî uygulaması aynı metni WireGuardKit'in `wg-quick` ayrıştırıcısıyla okur. Bu uygulamanın tünel uzantısı da WireGuardKit'i kullanır. İki okuma birbirinden ayrışıyordu. Gerçek bir yapılandırma dosyasında `Address` değeri önek (prefix) taşımıyordu. WireGuard uygulaması dosyayı kabul etti ve tünel çalıştı. Bu uygulama aynı dosyayı reddetti.

Ayrışma tek bir alanla sınırlı değildi. Önceki okuma bazı değerleri WireGuardKit'ten katı, bazı satırları ise ondan gevşek okuyordu. Varsayılanlar da WireGuardKit'inkilerden farklıydı.

### Ayrışmalar

| Konu                                   | Önceki okuma                   | WireGuardKit                     | Bu kararla                                                                  |
|----------------------------------------|--------------------------------|----------------------------------|-----------------------------------------------------------------------------|
| Öneksiz adres                          | Reddedilir                     | IPv4 `/32`, IPv6 `/128` okunur   | WireGuardKit gibi                                                           |
| Sınırı aşan önek                       | Reddedilir                     | Sınıra kırpılır                  | WireGuardKit gibi                                                           |
| `MTU` yok                              | `1420`, kabul aralığı 576–9200 | Değer yok, otomatik              | `0` otomatik demektir, kabul aralığı 0–65535                                |
| `PersistentKeepalive` yok              | `25`                           | Değer yok, kapalı                | `0` kapalı demektir                                                         |
| IP olmayan `DNS` girdisi               | Reddedilir                     | Arama alanı (search domain) olur | WireGuardKit gibi                                                           |
| `ListenPort`                           | Okunmaz                        | Okunur                           | Okunur, kabul aralığı 0–65535                                               |
| Satır içi `#` yorumu                   | Değerin parçası kalır          | Atılır                           | `[Interface]` ve `[Peer]` bölümlerinde atılır, `[Wstunnel]` bölümünde kalır |
| Bilinmeyen anahtar                     | Sessizce yok sayılır           | Hata                             | Hata                                                                        |
| Bilinmeyen bölüm                       | Sessizce yok sayılır           | Hata                             | Hata                                                                        |
| `=` taşımayan satır                    | Sessizce atlanır               | Hata                             | Hata                                                                        |
| Tekrar eden tekil anahtar              | Son değer geçerli olur         | Hata                             | Hata                                                                        |
| `Address`, `AllowedIPs`, `DNS` tekrarı | Birleştirilir                  | Birleştirilir                    | Değişmedi                                                                   |

`[Wstunnel]` bölümü bu uygulamaya aittir ve WireGuardKit'te yoktur. Bu bölümün değerleri `#` karakteri taşıyabildiği için satır içi yorum orada atılmaz.

### Bilinçli Sapmalar

WireGuardKit dört durumu kabul eder. Bu uygulama dördünü de reddetmeye devam eder.

| Konu                               | WireGuardKit | Bu uygulama                                                               | Neden                                                                                                                                           |
|------------------------------------|--------------|---------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| Boş `Address`                      | Kabul eder   | `validate()` reddeder, uzantıda `WireGuardConfigBuilder` yeniden reddeder | Adressiz bir arayüz trafik taşımaz. Başarılı görünen ama çalışmayan bir tünel yerine ret verilir.                                               |
| Boş `AllowedIPs`                   | Kabul eder   | `validate()` reddeder, uzantıda `WireGuardConfigBuilder` yeniden reddeder | Rotası olmayan bir eşle tünel `.active` görünür ama trafik tünelin dışından akar. Bu bir sızıntıdır.                                            |
| `Endpoint` taşımayan standalone eş | Kabul eder   | Ayrıştırıcı reddeder, uzantıda `WireGuardConfigBuilder` yeniden reddeder  | Bu istemci bağlantıyı kendisi başlatır. Uç noktası olmayan bir eşe el sıkışma gönderilemez. Ghost modda uç nokta `[Wstunnel]` bölümünden gelir. |
| Birden çok `[Peer]`                | Kabul eder   | İkinci `[Peer]` bölümü reddedilir                                         | Tünel modeli ve kasa yükü (payload) tek eş taşır. Bu model [ADR-0005](0005-system-keychain-tunnel-vault.md)'in bağlamında tarif edilir.         |

### Ölçülenler

- **Gerçek dosya (2026-11-15):** öneksiz `Address` taşıyan ve önceden reddedilen yapılandırma artık olduğu gibi içe aktarılıyor.
- **Arama alanı (2026-11-15):** içe aktarılan arama alanı, `scutil --dns` çıktısında tünel uzantısının `utun` çözücüsünde görünüyor.
- **Harness, ConfigContract (2026-11-16):** arama alanı ve `ListenPort`, `validate()`, kasa yükünün kodlanıp çözülmesi ve yazılan `.conf` metni boyunca korunuyor. İki anahtar eklenmeden önce yazılmış bir yük, arama alanı ve dinleme portu olmadan çözülüyor. Yalnız virgülden oluşan bir `DNS` değeri, WireGuard'daki gibi DNS sunucusu olmadan okunuyor.
- **Harness, sızıntı koruması (2026-11-16):** boş `AllowedIPs` ile kurulan tünel `.active` olmadı. Uzantı yapılandırmayı `savedProtocolConfigurationIsInvalid` ile reddetti.

## Karar

Yapılandırma okuması WireGuardKit'in kurallarını izler. Sızıntıya ya da çalışmayan bir tünele yol açan dört durumda bu uygulama reddetmeye devam eder. Somut olarak:

1. **Okuma kuralları WireGuardKit'inkilerdir.** "Ayrışmalar" tablosunun son sütunu içe aktarma ekranında, düzenleme ekranında ve toplu içe aktarmada geçerlidir. Hata, anahtarı ya da satırı adıyla söyler.

2. **Eksik değerler WireGuardKit'in boş değerleridir.** `MTU` yoksa `0` yazılır ve otomatik demektir. `PersistentKeepalive` yoksa `0` yazılır ve kapalı demektir. Uzantı `0` değerini WireGuardKit'e vermez, WireGuardKit de değeri olmayan alanı otomatik ya da kapalı okur. Ayrıntı ekranı bu iki durumu "Otomatik" ve "Kapalı" olarak gösterir.

3. **Arama alanları ve dinleme portu tünele ulaşır.** Kasa yükünün `interface` bölümü `dns_search` ve `listen_port` anahtarlarını taşır. Bu iki anahtar olmadan yazılmış bir yük hatasız çözülür. Uzantı ikisini WireGuardKit'e verir. Kopyalanan ve dışa aktarılan `.conf` metni ikisini geri yazar. Ayrıntı ekranı ikisini yalnız değer varken gösterir.

4. **Sızıntı korumaları iki katmanda kalır.** "Bilinçli Sapmalar" tablosundaki dört durum uygulamada `validate()` ya da ayrıştırıcı tarafından reddedilir. Boş `Address`, boş `AllowedIPs` ve `Endpoint` taşımayan standalone eş uzantıda `WireGuardConfigBuilder` tarafından bir kez daha reddedilir. Kasaya uygulamanın doğrulamasından geçmeden yazılmış bir yük de tünel olarak kurulmaz.

## Sonuçlar

- WireGuard uygulamasının kabul ettiği yapılandırmalar burada da kabul edilir. Ayrılan durumlar "Bilinçli Sapmalar" tablosunda sayılıdır.
- Okuma bazı noktalarda sıkılaştı. Önceden sessizce yok sayılan bilinmeyen anahtar, bilinmeyen bölüm ve anlaşılmayan satır artık hata verir. `PostUp` ya da `Table` gibi `wg-quick` anahtarları taşıyan bir dosya artık reddedilir. WireGuard uygulaması da bu anahtarları reddeder.
- `MTU` ve `PersistentKeepalive` taşımayan yapılandırmalar artık `1420` ve `25` değerleriyle değil, otomatik MTU ve kapalı keepalive ile kurulur. Bu iki değeri isteyen kullanıcı onları dosyada açıkça yazar.
- Kasa yükü iki sırsız anahtar kazandı. Sır taşıyan alanlar değişmedi.
- Uzantıda da derlenen `ConfigTypes.swift` öneksiz adresi ve sınırı aşan öneki WireGuardKit gibi okur. Kasa kayıtları her zaman önekli yazıldığı için uzantının okuduğu değerler bu yüzden değişmez.
- Kurulu 2.1.x uzantıları arama alanını ve dinleme portunu tünele taşımaz. Bu iki alan yeni sürüm kurulduğunda etkili olur.

## İlgili Kayıtlar

- [ADR-0005](0005-system-keychain-tunnel-vault.md): kasa yükünün modeli. Model iki sırsız alan kazandı. Kaydın kararı değişmedi.
- [ADR-0001](0001-architectural-decision-records.md) madde 6: bu kaydın kapsamı. Kayıt yalnız okuma kurallarına ilişkin kararı tutar. Ayrıştırıcının bütün yapısını tarif etmez.
