## Phantom-WG Mac {{VERSION}}

---

### 🇺🇸

#### Fixed in this version

- When the app stayed open in the menu bar for hours, it kept re-reading the VPN
  configurations in the background. The work that built up could stall the
  window for seconds when it was opened. This loop is fixed.
- When the window is closed, the app now does no background work. Opening the
  window from the menu bar sets it up again. Tunnels and Split-Tunneling keep
  running in the system extensions.

#### ⚠️ Upgrading from 2.1.2 or earlier

Since 2.1.3, builds are signed by **ARTEK İnovasyon Ar-Ge Sanayi ve Ticaret
Limited Şirketi** (Team ID `GZUHTM7439`). 2.1.2 and earlier were signed under
`9C5SL5H7CM`. The app and its bundle identifiers are unchanged, but macOS
scopes saved tunnels, the tunnel vault keys, the app group container and the
system extension approval to the signing team — none of them carry over.

> The uninstall dialog in 2.1.2 states that configurations and keys come back on
> reinstall. That holds within one signing identity, not across this change.

The Homebrew cask is retired. The last version it offered was 2.1.2, so a copy
installed with Homebrew takes these steps too.

1. Keep the `.conf` file of every tunnel you use, or export it again from your
   server. A key that exists only inside the app cannot be migrated.
2. Disconnect any active tunnel.
3. In 2.1.2 open **Settings → Uninstall System Extensions…**, confirm, then move
   the app to the Trash.
4. Install this version, approve the system extensions when macOS asks, and
   import your configurations again.

If you already moved the old app to the Trash, its extensions are still
registered. Remove them under System Settings → General → Login Items &
Extensions → Network Extensions before installing.

Your server is not affected — re-importing the same `.conf` restores the
connection.

#### Downloads

| Architecture | File |
|---|---|
| Apple Silicon (M1/M2/M3/M4) | `Phantom-WG-MacOS-{{VERSION}}-arm64.dmg` |
| Intel | `Phantom-WG-MacOS-{{VERSION}}-x86_64.dmg` |

#### Installation

1. Download the DMG for your architecture
2. Drag **Phantom-WG Mac** to the **Applications** folder
3. On first launch, approve the system extension:
   - System Settings → General → Login Items & Extensions → Network Extensions
4. Import your tunnel configuration (.conf) and connect

#### Requirements

- macOS 15.1 (Sequoia) or later

---

### 🇹🇷

#### Bu sürümdeki düzeltmeler

- Uygulama menü çubuğunda saatlerce açık kaldığında arka planda VPN
  yapılandırmalarını sürekli yeniden okuyordu. Biriken bu iş, pencere
  açıldığında arayüzün saniyelerce takılmasına yol açabiliyordu. Bu döngü
  giderildi.
- Pencere kapatıldığında uygulama artık arka planda iş yapmıyor. Pencere menü
  çubuğundan yeniden açıldığında baştan kuruluyor. Tüneller ve Split-Tunneling
  sistem uzantılarında çalışmaya devam ediyor.

#### ⚠️ 2.1.2 ve öncesinden yükseltme

2.1.3'ten bu yana sürümler **ARTEK İnovasyon Ar-Ge Sanayi ve Ticaret Limited
Şirketi** adına imzalanıyor (Team ID `GZUHTM7439`). 2.1.2 ve önceki sürümler
`9C5SL5H7CM` ile imzalanmıştı. Uygulama ve paket tanımlayıcıları değişmedi,
ancak macOS kayıtlı tünelleri, tunnel vault anahtarlarını, app group
kapsayıcısını ve sistem uzantısı onayını imzalayan takıma bağlı tutuyor —
hiçbiri taşınmaz.

> 2.1.2'deki kaldırma diyaloğu yapılandırmaların ve anahtarların yeniden
> kurulumda geri geleceğini söyler. Bu, aynı imza kimliği içinde geçerlidir; bu
> değişiklikte geçerli değildir.

Homebrew cask'ı kaldırıldı. Sunduğu son sürüm 2.1.2 olduğu için Homebrew ile
kurulmuş bir kopya da bu adımları izler.

1. Kullandığınız her tünelin `.conf` dosyasını saklayın ya da sunucunuzdan
   yeniden dışa aktarın. Yalnızca uygulamanın içinde duran bir anahtar taşınamaz.
2. Bağlı tünel varsa bağlantıyı kesin.
3. 2.1.2'de **Ayarlar → Sistem Uzantılarını Kaldır…** adımını açıp onaylayın,
   ardından uygulamayı Çöp Kutusu'na taşıyın.
4. Bu sürümü kurun, macOS sorduğunda sistem uzantılarını onaylayın ve
   yapılandırmalarınızı yeniden içe aktarın.

Eski uygulamayı zaten Çöp Kutusu'na taşıdıysanız uzantıları hâlâ kayıtlıdır.
Kurulumdan önce Sistem Ayarları → Genel → Oturum Açma Öğeleri ve Uzantılar →
Ağ Uzantıları altından kaldırın.

Sunucu tarafı etkilenmiyor — aynı `.conf` dosyasını yeniden içe aktarmak
bağlantıyı geri getirir.

#### İndirmeler

| Mimari | Dosya |
|---|---|
| Apple Silicon (M1/M2/M3/M4) | `Phantom-WG-MacOS-{{VERSION}}-arm64.dmg` |
| Intel | `Phantom-WG-MacOS-{{VERSION}}-x86_64.dmg` |

#### Kurulum

1. Mimarinize uygun DMG dosyasını indirin
2. **Phantom-WG Mac** uygulamasını **Applications** klasörüne sürükleyin
3. İlk çalıştırmada sistem uzantısını onaylayın:
   - Sistem Ayarları → Genel → Oturum Açma Öğeleri ve Uzantılar → Ağ Uzantıları
4. Tünel yapılandırmanızı (.conf) içe aktarın ve bağlanın

#### Gereksinimler

- macOS 15.1 (Sequoia) veya üzeri
