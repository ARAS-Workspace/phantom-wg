# Kayıt Referansları

Bu bölümdeki terminal kayıtlarının bir kısmı otomatik iş akışları tarafından oluşturulmaktadır.

## Asset Yapısı

```
documentation/docs/assets/static/recordings/feature-showcase/
├── api/              
├── cli/              
└── manuel/           
```

## Otomatik Kayıt Sistemleri

### API Kayıtları

**Dizin:** `api/`

**Workflow:** [generate-api-recordings.yml](https://github.com/ARAS-Workspace/phantom-wg/blob/main/.github/workflows/generate-api-recordings.yml)

`phantom-api` komutlarını kullanan scriptlerin otomatik kaydı. GitHub Actions üzerinde `workflow_dispatch` ile manuel tetiklenir.

**Kayıt Aracı:** `tools/recording-utilities/recording_automations_api/`

| Dosya         | Açıklama                                      |
|---------------|-----------------------------------------------|
| `automate.sh` | Tüm scriptleri sırayla çalıştırır             |
| `common.sh`   | Ortak fonksiyonlar (ssh_connect, run_command) |
| `api/*.sh`    | Her API işlemi için ayrı script               |

**Mevcut Kayıtlar:**

- `server_status` - Sunucu durumu sorgulama
- `add_client` - İstemci ekleme
- `list_clients` - İstemci listesi
- `export_client` - Konfigürasyon dışa aktarma
- `latest_clients` - Son eklenen istemciler
- `tweak_settings` - Ayar değişiklikleri
- `change_subnet` - Subnet değişikliği
- `get_firewall_status` - Güvenlik duvarı durumu
- `service_logs` - Servis logları
- `restart_service` - Servis yeniden başlatma
- `remove_client` - İstemci silme
- `dns_compact` - DNS yönetimi

---

### CLI Kayıtları

**Dizin:** `cli/`

**Workflow:** [generate-cli-recordings.yml](https://github.com/ARAS-Workspace/phantom-wg/blob/main/.github/workflows/generate-cli-recordings.yml)

İnteraktif `phantom-wg` menüsünün otomatik kaydı. YAML tabanlı workflow tanımları ile çalışır.

**Kayıt Aracı:** `tools/recording-utilities/phantom-recorder/`

| Dosya                 | Açıklama                           |
|-----------------------|------------------------------------|
| `phantom_recorder.py` | Ana kayıt motoru (pexpect tabanlı) |
| `workflows/*.yaml`    | Senaryo tanım dosyaları            |

**Mevcut Kayıtlar:**

- `server_status` - Sunucu durumu görüntüleme
- `add_client` - İstemci ekleme
- `remove_client` - İstemci silme
- `list_clients` - İstemci listesi
- `export_client` - Konfigürasyon dışa aktarma
- `latest_clients` - Son eklenen istemciler
- `tweak_settings` - Ayar değişiklikleri
- `change_subnet` - Subnet değişikliği
- `get_firewall_status` - Güvenlik duvarı durumu
- `service_logs` - Servis logları
- `restart_service` - Servis yeniden başlatma
- `dns_compact` - DNS yönetimi

---

### Manuel Kayıtlar

**Dizin:** `manuel/`

Test ortamında manuel olarak kaydedilen senaryolar. Birden fazla sunucu gerektiren durumlarda alınması gereken kayıtlar 
ve karmaşık yapılandırmalar için kullanılır.

**Senaryo Dökümanları:** `tools/recording-utilities/recording_environment/scenarios/`

- `multihop_compact.md` - Multihop VPN kurulum senaryosu
- `ghost_compact.md` - Ghost Mode kurulum senaryosu

