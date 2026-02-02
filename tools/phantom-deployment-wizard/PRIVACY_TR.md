<!--
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
-->

# Gizlilik Bildirimi — Phantom Deployment Wizard

**Son Güncelleme:** Ocak 2026

## Genel Bakış

Phantom Deployment Wizard, Phantom-WG ön yüklü bir VPS sunucu oluşturmanıza yardımcı olan açık kaynaklı ve kendi sunucunuzda barındırılabilen bir dağıtım aracıdır. Bu bildirim, aracın hangi verileri işlediğini, bu verilerin nasıl aktarıldığını ve hangi üçüncü taraf hizmetlerin kullanıldığını açıklamaktadır.

## Üçüncü Taraf Sorumluluk Reddi

**Phantom-WG'nin SporeStack ile herhangi bir ortaklığı, iş birliği veya ticari ilişkisi bulunmamaktadır.** SporeStack, bağımsız bir üçüncü taraf VPS barındırma sağlayıcısıdır. Bu araç, SporeStack API'si ile yalnızca kolay entegre edilebilir, gizlilik odaklı bir API sunması ve kişisel kimlik doğrulaması gerektirmeden kripto para ile ödeme kabul etmesi nedeniyle entegre edilmiştir. SporeStack'in kendi gizlilik ve kabul edilebilir kullanım politikaları, hizmetleri için bağımsız olarak geçerlidir.

SporeStack politikaları için: [sporestack.com](https://sporestack.com/)

## Bu Araç Hangi Verileri Toplar?

### Sizin Sağladığınız Veriler

| Veri                  | Amaç                                                                                   | Nereye Gönderilir                                                |
|-----------------------|----------------------------------------------------------------------------------------|------------------------------------------------------------------|
| **SporeStack Token**  | SporeStack hesabınızı doğrular                                                         | Doğrulama ve sunucu yönetimi için SporeStack API'sine gönderilir |
| **SSH Açık Anahtarı** | Dağıtılan sunucuya SSH erişimi sağlar                                                  | SporeStack API'sine gönderilir ve sunucuya tanımlanır            |
| **Sağlayıcı Seçimi**  | Sunucunuzun hangi bulut sağlayıcısında barındırılacağını belirler (Vultr/DigitalOcean) | Dağıtım parametresi olarak SporeStack API'sine gönderilir        |
| **Bölge Seçimi**      | Sunucunuzun coğrafi konumunu belirler                                                  | Dağıtım parametresi olarak SporeStack API'sine gönderilir        |
| **İşletim Sistemi**   | Sunucunuza kurulacak işletim sistemini belirler                                        | Dağıtım parametresi olarak SporeStack API'sine gönderilir        |
| **Sunucu Boyutu**     | Sunucunuzun donanım özelliklerini belirler                                             | Dağıtım parametresi olarak SporeStack API'sine gönderilir        |
| **Kiralama Süresi**   | Sunucunun ne kadar süreliğine kiralanacağını belirler                                  | Dağıtım parametresi olarak SporeStack API'sine gönderilir        |

### Kullanım Sırasında Üretilen Veriler

| Veri                                  | Amaç                                                 | Nereye Gider                                                                               |
|---------------------------------------|------------------------------------------------------|--------------------------------------------------------------------------------------------|
| **SSH Özel Anahtarı** (oluşturulursa) | Sunucuya SSH ile bağlanmanızı sağlar                 | Tarayıcınızda yalnızca bir kez görüntülenir — **hiçbir sunucuya veya API'ye gönderilmez**  |
| **Makine Kimliği (Machine ID)**       | Dağıtılan sunucunuzu durum sorgulaması için tanımlar | SporeStack API'sinden alınır, tarayıcı oturumunda saklanır                                 |
| **Sunucu IPv4 Adresi**                | Dağıtılan sunucunuzun genel IP adresi                | SporeStack API'sinden alınır, tarayıcı oturumunda saklanır                                 |
| **Dağıtım Yapılandırması**            | Seçilen tüm seçeneklerin özeti                       | Tarayıcı oturumunda saklanır; isteğe bağlı olarak JSON dosyası şeklinde dışa aktarılabilir |

## Veri Depolama

### Kalıcı Depolama Yoktur

Bu araç herhangi bir veritabanı, günlük dosyası veya kalıcı depolama mekanizması **kullanmaz**. Tüm veriler yalnızca tarayıcınızın Streamlit oturum durumunda bulunur ve aşağıdaki durumlarda otomatik olarak silinir:

- Tarayıcı sekmesini kapattığınızda
- Tarayıcı oturumunuzun süresi dolduğunda
- Sihirbazda "Start Over" (Baştan Başla) düğmesine tıkladığınızda

### Sunucu Taraflı Günlük Kaydı Yoktur

Streamlit uygulaması kullanıcı verilerini diske yazmaz. Konteyner günlükleri (Docker üzerinden çalıştırılıyorsa) yalnızca uygulama düzeyinde işletimsel mesajlar içerir; kullanıcı girdileri veya API token bilgileri içermez.

### İsteğe Bağlı Dışa Aktarım

Dağıtım sürecinin sonunda, dağıtım yapılandırmanızı JSON dosyası olarak indirmeyi tercih edebilirsiniz. Bu dosya seçtiğiniz sağlayıcı, bölge, işletim sistemi, sunucu boyutu, kiralama süresi, sunucu IP adresi ve makine kimliğini içerir. **SporeStack token veya SSH özel anahtarınızı içermez.**

## Dış Ağ Bağlantıları

Bu araç aşağıdaki hizmetlere giden bağlantılar kurar:

### 1. SporeStack API (`api.sporestack.com`)
- **Amaç:** Token doğrulama, altyapı sorguları (bölgeler, işletim sistemleri, sunucu boyutları), fiyat teklifi, sunucu dağıtımı ve durum sorgulama
- **Protokol:** HTTPS
- **Kimlik Doğrulama:** SporeStack token (URL yolunun bir parçası olarak gönderilir)
- **Gönderilen veriler:** Token, SSH açık anahtarı, dağıtım parametreleri (sağlayıcı, bölge, işletim sistemi, sunucu boyutu, gün sayısı, cloud-init betiği)

### 2. Tor Project Check API (`check.torproject.org`) — Yalnızca Üretim Modu
- **Amaç:** Sihirbazın trafiği Tor üzerinden yönlendirip yönlendirmediğini doğrular
- **Protokol:** HTTPS
- **Gönderilen veriler:** Standart HTTP isteği (kullanıcı verisi içermez)
- **Alınan veriler:** Tor bağlantı durumu ve çıkış düğümü IP adresi
- **Ne zaman:** Yalnızca araç Tor modunda çalıştığında (`TOR_MODE=1`)

### 3. Phantom Kurulum Betiği (`install.phantom.tc`) — Yalnızca Sunucu Tarafı
- **Amaç:** Dağıtılan sunucuya Phantom-WG kurar
- **Protokol:** HTTPS
- **Önemli:** Bu bağlantı, sihirbaz uygulaması tarafından **değil**, cloud-init aracılığıyla **dağıtılan sunucunuz tarafından** kurulur

## Bu Aracın Yapmadıkları

- **Analitik veya telemetri yoktur.** Streamlit'in yerleşik kullanım istatistikleri açıkça devre dışı bırakılmıştır (`gatherUsageStats = false`).
- **İzleme çerezleri veya parmak izi takibi yoktur.** Üçüncü taraf izleme betikleri yüklenmez.
- **Kullanıcı hesabı veya kayıt yoktur.** Araç, kullanıcı hesabı oluşturmaz veya yönetmez.
- **Veri paylaşımı yoktur.** Verileriniz, sunucunuzun dağıtımı için gerekli olan SporeStack dışında kimseyle paylaşılmaz.
- **Veri saklama yoktur.** Oturumunuz sona erdikten sonra hiçbir veri kalıcı olarak tutulmaz.
- **Ödeme işleme yoktur.** Tüm ödemeler tamamen SporeStack tarafından yönetilir. Bu araç cüzdan adresleri, işlem kimlikleri veya ödeme detayları ile hiçbir şekilde ilgilenmez.

## Tor Yönlendirme (Üretim Dağıtımı)

Araç, Tor gizli servisi olarak dağıtıldığında (`docker-compose.hidden.yml` kullanılarak), sihirbazdan çıkan tüm trafik — SporeStack API çağrıları dahil — Tor ağı üzerinden yönlendirilir. Bu durumda:

- Gerçek IP adresiniz SporeStack'e açığa çıkmaz
- Sihirbaza `.onion` adresi üzerinden erişilir
- DNS çözümlemesi Tor üzerinden gerçekleşir

Bu, isteğe bağlı bir dağıtım yapılandırmasıdır. Yerel olarak veya Tor kurulumu olmadan çalıştırıldığında, normal ağ bağlantınız kullanılır.

## SSH Anahtar Güvenliği

Sihirbaz içinde SSH anahtar çifti oluşturmayı tercih ederseniz:

- **Özel anahtar**, 4096-bit RSA algoritması kullanılarak yerel olarak üretilir (`paramiko` kütüphanesi aracılığıyla)
- Özel anahtar, kopyalamanız için tarayıcınızda **yalnızca bir kez** görüntülenir
- Özel anahtar yalnızca tarayıcı oturum belleğinde tutulur — **hiçbir API veya sunucuya iletilmez**
- **Açık anahtar**, sunucunuza tanımlanabilmesi için SporeStack'e gönderilir

Mevcut bir SSH açık anahtarı içe aktarırsanız, yalnızca açık anahtar işlenir. Sihirbaz, mevcut özel anahtarınızı hiçbir zaman istemez veya işlemez.

## Cloud-Init Betiği

Dağıtım, sunucunuzun ilk açılışında çalışan bir cloud-init betiği içerir. Bu betik:

1. Sistem paketlerini günceller
2. `curl` paketini kurar
3. `install.phantom.tc` adresinden Phantom-WG kurulum betiğini indirir ve çalıştırır

Cloud-init betiği, dağıtımdan önce sihirbaz içinde görüntülenebilir ve incelenebilir ("View Cloud Init Script" bölümünden). Vultr dağıtımlarında betik iletim öncesinde base64 ile kodlanır; DigitalOcean için düz metin olarak gönderilir. Her iki durumda da içerik aynıdır.

## Açık Kaynak ve Şeffaflık

Phantom-WG açık kaynaklı bir projedir. Bu dağıtım sihirbazı, CI/CD pipeline'ı ve tüm altyapı yapılandırmaları dahil olmak üzere kod tabanının tamamı GitHub üzerinde herkese açık ve denetlenebilir durumdadır.

Sihirbazın üretim dağıtımı (Tor gizli servisi), doğrudan repository üzerinden bir GitHub Actions workflow'u (`.github/workflows/phantom-wizard-hidden-deployment-workflow.yml`) aracılığıyla yönetilmektedir. Bu şu anlama gelir:

- **Her kod değişikliği izlenebilir.** Sihirbaza yapılan tüm güncellemeler, herkese açık repository üzerinden dağıtım pipeline'ını tetikler.
- **Gizli değişiklik yoktur.** Üretim ortamı, GitHub'da inceleyebileceğiniz kaynak kodun aynısından derlenir ve dağıtılır.
- **Denetlenebilir pipeline.** Workflow yapılandırması, dağıtım betikleri ve Docker yapılandırmaları herkese açık repository'nin bir parçasıdır.

Bu yaklaşım, kullandığınız aracın inceleyebildiğiniz kaynak kodla birebir aynı olmasını garanti eder — ayrı, gizli bir kod tabanı bulunmamaktadır.

## Haklarınız ve Kontrolünüz

- **Şeffaflık:** Tüm kaynak kodu açık kaynaklıdır ve GitHub üzerinde denetlenebilir
- **Doğrulanabilir dağıtım:** Üretim ortamı, doğrudan repository üzerindeki herkese açık CI/CD pipeline'ı aracılığıyla dağıtılır
- **Dağıtım öncesi inceleme:** Sihirbaz, dağıtımı onaylamadan önce tam API istek gövdesini ve cloud-init betiğini gösterir
- **Bağımlılık yoktur:** Dağıtılan sunucu standart bir VPS'dir — SSH ile tam root erişiminiz vardır
- **Oturum kontrolü:** Tüm oturum verilerini temizlemek için istediğiniz zaman "Start Over" düğmesine tıklayabilirsiniz
- **Dışa aktarım kontrolü:** Dağıtım yapılandırması JSON dosyasını indirip indirmemeye siz karar verirsiniz

## Bu Bildirimde Yapılacak Değişiklikler

Bu gizlilik bildirimi, araç geliştikçe güncellenebilir. Değişiklikler, güncellenmiş tarih ile bu dosyaya yansıtılır. Araç kendi sunucunuzda barındırıldığı için, çalıştırdığınız araç sürümüne karşılık gelen bildirim sürümüne her zaman erişiminiz vardır.

## İletişim

Bu gizlilik bildirimi veya Phantom Deployment Wizard hakkında sorularınız için:

**Rıza Emre ARAS** — [r.emrearas@proton.me](mailto:r.emrearas@proton.me)