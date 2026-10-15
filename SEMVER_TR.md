# Phantom-WG Anlamsal Versiyonlama

## Ürün Versiyonları

| Ürün                  | Açıklama                                          | Branch |
|-----------------------|---------------------------------------------------|--------|
| **Phantom-WG Modern** | Tam platform (daemon + SPA + auth + bridge'ler)   | main   |

## Versiyon Hiyerarşisi

**Phantom-WG Modern versiyonu = Phantom Daemon versiyonu.**

Daemon, ürün versiyonunu belirleyen merkezi pakettir.
Diğer tüm bileşenler kendi bağımsız semver döngülerine sahip bağımlılıklardır.

```
Phantom-WG Modern vX.Y.Z
  └── Phantom Daemon vX.Y.Z             ← ürün versiyonunun kaynağı
        ├── auth-service vA.B.C         ← bağımlılık
        ├── wireguard-go-bridge vA.B.C  ← bağımlılık
        ├── firewall-bridge vA.B.C      ← bağımlılık
        ├── react-spa (build artifact)  ← release ile birlikte paketlenir
        ├── vendor/linux-{arch}/        ← iki bridge, release ile paketlenir
        └── nginx config                ← release ile birlikte paketlenir
```

## Daemon Versiyonu (Ürün Versiyonu)

Daemon versiyonu standart semver'i takip eder ve doğrudan
Phantom-WG Modern release versiyonuna eşlenir:

- **Major** — Kırılgan değişiklikler, mimari değişimler
- **Minor** — Yeni özellikler, yeni API uç noktaları
- **Patch** — Hata düzeltmeleri, güvenlik yamaları

Daemon versiyonu, ürün versiyonu için tek doğruluk kaynağıdır.
Yeni bir Phantom-WG Modern release'i çıkarıldığında, daemon versiyonunu taşır.

### Nerede tanımlı

- `phantom_daemon/__init__.py` → `__version__`
- `GET /api/core/hello` → `version` alanı
- Dashboard durum kartı → kullanıcıya gösterilir

## Bağımlılık Versiyonları

Bağımlılıklar kendi semver'lerini bağımsız olarak yönetir. Versiyonları
geliştirme sürecinde sık sık değişir. Bir bağımlılık versiyon artışı,
daemon (ürün) versiyonunu otomatik olarak **artırmaz**.

Daemon versiyon artışı, entegre ürün — daemon + bağımlılıklar —
yeni bir release kilometre taşına ulaştığında gerçekleşir.

### Bağımlılıklar

| Bileşen                 | Versiyonlama         | Branch                  |
|-------------------------|----------------------|-------------------------|
| **auth-service**        | semver               | dev/auth-service        |
| **wireguard-go-bridge** | semver               | dev/wireguard-go-bridge |
| **firewall-bridge**     | semver               | dev/firewall-bridge     |
| **react-spa**           | package.json version | dev/daemon (embedded)   |

### Test Bağımlılıkları

Ürünün parçası değildir ve release paketine girmez. compose-bridge,
packager'ın pakete almadığı `e2e_tests/` altındaki süitleri yürütür.

| Bileşen              | Versiyonlama | Branch                   |
|----------------------|--------------|--------------------------|
| **compose-bridge**   | semver       | dev/tests/compose-bridge |

### Vendor Dağıtımı

Her bridge kendi etiketli GitHub release'ini yayınlar, mimari başına bir
arşiv:

```
github.com/ARAS-Workspace/phantom-wg/releases/download/
├── vendor-firewall-bridge-v{version}/linux-{arch}.zip
└── vendor-wireguard-go-bridge-v{version}/linux-{arch}.zip
```

Takip edilecek bir `latest` yok. GitHub'ın latest-release ucu bileşen için
değil depo için cevap verir, bu yüzden her tüketici bir etiket pinler. Daemon
hem sürümleri hem her arşivin SHA-256'sını `Dockerfile` ve `dev.Dockerfile`
içinde pinler; digest'i tutmayan bir indirme build'i kırar.

Bridge'ler imaja iki yoldan ulaşır:

- **Release paketi** — arşiv onları `vendor/linux-{arch}/` altında taşır,
  oraya release workflow'u yazar. Build o ağacı kullanır ve ağ isteği yapmaz.
- **`main` klonu** — `vendor/` yoktur, build pinli release'leri indirir.

