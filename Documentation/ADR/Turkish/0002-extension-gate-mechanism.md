# ADR-0002 — Extension Gate Mekanizması

## Durum

Kabul Edildi — 2026-05-09

Bu ADR'ın aşağıdaki bölümlerinin yerini ADR-0006 (***Ölçülen Aktivasyon***) aldı: madde 1'in kapanış paragrafı (durum değişikliklerinin yalnızca kullanıcı kaynaklı olduğu ilkesi), madde 4'teki "OS seviyesinde idempotent" nitelemesi ve madde 6'nın kaynak listesi. Kalan kararlar yürürlüktedir.

## Bağlam

Phantom-WG Mac uygulaması, ana uygulamayla birlikte gelen üç macOS sistem uzantısına bağlıdır:

- **PhantomTunnel** — `NEPacketTunnelProvider`, WireGuard veya wstunnel + WireGuard tünel bağlantıları
- **PhantomSplitTunnel** — `NETransparentProxyProvider`, uygulama bazında trafik bypass
- **PhantomDNSProxy** — `NEDNSProxyProvider`, PhantomSplitTunnel tarafından bypass edilen uygulamaların seçili ağ arayüzü üzerinden DNS yönlendirme garantisi

İlk olarak **Sistem Uzantıları** hakkında konuşmak istiyorum. macOS üzerinde sistem uzantıları sessiz bağımlılıklar değildir. İşletim sistemi her uzantının ilk yüklenmesinde ***System Settings*** üzerinden kullanıcının açık onayını ister; kullanıcı sonradan aynı panelden herhangi birini devre dışı bırakabilir. Bundle güncelleme sırasında yerinde değiştirilebilir, kaldırma sırasında silinebilir veya kullanıcı onayını yarıda reddederse tutarsız bir durumda kalabilir. Bu yolların hiçbiri uygulamanın içinden atlanamaz. Apple'ın `OSSystemExtensionRequest` API'si duruma dayalı, asenkron çalışır ve her geçişi tek bir durum sorgusu yerine temsilci geri çağırma (delegate-callback) yoluyla yansıtır.

Buna ek olarak, "işletim sistemine sistem uzantısı durumunu sor, arayüz üzerinde durumu yansıt" prensibinin saf hâli iki nedenle yetersiz kalır.

- ***Birincisi***, `propertiesRequest` kurulu sistem uzantılarını sorgulayan tek API'dir, ama hem "uzantı hiç kurulmamış" hem de "uzantı kurulu ama System Settings'te kapalı" durumunda boş dizi döner. Operasyonel olarak bu iki durum birbirinden farklıdır: ilki yeni bir aktivasyon talebi, ikincisi kullanıcının *System Settings*'te toggle'ı açması gerekir ama API'nin cevap şekli aynıdır. Ayırt etmek için cevabı bir aktivasyon talebinin az önce `.completed` sonucuyla bitip bitmediğine göre korelasyon kurmak gerekir; bu ipucu olmadan `Extension Gate`, kapalı durumdaki sistem uzantısını kurulu değilmişçesine yorumlar ve kullanıcıya işletim sistemi kurulum akışını ikinci kez tetikler.

- ***İkincisi***, kullanıcının drop-back'ten kurtarabilmesi gerekir. Kullanıcı sonradan System Settings'te bir sistem uzantısını kapatırsa, sistem uzantısı sürecini sonlandırırsa veya replacement gerektiren bir güncelleme tetiklenirse, uygulamanın tünel arayüzü her şey yolundaymış gibi sessizce devam etmemelidir. Uygulamanın root view'inin bağlanacağı tek bir boolean ("üç sistem uzantısı da ayakta mı?") ve `.activated`'tan çıkan herhangi bir uzantı olduğunda `Extension Gate`'e geri dönüşün belirli bir UX yolunun olması gerekir.

## Karar

Aktivasyon yüzeyi, daha üst düzey bir koordinatör ve özel bir root view ile desteklenen, bundle başına generic bir kontrolcü olarak uygulanır; ana uygulama tek bir hazırlık boolean'ına dayanır.

1. **`ExtensionGateController` — bundle başına bir tane.** Kontrolcü tek bir `bundleID + displayName` çiftini sarar ve her `OSSystemExtensionRequest` sinyalini kapalı bir `Status` enum'una yansıtır:

   - `unknown` — başlangıç durumu, henüz hiçbir sorgu çözülmedi.
   - `notInstalled` — `propertiesRequest` canlı kayıt döndürmedi ve yakın zamanda aktivasyon talebi açılmadı.
   - `activating` — bir aktivasyon talebi sürüyor.
   - `needsApproval` — Apple, sistem uzantısı ilerleyebilmeden önce kullanıcı girdisi (*System Settings toggle*'ı veya *OS Prompt*'u) bekliyor.
   - `activated` — `propertiesRequest` `isEnabled = true` ve onay beklemeyen canlı bir kayıt gösteriyor.
   - `failed(String)` — kalıcı hata (code signature, system policy, eksik entitlement, validation hatası, …).

   Durum değişiklikleri kullanıcı kaynaklıdır. Arka planda polling yoktur; geçişler yalnızca buton basışına (`activate()`, `refresh()`, `deactivate()`) veya *OS delegate callback*'ine cevap olarak gerçekleşir.

2. **`pendingActivationCompleted` bayrağı** boş-properties anomalisini ayırt eder. Bir aktivasyon talebi `.completed` ile çözüldüğünde kontrolcü bu bayrağı aktive eder ve hemen `propertiesRequest`'i yeniden gönderir. Sonraki properties cevabı şu kurala göre işlenir:

   - Canlı kayıt bulundu → status, kaydın `isEnabled` / `isAwaitingUserApproval` bayraklarından gelir.
   - Canlı kayıt yok, bayrak aktif → sistem uzantısı kayıtlı ama System Settings'te kapalı; status `needsApproval` olur, kullanıcı *System Settings*'e yönlendirilir.
   - Canlı kayıt yok, bayrak aktif değil, kontrolcü hâlâ `unknown` → gerçekten kurulmamış; status `notInstalled` olur.
   - Canlı kayıt yok, bayrak aktif değil, kontrolcü başka bir durumda → geçici OS sorgu gecikmesi; no-op.

   Replacement upgrade'leri — Apple sürüm geçişi sırasında çift canlı sürüm raporlayabilir — `pickLive` ile çözülür; öncelik sırası `isEnabled = true`, sonra `isAwaitingUserApproval = true`, sonra herhangi bir canlı kayıt. Seçilen kayıt sistemin gerçekten çalıştırdığı sürümü yansıtır, kaldırılmakta olan eski sürümü değil.

3. **`ExtensionGateCoordinator`** üç kontrolcüyü sahiplenir, root view'e tek bir `allReady` boolean'ı sunar ve `NSApplication.didBecomeActiveNotification` observer'ı üzerinden uygulama foreground'a geldiğinde `checkAll()`'u yeniden gönderir. Drop-back'i yakalayan budur: System Settings'ten sistem uzantısını kapatıp uygulamaya dönen kullanıcı, `Extension Gate`'in zaten durumu yeniden değerlendirdiğini görür. `ExtensionGateCoordinator` ayrıca lokal *settings* menüsü *uninstall* akışı için `uninstallAll()` sunar; üç sistem uzantısını sıralı olarak devre dışı bırakarak kullanıcının uygulamanın bağlı olduğu sistem uzantılarını sistemden tek hareketle tamamen kaldırmasını sağlar.

4. **`ExtensionGateView` + `ExtensionGateRow` — `allReady` olana kadar kullanıcının gördüğü tek arayüz.** Root view (`PhantomApp`) herhangi bir kontrolcü `.activated` değilken `Extension Gate` panelini render eder; tünel arayüzüne başka hiçbir durumda erişilemez. Her satır kontrolcünün durumunu şuna eşler:

   - Status ikonu (yeşil onay, turuncu uyarı, gri x, kırmızı hata, spinner).
   - Yerelleştirilmiş status cümlesi.
   - Bağlamsal aksiyon butonu (`Aktive Et`, `System Settings'i Aç`, `Tekrar Dene`).
   - `.failed` durumu için inline hata mesajı.

   "*System Settings*'i Aç" yolu tedbirlidir: satır *System Settings*'i açmadan önce `activate()`'i tekrar gönderir, OS seviyesinde idempotent (kurulmamış sistem uzantısı kurulur, bekleyen onay prompt'u yeniden yüzeye çıkar, zaten aktif olan sessizce `.completed` döner). Bu sayede kullanıcının arayacağı toggle'ın Network Extensions panelinde gerçekten var olduğu garanti edilir.

5. **Hata haritası kapsamlıdır.** Belgelenmiş her `OSSystemExtensionError.Code` için yerelleştirilmiş kullanıcı mesajı vardır: `authorizationRequired` → `needsApproval`; `extensionNotFound` → `notInstalled`; `unsupportedParentBundleLocation`, `codeSignatureInvalid`, `validationFailed`, `forbiddenBySystemPolicy`, `missingEntitlement` → kalıcı `.failed`, vakaya özgü metinle; bilinmeyen kodlar generic mesaja düşer ve raw kod kullanıcıya iletilir, böylece gelecekteki bir kullanıcı bunu raporlayabilir.

6. **Kalıcı `Extension Gate` durumu yok.** Kontrolcüler, in-flight `pendingActivationCompleted` bayrağı dışında hiçbir kendi yorumlarını önbelleğe almaz. Her durum kararı `propertiesRequest` cevaplarından ve delegate callback'lerinden yeniden türetilir. Bu, uygulamanın dünyaya dair persist ettiği görünümün işletim sistemi çekirdeğinin (kernel) gerçek sistem uzantısı kayıt defteriyle ayrışmasından doğan bug sınıfını engeller. İşletim sistemi tek ***ground truth***'tur.

## Sonuçlar

- **Tek hazırlık boolean'ı.** `allReady`, `PhantomApp`'in tükettiği tek sinyaldir. Tüm `Extension Gate` state-machine endişesi root'ta tek bir binary kontrole indirgenir ve tünel kullanıcı arayüzü üç extension da `.activated` raporlayana kadar erişilemez kalır.

- **Kurtarılabilir drop-back'ler.** Kullanıcı *System Settings* paneli üzerinden bir sistem uzantısını kapatırsa, ayakta olan process'i öldürürse veya replacement upgrade çalıştırırsa, uygulamaya dönüşü `didBecomeActive` observer'ı state'i yeniden değerlendirir ve root view `Extension Gate` tarafına geri düşer. Tünel kullanıcı arayüzü bozulmuş bir durumun ötesine sessizce geçmez.

- **İlk kurulumda üç onay diyalogu.** Uygulama ilk açıldığında kullanıcı üç ayrı *System Settings* prompt'u görür.  Apple birden fazla sistem uzantısını tek bir onayda gruplamadığı için bu durum kaçınılmazdır.

- **Apple framework'üne bağımlı.** `propertiesRequest` semantiği resmi olarak belgelenmemiştir; kapalı-için-boş-array davranışı empirikdir ve gelecekteki bir macOS sürümünde değişebilir. `pendingActivationCompleted` workaround'u controller içinde belgelendi. Bu Apple kontratı değiştirirse hatanın yerini bulmanın kolay olacağı anlamına gelir. `OSSystemExtensionError.Code.validationFailed` Apple'ın verdiği en generic kalıcı koddur ve mesajımız bunu yansıtır. Daha kesin tanı için kullanıcının OS tarafındaki loglara bakılması ve değerlendirilmesi gerekir.

- **Manuel test matrisi.** ***Controller***, tasarlandığı kullanıcı senaryolarında çalıştırıldı.
  - Extension zaten aktifken cold boot
  - Fresh Install (ilk açılış)
  - Kurulu ama System Settings'te kapalı
  - Replacement upgrade (sürüm yenileme)
  - `uninstallAll()` ile üç uzantıyı toplu kaldırma

- **Arka planda polling yok.** Kullanıcı etkileşimleri arasında güç ve runtime maliyeti yoktur. `Extension Gate` yalnızca kullanıcı bir aksiyon aldığında veya uygulamaya döndüğünde çalışır.
