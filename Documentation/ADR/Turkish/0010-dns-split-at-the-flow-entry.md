# ADR-0010 — DNS Ayrımı Kuralda Değil Akışın Girişinde Yapılır

## Durum

Kabul Edildi — 2026-11-15

Bu bir **uzantı kaydıdır**: [ADR-0001 Madde 5](0001-architectural-decision-records.md#karar)'in tarif ettiği yolla, kabul edilmiş bir kaydı daraltır. Daralttığı kayıt ADR-0003'tür. ADR-0003'ün metni değişmez. Bu kayıt yalnız 2. maddesinin mekanizmasının yerini alır.

- Fix: split tunnel declines DNS flows in code, without port 53 rules ([8d43957](https://github.com/ARAS-Workspace/phantom-wg/commit/8d43957ca1afd5c930a183232029335fdec0bba3))

- Refactor: proxy extensions use the macOS 15 flow endpoint APIs ([90b85ab](https://github.com/ARAS-Workspace/phantom-wg/commit/90b85ab27d1330ea0154ff20a110d3eaf0aa0f4f))

## Bağlam

**Daraltılan kayıt:** [ADR-0003 Split-Tunneling ve DNS-Proxy Mimarisi](0003-split-tunneling-and-dns-proxy-architecture.md), [Karar](0003-split-tunneling-and-dns-proxy-architecture.md#karar) bölümünün 2. maddesi.

**Kaynak:** `PhantomSplitTunnel/App/TransparentProxyProvider.swift`, `PhantomSplitTunnel/Features/FlowFiltering/TCPFlowRelay.swift`, `PhantomSplitTunnel/Features/FlowFiltering/UDPFlowRelay.swift`, `PhantomDNSProxy/App/DNSProxyProvider.swift`, `PhantomDNSProxy/Features/DNSFlowRelay.swift`, `project.yml`. Commit [`8d43957`](https://github.com/ARAS-Workspace/phantom-wg/commit/8d43957ca1afd5c930a183232029335fdec0bba3) ve [`90b85ab`](https://github.com/ARAS-Workspace/phantom-wg/commit/90b85ab27d1330ea0154ff20a110d3eaf0aa0f4f).

ADR-0003, DNS akışının (flow) DNS Proxy şeridinde kalmasını ağ kuralı seviyesinde bir carve-out ile sağladı. `PhantomSplitTunnel`, `excludedNetworkRules` içine port 53 için dört kural koyuyordu. Kurallar `0.0.0.0` ve `::` adreslerini UDP ve TCP için ayrı ayrı kapsıyordu. ADR-0003 bu yolu DNS şeridinin tek mekanizması olarak kaydetti.

Bu mekanizma macOS 15'te çalışmıyor. `nesessionmanager`, Split-Tunnel'ın Transparent Proxy oturumunu dört kuralın her biri için `53 cannot be specified as the port for transparent proxy network rules` hatasıyla reddediyor ve oturumu kaldırıyor. DNS Proxy çalışmaya devam ediyor. Transparent Proxy çalışmadığı için listedeki uygulamaların trafiği fiziksel arayüze yönlendirilmiyor. Carve-out `mac-v2.1.0` sürümünden beri yayında. Hatanın macOS 15'te o sürümden beri var olduğu kodun geçmişinden okunuyor. Ölçülen kurulum geliştirme sanal makinesi üzerindedir.

Bu kurallar SDK'nın yazılı sözleşmesine baştan beri aykırıydı. `NETransparentProxyNetworkSettings.h` başlığı `includedNetworkRules` ve `excludedNetworkRules` için port 53'ün kullanılamayacağını ve DNS trafiğinin yalnız alan adına dayalı kurallarla eşleştirilebileceğini yazıyor. Bu cümle macOS 10.15 SDK'sında da var, yani API ilk geldiği günden beri aynı sözleşmeyi taşıyor. macOS 27.0.1 bu kuralları reddetmiyor. Carve-out geliştirme ortamında bu yüzden çalışıyor göründü.

O döneme ait notlarımda `false` döndürmenin sonuç vermediği yazıyor. Notlara göre bir ayrım gerekiyordu ve bu ayrımın akış buraya ulaşmadan daha alt bir katmanda çözülmesi gerekiyordu. O dönemki `TransparentProxyProvider` yalnız `handleNewFlow`'u eziyordu. UDP akışının hedefi orada görünmüyordu. Hedef ancak `handleNewUDPFlow`'un ilk uç noktasında görünür. macOS 15 bu girişi `NEAppProxyUDPFlowHandling` ile Swift'e açtı.

Apple DTS'in bu konudaki yönlendirmesi de aynı yöndedir. DNS akışları Transparent Proxy alt sisteminde özel ele alınır ve DNS'i yakalamak için DNS Proxy kullanılmalıdır ([Apple Developer Forums, DTS, Aralık 2025](https://developer.apple.com/forums/thread/809317)).

### Daraltılan Madde

| ADR-0003 | Bugüne kadarki bağ | Bu kararla artık | Kaynak |
| --- | --- | --- | --- |
| **Madde 2** Ağ-kuralı seviyesinde carve-out | `excludedNetworkRules` içinde port 53 için dört kural vardır. Port 53'ü kuralla hariç tutmak DNS şeridinin tek mekanizmasıdır. | Ağ kuralları port 53 taşımaz. Transparent Proxy 53'e giden akışı girişte tanır ve `false` döner. Akış DNS Proxy'ye düşer. | `TransparentProxyProvider.swift`, commit `8d43957` |

### Ölçülenler

- **macOS 15 (geliştirme VM'i, 2026-11-15):** düzeltmeden önce `nesessionmanager` dört ret satırı yazdı ve Split-Tunnel oturumu kaldırıldı. Düzeltmeden sonra oturum açılıyor ve Split-Tunnel logu `interface resolved: en0 (wiredEthernet)` satırını yazıyor.
- **macOS 27.0.1 (geliştirme makinesi, 2026-11-15):** sistem günlüğünde son üç günde ret satırı yok. Split-Tunnel oturumları carve-out varken de bağlanıyordu.
- **Sıra (macOS 27.0.1, 2026-11-15):** akış önce Transparent Proxy'ye gelir. Transparent Proxy bırakırsa DNS Proxy onu yakalar. System DNS Resolver açıkken Split-Tunnel logu 13:06:16.396 ile 13:06:16.398 arasında `System DNS (mDNSResponder) — DNS left to the system  UDP  2620:fe::fe:53` satırlarını yazdı. DNS-Proxy logu 13:06:16.398 ile 13:06:16.404 arasında `MATCHED System DNS (mDNSResponder) UDP → 1.1.1.1:53 via en0` satırlarını yazdı.
- **Uygulama kimliğiyle gelen 53 akışı (macOS 27.0.1, 2026-11-15):** Brave kimliğiyle gelen UDP 53 akışları da Transparent Proxy'ye geldi ve `Brave Browser — DNS left to the system  UDP  2620:fe::9:53` satırıyla bırakıldı. Aynı oturumda DNS-Proxy logu `MATCHED Brave Browser UDP → 1.1.1.1:53 via en0` satırlarını yazdı.

## Karar

DNS ayrımı ağ kuralında değil, akışın Transparent Proxy'ye girdiği yerde yapılır. Somut olarak:

1. **Ağ kuralları port 53 taşımaz.** `PhantomSplitTunnel` yalnız dual-stack geniş `includedNetworkRules` kuralını kurar. `excludedNetworkRules` kullanılmaz.

2. **53'e giden akış girişte bırakılır.** TCP akışı `handleNewFlow` içinde `remoteFlowEndpoint` ile, UDP akışı `handleNewUDPFlow(_:initialRemoteFlowEndpoint:)` içinde ilk uç nokta ile tanınır. Port 53 ise iki giriş de `false` döner. Akış listedeki bir uygulamaya aitse Split-Tunnel loguna `DNS left to the system` satırı yazılır.

3. **DNS şeridi DNS Proxy'de kalır.** Bırakılan akışı DNS Proxy yakalar ve ADR-0003'te tarif edildiği gibi fiziksel arayüzün çözücüsüne taşır. İki uzantı arasında ADR-0003'ün kurduğu ayrılık değişmez.

Bu karar iki uzantının sayısına, kontrol kanalına ya da System DNS Resolver anahtarına dokunmaz. Yalnızca DNS akışının Transparent Proxy'den hangi yolla ayrıldığını değiştirir.

## Sonuçlar

- macOS 15'te Split-Tunnel yeniden başlıyor. Kurulu 2.1.x uzantıları yeni sürüm kurulana kadar macOS 15'te başlamamaya devam eder.
- Kod, Transparent Proxy ağ kuralları için SDK'nın yazılı sözleşmesine uyar. macOS'un bu sözleşmeyi hangi sürümde uygulamaya başladığı artık davranışı etkilemez.
- Ayrım, Apple'ın belgelemediği bir sıraya dayanır. Akış önce Transparent Proxy'ye, sonra DNS Proxy'ye gelir. Sıra bir macOS sürümünde değişirse DNS şeridi bozulur. Kontrol yolu ölçülebilir durumdadır. Split-Tunnel logundaki `DNS left to the system` satırlarının DNS-Proxy logunda aynı anda `MATCHED` satırlarıyla karşılanması gerekir.
- Uygulama kimliğiyle doğrudan 53'e giden akışlar da (ölçümde Brave) Transparent Proxy'ye gelir ve aynı yolla bırakılır. Split-Tunnel logu bu akışları da gösterir.
- Karar macOS 15'in UDP girişine dayandığı için iki proxy uzantısının tabanı uygulamanın tabanıyla birleşti ve 15.1 oldu. Uzantılar macOS 15'in `NWEndpoint` tabanlı akış API'lerini kullanır ve kullanımdan kalkan `NWHostEndpoint` ailesi kodda kalmadı. Uzantılar yalnız uygulamanın kurduğu sistemlerde çalıştığı için desteklenen sistem kapsamı değişmedi.

## İlgili Kayıtlar

- [ADR-0003](0003-split-tunneling-and-dns-proxy-architecture.md) madde 2: yukarıdaki tabloda daraltıldı. Kaydın öteki maddeleri değişmedi. İki uzantının ayrılığı ve DNS Proxy'nin DNS şeridi bu kaydın da taşıyıcısıdır.
- [ADR-0004](0004-unified-proxy-config-daemon.md): iki proxy uzantısının kontrol kanalı. Değişmedi.
- [ADR-0001](0001-architectural-decision-records.md) madde 5: bu kaydın var olma biçimi. Kabul edilmiş bir ADR düzeltme için değiştirilmez, daraltan yeni bir kayıt açılır.
