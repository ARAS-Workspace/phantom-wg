<!--
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
-->

# Gizlilik Bildirimi — install.phantom.tc

**Son Güncelleme:** Ocak 2026

## Genel Bakış

`install.phantom.tc`, Phantom-WG bootstrap kurulum betiğini sunan bir Cloudflare Worker'dır. Tamamen [phantom-wg](https://github.com/ARAS-Workspace/phantom-wg) GitHub reposundan yönetilir ve GitHub Actions (`.github/workflows/deploy-phantom-install.yml`) aracılığıyla otomatik olarak deploy edilir.

## Kaynak Kod ve Dağıtım

- **Kaynak:** [`tools/phantom-install/`](https://github.com/ARAS-Workspace/phantom-wg/tree/main/tools/phantom-install)
- **Dağıtım:** GitHub Actions workflow'u, `main` branch'ine yapılan ve `tools/phantom-install/**` yolunu etkileyen push'larda tetiklenir
- **Çalışma Ortamı:** Cloudflare Workers (stateless, kalıcı depolama yok)

## Endpoint'ler ve Veri İşleme

| Endpoint            | Metot | Amaç                                                                                  | Veri İşleme                                                                                      |
|---------------------|-------|---------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `/` veya `/install` | GET   | Kurulum shell betiğini döndürür                                                       | Statik dosya sunulur; veri toplanmaz                                                             |
| `/ip`               | GET   | Çağıran tarafın genel IP adresini döndürür (`CF-Connecting-IP` header'ı aracılığıyla) | IP, yanıt gövdesinde çağırana yansıtılır; **saklanmaz**, loglanmaz veya başka bir yere iletilmez |
| `/health`           | GET   | Sağlık kontrolü için `OK` döndürür                                                    | Veri toplanmaz                                                                                   |

Diğer tüm yollar `404 Not Found` yanıtı döndürür.

## Bu Servisin Yapmadıkları

- **Analitik yoktur.** Worker kodu herhangi bir analitik, izleme veya kullanım ölçümü içermez.
- **Telemetri yoktur.** Herhangi bir harici servise, üçüncü tarafa veya raporlama uç noktasına veri gönderilmez.
- **Loglama yoktur.** Worker, istek verilerini herhangi bir günlük dosyasına, dosyaya veya veritabanına yazmaz.
- **Veritabanı veya kalıcı depolama yoktur.** Worker tamamen stateless'tır — Cloudflare KV, D1, R2, Durable Objects veya başka herhangi bir depolama mekanizması kullanmaz.
- **Çerez veya parmak izi takibi yoktur.** Hiçbir çerez ayarlanmaz ve istemci parmak izi takibi yapılmaz.
- **Kullanıcı hesabı veya kimlik doğrulama yoktur.** Servis tamamen açık ve anonimdir.

## Cloudflare Altyapı Notu

Bir Cloudflare Worker olarak bu servis, Cloudflare'in küresel ağı üzerinde çalışır. Cloudflare, platformlarında çalışan herhangi bir servis için standart olduğu üzere, kendi altyapı dashboard'u aracılığıyla operasyonel metrikler (istek sayıları ve hata oranları gibi) toplayabilir. Bu, Cloudflare platformunun doğasında olan bir özellik olup Worker kodu tarafından kontrol edilmez. Detaylar için [Cloudflare Gizlilik Politikası](https://www.cloudflare.com/privacypolicy/)'na bakınız.

## Açık Kaynak ve Şeffaflık

Bu Worker'ın kaynak kodunun tamamı, dağıtım workflow'u ve yapılandırması [phantom-wg](https://github.com/ARAS-Workspace/phantom-wg) reposunda herkese açık olarak mevcuttur. Her dağıtım, herkese açık repodan tetiklenir — ayrı, gizli bir kod tabanı bulunmamaktadır.

## Bu Bildirimde Yapılacak Değişiklikler

Bu gizlilik bildirimi, servis geliştikçe güncellenebilir. Değişiklikler, güncellenmiş tarih ile bu dosyaya yansıtılır.

## İletişim

Bu gizlilik bildirimi veya install.phantom.tc servisi hakkında sorularınız için:

**Rıza Emre ARAS** — [r.emrearas@proton.me](mailto:r.emrearas@proton.me)
