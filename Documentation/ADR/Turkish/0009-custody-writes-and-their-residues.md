# ADR-0009 — Her Satır, Kendi Artığını Onarılabilir Bırakan Sırayla Silinir

## Durum

Kabul Edildi — 2026-08-17

Bu bir **uzantı kaydıdır**: [ADR-0001 Madde 5](0001-architectural-decision-records.md#karar)'in tarif ettiği yolla, kabul edilmiş bir kaydı daraltır. Genişlettiği kayıt ADR-0005'tir, ve ADR-0008'in yanına oturur: o kayıt custody OKUMALARINI eylem anına bağlamıştı, bu kayıt aynı şeyi custody YAZMALARI için yapar. Hiçbiri bir kararı tersine çevirmez; ikisinin de tek öncülü vardır, bir depo hakkındaki karar eylem anında verilir.

- Fix: a removal now empties first the store whose loss its own row can survive ([e889681](https://github.com/ARAS-Workspace/phantom-wg/commit/e889681c4d24259977fa3b139f482e9b6a341626))

- Fix: the fake system list drops a provider whose entry a removal took, and five custody-write steps spend it ([b09ecbf](https://github.com/ARAS-Workspace/phantom-wg/commit/b09ecbf76cd11205ca8cfc91d6957eaed166691c))

- Fix: a teardown that takes the store is now obeyed by everything that would write to it ([065c902](https://github.com/ARAS-Workspace/phantom-wg/commit/065c902455933e02804b925bd81f85c782012d0e))

- Fix: the vault pass's teardown kit moves to its own file, and four new steps spend it ([3c6b90a](https://github.com/ARAS-Workspace/phantom-wg/commit/3c6b90aaf41926714fa1844214a09141a1851d92))

- Fix: a refused vault write now reaches the user as an answer rather than as a timeout ([d1392c0](https://github.com/ARAS-Workspace/phantom-wg/commit/d1392c04c804c3cd79fd4c542f42c5cb3cef9856))

- Fix: a removal the user gave up waiting on stops holding this app's whole self-heal shut ([24ab3d8](https://github.com/ARAS-Workspace/phantom-wg/commit/24ab3d86b044c7427fedd5935844d3c311bf44d4))

- Cila: a failed add's vault rollback reports the payload it left behind ([2c8bd9a](https://github.com/ARAS-Workspace/phantom-wg/commit/2c8bd9a5ea6a13f9a1a9d04a62e4a311fdce8641))

## Bağlam

**Genişletilen kayıt:** [ADR-0005 Sistem Keychain Tünel Kasası](0005-system-keychain-tunnel-vault.md); ilgili bölümler [Karar](0005-system-keychain-tunnel-vault.md#karar) ve [Sınır Durumları](0005-system-keychain-tunnel-vault.md#sınır-durumları).

**Kaynak:** `Phantom-WG-MacOS/Infrastructure/Tunnel/TunnelsManager.swift`, `Phantom-WG-MacOS/Features/TunnelList/TunnelListView.swift`, `Phantom-WG-MacOS/Infrastructure/Tunnel/TunnelErrors.swift`, `Phantom-WG-MacOS/Infrastructure/Initialization/ExtensionGateController.swift`; commit [`e889681`](https://github.com/ARAS-Workspace/phantom-wg/commit/e889681c4d24259977fa3b139f482e9b6a341626), [`065c902`](https://github.com/ARAS-Workspace/phantom-wg/commit/065c902455933e02804b925bd81f85c782012d0e), [`d1392c0`](https://github.com/ARAS-Workspace/phantom-wg/commit/d1392c04c804c3cd79fd4c542f42c5cb3cef9856), [`24ab3d8`](https://github.com/ARAS-Workspace/phantom-wg/commit/24ab3d86b044c7427fedd5935844d3c311bf44d4) ve [`2c8bd9a`](https://github.com/ARAS-Workspace/phantom-wg/commit/2c8bd9a5ea6a13f9a1a9d04a62e4a311fdce8641).

Bu belge ADR-0005'i yeniden anlatmaz. İki maddesinin bağını daraltır ve tablosunun üç satırını yeniden okutup beş satır ekler.

Daraltmanın sebebi tek bir gözlemdir. ADR-0005 silmeye tekdüze bir sıra verdi: önce kasa, sonra Network Extension. O sıra yarım kaldığında geriye kalan şey sırrı olmayan bir sistem girdisidir, ve sahiplik sınırı sırrı olmayan bir girdiyi **başka bir yerel kullanıcının** girdisi sayar. Sonuç, uygulamanın göremediği, silemediği ve `on-demand` kuralı `armed` kaldıysa kendini yeniden bağlayan bir girdidir. Sıranın tersi bu artığı doğurmaz: girdisi olmayan bir payload, reconcile'ın onarmak üzere tanımlandığı şekildir.

Tersi de tekdüze olamaz. `readAll` yalnız çözülebilen payload'ları döndürür, yani **çözülemeyen** bir payload'ı reconcile asla geri basamaz; o payload için girdi tek çapadır. O satırda girdiyi önce almak, sırrı Keychain'de uygulamanın bir daha adlandıramayacağı bir yere kilitler.

### Daraltılan Maddeler

| ADR-0005 | Bugüne kadarki bağ | Bu kararla artık | Kaynak |
| --- | --- | --- | --- |
| **Madde 11** Sıra garantileri | "Silme: önce kasa, sonra Network Extension; kasa silinemezse işlem iptal edilir ve tünel bütün kalır." Sıra tekdüzedir ve satırdan bağımsızdır. | Sıra satır başına, payload'ın o andaki verdict'ine göre seçilir. Çözülebilen payload: **önce girdi**. Çözülemeyen payload: **önce payload**, girdi tek çapa olduğu için. Cevapsız kasa: silme **reddedilir**, iki depoya da dokunulmaz. Ekleme sırası değişmedi. | `entryGoesFirst(for:)`, `remove()` |
| **Madde 8** Reconcile üç görev taşır ve kasada yakınsar | Geçiş, tetikleyicisi geldiğinde koşar; ne koşmasını engelleyecek bir hâl vardır ne de böyle bir hâl adlandırılmıştır. | Geçiş, uygulamanın kendi teardown'ı depoyu aldığında **koşmaz**, ve bu yalnız başlamamış geçiş için değil **koşmakta olan** geçiş için de geçerlidir: `latch`, yazan her noktada yeniden okunur. | `refreshSuspended`, `reload()`, `mintMissingEntries`, `realignDriftedProjections` |

Bir üçüncü bağ ADR-0005'te madde değil tablo satırıdır ve aşağıda yeniden okutulur: bir yazmanın **reddedilmesi** ile **cevapsız kalması** arasındaki fark, bugüne kadar yalnız log seviyesinde vardı ve kullanıcıya tek cümle olarak ulaşıyordu.

### Sınır Durumları Tablosuna İşlenecekler

Aşağıdakiler ADR-0005'in [Sınır Durumları](0005-system-keychain-tunnel-vault.md#sınır-durumları) tablosuna aittir. Tablo değiştirilmez; bu kararla beraber artık şöyle okunur.

**Değişen üç satır:**

| Mevcut satır | Bugüne kadarki hüküm | Bu kararla artık |
| --- | --- | --- |
| Kullanıcı tüneli uygulama içinden sildi | "Önce **TunnelVault** kaydı silinir ve tünel geri gelmez" | Önce **Network Extension** girdisi silinir; kasa kaydı arkasından gider ve tünel yine geri gelmez. Yalnız çözülemeyen payload taşıyan satırda eski sıra korunur. |
| **TunnelVault** kaydı silinemedi çünkü **Sistem Uzantısı** ulaşılamaz durumda | "Silme işlemi iptal edilir ve tünel bütün kalır" | Kasa cevap **vermiyorsa** silme hiç başlamaz ve tünel bütün kalır. Kasa **hayır diyorsa** girdi çoktan gitmiştir; geriye kalan payload'ı reconcile geri kurar ve kullanıcı iki cümleyi ayrı okur. |
| **Sistem Uzantısı** kaldırılıp yeniden kuruldu ve **Network Extension** deposu boşaldı | "Tüm tüneller **TunnelVault** üzerinden geri kurulur" | Tek bir istisna dışında: kaldırmayı **uygulamanın kendisi** yürütüyorsa geri kurma o teardown boyunca koşmaz. Teardown'ın boşalttığı girdileri geri basmak, kaldırmanın hiç görmediği kimlikler üretirdi. |

**Eklenecek satırlar:**

| Durum | Davranış | Değerlendirme |
| --- | --- | --- |
| Silinen satırın payload'ı çözülmüyor | Önce payload silinir, girdi en sona kalır | Girdi, geri kurulamayan bir sırrın tek çapasıdır |
| Silme sırasında kasa cevap vermiyor | Silme reddedilir, iki depoya da dokunulmaz | Yarım durum oluşmaz |
| Girdi silme reddedildi | Satır sistemin kendi okumasına geri verilir ve tünel bütün kalır, ancak `on-demand` kuralı `disarmed` | Bedel isimlendirilmiştir: tünel sağ kalır fakat sessizce `disarmed` |
| Payload silme başarısız, girdi çoktan gitmiş | Bir geçiş zamanlanır ve tünel geri gelir | Girdi-önce sıranın var olma sebebi budur |
| Uygulamanın kendi teardown'ı depoyu almış | Geri kurma, izdüşüm hizalaması ve kuyruğun devri durur | Kaldırmanın görmediği kimlik doğmaz |
| Kullanıcı kaldırma onayını hiç yanıtlamıyor | Bekleyiş kendi bütçesiyle biter, akış sona erer ve `latch` olağan kapıdan iner | Terk edilmiş bir kaldırma, uygulamanın bütün self-heal'ini süreç ömrü boyunca kilitli tutamaz |
| Başarısız bir eklemenin kasa geri alması reddedildi ya da cevapsız kaldı | Geriye kalan payload raporlanır | Onarılabilir bir artık sessiz kalmaz: bir sonraki reconcile, eklemenin başarısız dediği tüneli geri basabilir |

## Karar

Bir custody yazması, bıraktığı artığa göre sıralanır; artık onarılabilir olmalıdır ve onarılamayacaksa hiç doğmamalıdır. Somut olarak:

1. **Sıra satır başına seçilir.** İlk yıkıcı adımdan önce payload id ile okunur ve verdict sırayı belirler: çözülebilir payload girdi-önce silinir, çözülemeyen payload-önce, cevapsız kasa silmeyi reddettirir. İlke tekdüzelik değil şudur: **her satır, kendi artığını onarılabilir bırakan sırayla silinir.** Okuma sabırlıdır çünkü yerini aldığı silme de sabırlıydı; geçici bir karanlık an bir reddetmeye dönüşmez.

2. **Girdi-önce sıranın zorunlu bir eşliği vardır.** Reconcile'ın aday filtresi, silinmekte olan kimlikleri elemek zorundadır. Bu bar olmadan sıra sınıfı kapatmaz, **üretir**: girdi iner, sistem bir değişiklik yayar, geçiş payload'ı `orphan` görür ve girdiyi geri basar, tam o sırada payload silmesi iner. Bar, kararın ayrılmaz parçasıdır.

3. **Uygulamanın kendi teardown'ı depoyu alır.** Kaldırma akışı, sınıflandırmadan önce bir `latch` kaldırır ve akışın her çıkışında indirir. `latch`, yalnız başlamamış bir geçişi değil koşmakta olan geçişi de barlar: yazan her nokta onu yeniden okur. Yalnız daraltan yollar bilerek barsızdır, çünkü teardown'ın kaçıracağı hiçbir şey üretmezler. `latch`'i indiren iki kapı vardır ve ikisi de adlandırılmıştır, fakat eşit değildirler. Birincisi akışın kendisidir ve olağan kapıdır. İkincisi, hiç dönmeyen bir akış için kurtarmadır ve artık **yedek**tir: yazıldığı durum, yani kullanıcının hiç yanıtlamadığı bir sistem onayında asılı kalan akış, bekleyişin kendi bütçesiyle sınırlandığı için artık birinci kapıdan çıkar. İkinciye kalan, istek başına bir bütçenin ulaşamayacağı şeydir: `latch`'i kaldıran görevin sistem tarafından başka bir yolla sonlandırılması, yani koşacak hiçbir çıkışın kalmaması. **İkisi birbirinin yerini tutmaz** ve bu yanlış okunmamalıdır: bir onay penceresinde park etmiş teardown, kapıyı hazır durumda kıpırdamadan bıraktığı için ikinci kapının tetiği hiç ateşlenmez. Biri diğerini kapsıyor sanılıp silinmemelidir.

4. **Bir ret ile bir sessizlik kullanıcıya aynı cümleyle ulaşmaz.** Kasa hayır dediğinde durum tam olarak eskisi gibidir ve yarım yazılan hiçbir şey yoktur; kasa cevap vermediğinde yazma inmiş bile olabilir, yalnız cevabı kaybolmuştur. İkisi karşıt bilgiler taşır ve tek bir cümleye çökmeleri, kullanıcıya yanlış olanı okutur.

Hiçbiri sırların nerede durduğuna, sahiplik sınırına ya da el sıkışması koşuluna dokunmaz. Yalnızca bir yazmanın hangi sırayla, hangi barlarla ve hangi cümleyle bittiğini değiştirirler.

## Sonuçlar

- Yarım kalan bir silmenin artığı artık onarılabilir tarafa düşer. Gizli girdi sınıfının bu yoldan doğan üreticisi kapanmıştır.
- Çözülemeyen payload taşıyan satır, isimli bir muaf olarak eski sırayı korur. Kural tekdüze olmadığı için okunması da tekdüze değildir, ve muafın gerekçesi kodun yanında yazılıdır.
- Girdi silmesi reddedildiğinde tünel sağ kalır fakat `on-demand` kuralı `disarmed` olur, çünkü `remove()` kuralı girdiye dokunmadan önce indirir. Bu bilinçli bir bedeldir ve kullanıcıya bugün söylenmez; söylenmesi ayrı bir kalemdir.
- Kaldırma sürerken hiçbir self-heal koşmaz. Bunun bedeli, kaldırma akışı sırasında listenin kendini onarmamasıdır; kazancı, kaldırmanın "temiz" derken Sistem Ayarları'nda girdi bırakmamasıdır.
- Kullanıcı iki farklı hata cümlesi görebilir. İkisi de aynı işlemin başarısızlığını anlatır fakat farklı şeyler önerir, ve bu ayrım kasıtlıdır.
- Terk edilmiş bir kaldırma artık kendi bütçesiyle biter, yani `latch` süreç ömrü boyunca yukarıda kalmaz. Bu, kaydın 3. maddesindeki iki kapıdan ikincisini gereksiz kılmaz, yalnız onu olağan yoldan yedeğe taşır.
- Bu ilke silmeye özgü değildir: başarısız bir eklemenin kasa geri alması da bir custody yazmasıdır ve onun artığı da artık raporlanır. Geri alma reddedilir ya da cevapsız kalırsa geriye girdisiz bir payload kalır, ve bunu bir sonraki reconcile eklemenin başarısız dediği tünel olarak geri basabilir. Artık onarılabilir olduğu için doğması yasak değildir; sessiz kalması yasaktır.
- Aynı ayrım log yüzeyine de indi: `remove()` ve kaldırma süpürmesi, reddedilmiş bir disarm kaydından sonra kuralın "armed kaldığını" iddia ediyordu. Hiçbir ret bunu kanıtlamaz, ve iki satır artık paylaşılan yardımcının söylediğini söyler.
- Silme yolu bir kasa okuması pahalılaşmıştır. Olağan durumda bu tek bir gidiş dönüşüdür; silme yolu önceden de en az bir okuma harcıyordu.

## İlgili Kayıtlar

- [ADR-0005](0005-system-keychain-tunnel-vault.md) madde 8 ve 11: yukarıdaki tabloda daraltıldı.
- [ADR-0005](0005-system-keychain-tunnel-vault.md) madde 6: sahiplik sınırı. Değişmedi, ve bu kaydın taşıyıcısıdır: girdi-önce sıranın tercih edilme sebebi, sırrı olmayan bir girdinin o sınır tarafından başka kullanıcının sayılmasıdır.
- [ADR-0008](0008-custody-decisions-at-the-moment-of-acting.md): custody okumalarını eylem anına bağlayan kardeş kayıt. Bu kaydın 2. maddesindeki bar, o kaydın uçuş işaretiyle aynı filtrede oturur.
- [ADR-0001](0001-architectural-decision-records.md) madde 5: bu kaydın var olma biçimi; kabul edilmiş bir ADR düzeltme için oyulmaz, daraltan yeni bir kayıt açılır.
