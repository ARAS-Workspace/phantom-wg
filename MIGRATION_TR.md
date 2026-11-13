# Taşıma Rehberi: 1.1.5 → 2.0.0

Bu rehber, çalışan bir Phantom-WG Modern 1.1.5 kurulumunu 2.0.0 sürümüne taşır. 2.0.0, 1.1.5'in yanına kendi dizinine kurulur. Veri ve ortam dosyaları yeni dizine kopyalanır. 1.1.5 dizini olduğu gibi kalır ve geri dönüş yoludur.

> [!NOTE]
> Bu rehber adımları ve gerekçelerini kısaca verir. İki sürüm arasındaki farkların tamamı ve adımların dayandığı ölçümler dağıtımla gelen [`MIGRATION`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/MIGRATION) dosyasındadır.

## Başlamadan Önce

**Olduğu gibi taşınanlar**

- WireGuard sunucu anahtarları. 1.1.5'in istemci yapılandırmaları çalışmaya devam eder.
- İstemciler, adres havuzu, multihop exit tanımları ve firewall durumu.
- Kullanıcılar, rolleri, şifreleri, TOTP kayıtları ve audit log.
- TLS sertifikası (self-signed ya da Let's Encrypt).
- `.env.daemon` dosyası.

**Kesinti.** Stack, 3. adımdaki `down` komutundan 7. adımdaki `up` komutuna kadar kapalıdır. [Prova koşusunda](https://github.com/ARAS-Workspace/phantom-wg/actions/runs/43168361592) bu süre, imajlar 2. adımda çekilmiş olarak, 28 saniyeydi.

**Dizinler.** Örnekler, 1.1.5 hızlı başlangıcındaki gibi root olarak çalışır. 1.1.5 `/opt/phantom-wg` dizinindedir ve 2.0.0 `/opt/phantom-wg-modern` dizinine kurulur. Başka dizinler de aynı şekilde çalışır.

## Gereksinimler

2.0.0, host'tan 1.1.5'ten fazlasını ister. 1.1.5 için Docker Engine 20.10 ve Docker Compose v2 yeterliydi.

| Gereksinim     | 2.0.0                                      |
|----------------|--------------------------------------------|
| Docker Engine  | 27.0.1 veya üstü                           |
| Docker Compose | 2.27.2 veya üstü                           |
| Kernel         | 5.15 veya üstü                             |
| Python         | `python3` 3.9 veya üstü                    |
| TUN            | `/dev/net/tun`                             |
| Araçlar        | `bash`, `git`, release arşivi için `unzip` |

> [!WARNING]
> `gates` komutu Docker ve Compose sürümlerini raporlar ama karşılaştırmaz. 2. adımdaki çıktıyı bu tabloyla karşılaştırın.

## Adımlar

### 1. Mevcut Kurulumu İnceleme

```bash
cd /opt/phantom-wg
./tools/prod.sh status
git status --short
git show HEAD:docker-compose.yml | diff - docker-compose.yml
```

Bu adım, sunucunuzda elle yapılmış değişiklikleri gösterir. `git status` değişen dosyaları listeler ama `compose lock` altındaki `docker-compose.yml` dosyasını göstermez. Son komut bu dosyadaki değişiklikleri kilitli olsa da basar. Değişiklik yoksa çıktı boş kalır. Kendi port ya da subnet ayarınız varsa not alın. Bu ayarlar 6. adımda yerine yazılır.

### 2. Yeni Sürümü İndirme

```bash
git clone --depth 1 --branch main \
  https://github.com/ARAS-Workspace/phantom-wg.git \
  /opt/phantom-wg-modern
cd /opt/phantom-wg-modern
./tools/prod.sh gates
./tools/prod.sh pull
```

- Dizin adını yazın. Dizin adı verilmeyen klon `phantom-wg` adını alır. `/opt` altında bu ad 1.1.5'in dizinidir ve git orada durur.
- `gates` host'un sağladıklarını raporlar.
- `pull` imajları şimdiden indirir. 1.1.5 bu sırada hizmet vermeye devam eder ve indirme kesintiye eklenmez.

<details>
<summary>Release arşivi ile indirme</summary>

```bash
cd /opt
unzip phantom-wg-modern-v2.0.0-amd64.zip    # ya da -arm64
cd /opt/phantom-wg-modern
./tools/prod.sh gates
```

Arşiv imajlarını `images/` dizininde taşır. `setup` onları 5. adımda yükler, bu yüzden `pull` gerekmez.

</details>

### 3. Mevcut Kurulumu Durdurma

```bash
cd /opt/phantom-wg
./tools/prod.sh down
```

Veritabanları bir sonraki adımda kopyalanır. Çalışan bir stack onları yarım yazılmış bırakabilir. Kesinti bu komutla başlar.

### 4. Veriyi ve Ortam Dosyalarını Kopyalama

```bash
cd /opt/phantom-wg-modern
cp -a /opt/phantom-wg/container-data /opt/phantom-wg/.env.daemon \
  /opt/phantom-wg/.env.auth-service .
chown -R --reference=. container-data .env.daemon .env.auth-service
```

- `cp -a` dosyaları 1.1.5'teki sahipleriyle kopyalar.
- `chown` kopyayı bu dizinin sahibine verir. 2.0.0 araçları dosyaları bu kullanıcı olarak yazar.
- Bu adımı root olarak ya da `sudo` ile çalıştırın. `container-data`, daemon'ın root olarak yazdığı dosyaları taşır.

### 5. Eksikleri Oluşturma

```bash
./tools/prod.sh setup
```

`setup` yalnızca eksik olanı oluşturur. Burada eksik olan `.env` ve `docker-compose.override.yml` dosyalarıdır. 1.1.5'ten gelen anahtarlara, auth veritabanına, TLS sertifikasına ve adres havuzuna dokunmaz.

### 6. Ortam Dosyalarını Düzenleme

`.env.auth-service` dosyasında `AUTH_PROXY_MAX_BODY` değerini değiştirin ve hemen altına yeni satırı ekleyin:

```ini
AUTH_PROXY_MAX_BODY=65536
AUTH_PROXY_BACKUP_MAX_BODY=67108864
```

2.0.0, API üzerinden geçen istek gövdesini 64 KiB ile sınırlar. Yalnızca yedek yükleme rotaları 64 MiB taşır. Dosya bu değişiklik olmadan da çalışır. Bu iki satır onu 2.0.0'ın ayarına getirir.

> [!WARNING]
> 1.1.5'in `.env.auth-service` dosyası satır sonu olmadan biter. `echo >>` ile eklenen satır son satıra yapışır ve auth-service o değerde durur. Dosyayı bir editörle düzenleyin.

Sunucuya özgü ayarlarınız varsa 1. adımda not aldıklarınızı 2.0.0'daki yerlerine yazın:

| 1.1.5'teki ayar                                    | 2.0.0'daki yeri                                                                                |
|----------------------------------------------------|------------------------------------------------------------------------------------------------|
| Kendi portlarınız                                  | `docker-compose.override.yml`                                                                  |
| Kendi subnet'leriniz                               | `.env` dosyasında `PHANTOM_SUBNET_V4` ve `PHANTOM_SUBNET_V6`                                   |
| `.env.daemon` içinde kendi `WIREGUARD_LISTEN_PORT` | `docker-compose.override.yml` dosyasındaki UDP girdisinin konteyner tarafı aynı port olmalıdır |

### 7. Yeni Sürümü Başlatma

```bash
./tools/prod.sh up
./tools/prod.sh status
./tools/prod.sh show-versions
```

Kesinti `up` komutuyla biter. Öteki iki komut servislerin durumunu ve sürümlerini gösterir.

## Kontrol

- [ ] Kontrol paneli açılıyor ve 1.1.5'in `admin` hesabı aynı şifreyle giriş yapıyor.
- [ ] 1.1.5'in istemcileri listeleniyor.
- [ ] Bir istemci 1.1.5'teki yapılandırmasıyla bağlanıyor ve el sıkışması kontrol panelinde görünüyor.
- [ ] O istemcinin trafiği sunucu üzerinden çıkıyor. İnternetin gördüğü adres sunucunun adresi.
- [ ] Audit log, 1.1.5'in kayıtlarını yeni kayıtlardan önce listeliyor.

## Geri Dönüş

1.1.5 dizini olduğu gibi durur. 4. adım ondan yalnızca kopyaladı.

```bash
cd /opt/phantom-wg-modern
./tools/prod.sh down
cd /opt/phantom-wg
./tools/prod.sh up
```

2.0.0'ın 7. adımdan sonra yazdıkları (yeni istemciler, kullanıcılar, audit kayıtları) `/opt/phantom-wg-modern` dizininde kalır. 1.1.5 bunları taşımaz.

## Taşımadan Sonra

**Let's Encrypt.** Sertifika durumu `container-data/certbot` altındadır ve 4. adımda kopyalanır. Sertifikayı yenileyen bir cron işi ya da timer 1.1.5 dizinini gösterir. Onu yeni dizine yönlendirin.

**1.1.5'in imajları ve volume'u.** 2.0.0'ın hizmet verdiğinden emin olduktan sonra kaldırın:

```bash
docker image rm phantom-wg-daemon phantom-wg-auth-service nginx:1-alpine
docker volume rm phantom-wg_phantom-sock
```

Adlar 1.1.5'in dizin adından gelir. 1.1.5 dizini yerinde durdukça geri dönüş, imajlar ve volume silindikten sonra da çalışır. Bu durumda `up` imajları yeniden kurar ve volume'u yeniden oluşturur.

**Güncellemeler.** Git klonu ile kurulan 2.0.0, `./tools/prod.sh update` ile güncellenir. Ayrıntılar [`UPDATE`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/UPDATE) dosyasındadır.
