# ADR-0007 — Aktivasyon ve Kasa Yüzeylerinde Kabul Sonrası Hardening (Sertleştirme)

## Durum

Kabul Edildi — 2026-08-08

Bu hardening işleminin beraberinde yazılan bir ADR dökümandır. Tek belgede iki hardening toplanır; ikisi de bir kararı tersine çevirmez, yalnızca daraltır.

- Fix: stop re-activating a live extension when opening Settings from the gate (cf1eac7)

- Fix: roll back the vault store on a failed rewrite, propagate broken enumerations, and pin the vault peer identifier (1db8811)

## Bağlam

2026-08-05 sonrası yapılan inceleme, kabul edilen metnin iki yüzeyde kodun gerisinde kaldığını gösterdi. Her iki yüzeyde de kod, dokümanda tarif edilenden daha katı davranıyor. 

### 1. Gate satırı aktivasyonu koşullu hale getirildi

`.needsApproval` satırındaki System Settings butonu, önceden ayarları açmadan önce koşulsuz olarak `activate()` çağırıyordu (ADR-0002 madde 4). ADR-0006, aktivasyon talebinin kurulu bundle ile bayt-özdeş olsa bile uzantıyı tam bir değişimle (replacement) yeniden kurduğunu ve bu sırada çalışan provider sürecinin sonlandığını ölçmüştü. `controller.status` değeri butona basıldığı an okunur; panelin ekrana gelmesiyle butona basılması arasındaki kısa aralıkta bir foreground yenilemesi durumu `.activated`'a taşırsa, koşulsuz çağrı o an çalışan uzantıyı yeniden kurup sonlandırırdı. Aktivasyon artık yalnız durum hâlâ `.notInstalled` veya `.needsApproval` iken çağrılır:

```swift
onOpenSettings: {
    if controller.status == .notInstalled
        || controller.status == .needsApproval {
        controller.activate()
    }
    openSystemSettings()
}
```

`.needsApproval` çağrısı korunur; amacı onay istemini yeniden göstermektir, bu da maddenin özgün işlevidir. Dışarıda bırakılan tek durum `.activated`'dır: çalışan bir uzantıya aktivasyon göndermek onu yeniden kurup sonlandırır. Dosya: `Phantom-WG-MacOS/App/ExtensionGate/ExtensionGateView.swift`.

### 2. Kasa daemon eş sabiti kimliğe genişletildi

Kasa ve proxy daemon'ları ortak XPC iskeletini paylaşır ve eşi takım imzasına sabitler (ADR-0004 madde 6, ADR-0005 madde 2). Ama kasa daemon'u `fetchVault` ve `storeVault` ile özel anahtar, preshared key ve wstunnel secret dağıtır; proxy daemon'u yalnız bypass listesi yazar. Takımın imzaladığı ilgisiz bir binary (debug yapısı, test aracı, başka bir ürün) yalnız takım sabitiyle anahtar dağıtım RPC'lerine ulaşabilirdi. Kasa daemon'u artık kimliği de sabitler:

```swift
private static let peerCodeRequirement =
    #"identifier "com.remrearas.Phantom-WG-MacOS" and anchor apple generic and certificate leaf[subject.OU] = "9C5SL5H7CM""#
```

Sabit, çekirdek audit token'ı üzerinden uygulanır ve yarışsızdır. Proxy daemon'u yalnız takım sabitinde kalır, çünkü tehdit modeli farklıdır. Dosyalar: `PhantomTunnel/Infrastructure/TunnelVaultDaemon.swift`, `Extensions/Domain/IPC/ProxyConfigDaemon.swift`.

## Sonuçlar

- Ayarları açmak, tap anında canlı hale gelmiş bir uzantıyı artık öldürmez; `.needsApproval` onay istemi aynı şekilde devam eder.
- ADR-0006'nın "Hiçbir aktivasyon çağrısı ölçümsüz değildir." ilkesi son çağrı noktasını da kapsar.
- Kasa anahtarlarını dağıtan XPC yüzeyi, takımın imzaladığı ilgisiz binary'lere karşı da kapalıdır; duruş ADR-0005'te belgelenenden katıdır.
- İki değişiklik de temelinde kısıtlayıcıdır. Hiçbir akış yeni yetenek kazanmaz, iki yüzey daha az şeye izin verir.

## İlgili Kayıtlar

- ADR-0002 madde 4: davranış cümlesi bu ADR ile daraltıldı.
- ADR-0004 madde 6: proxy eş sabiti; değişmedi, karşıtlık için anılır.
- ADR-0005 madde 2: kasa eş sabiti bu ADR ile sıkılaştırıldı.
- ADR-0006 madde 4: ölçülü aktivasyon; bu ADR ile son çağrı noktasına genişletildi.
