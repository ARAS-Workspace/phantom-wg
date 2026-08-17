# ADR-0008 — Custody Kararları Eylem Anında Verilir

## Durum

Kabul Edildi — 2026-08-15

Bu bir **uzantı kaydıdır**: [ADR-0001 Madde 5](0001-architectural-decision-records.md#karar)'in tarif ettiği yolla, kabul edilmiş bir kaydı daraltır. Genişlettiği kayıt ADR-0005'tir. Custody yolundaki üç sertleştirmeyi toplar; hiçbiri bir kararı tersine çevirmez. Üçünün tek öncülü vardır: bir payload hakkındaki karar, daha önce alınmış bir cevaba göre değil, eylem anında depoların söylediğine göre verilir.

- Fix: the duplicate purge drops orphans only, and a restore proves, marks and re-checks each candidate at the moment it mints ([365bc45](https://github.com/ARAS-Workspace/phantom-wg/commit/365bc4580221eb06a848d3e7c8636f97620517d2))

- Fix: a vault the harness can make answer one thing in bulk and another per id, and seven custody steps that spend it ([27e754a](https://github.com/ARAS-Workspace/phantom-wg/commit/27e754ae0cb9fc2d7ca2f959c62e43307b56b398))

## Bağlam

**Genişletilen kayıt:** [ADR-0005 Sistem Keychain Tünel Kasası](0005-system-keychain-tunnel-vault.md); ilgili bölümler [Karar](0005-system-keychain-tunnel-vault.md#karar) ve [Sınır Durumları](0005-system-keychain-tunnel-vault.md#sınır-durumları).

**Kaynak:** `Phantom-WG-MacOS/Infrastructure/Tunnel/TunnelsManager.swift`, commit [`365bc45`](https://github.com/ARAS-Workspace/phantom-wg/commit/365bc4580221eb06a848d3e7c8636f97620517d2) ve [`27e754a`](https://github.com/ARAS-Workspace/phantom-wg/commit/27e754ae0cb9fc2d7ca2f959c62e43307b56b398).

Bu belge ADR-0005'i yeniden anlatmaz. Üç maddesinin bağını daraltır ve tablosuna bir satır ekler. 

### Daraltılan Maddeler

| ADR-0005 | Bugüne kadarki bağ | Bu kararla artık | Kaynak |
| --- | --- | --- | --- |
| **Madde 12** Ad tekilliği yazma anında zorlanır | Kasa yazımı, aynı adı taşıyan **başka** her payload kaydını düşürür; ad çakışmasının doğabileceği tek yol budur ve kapalıdır | Yazma yalnız **orphan** kaydı düşürür: kimliği listede olan ya da uçuşta işaretli olan kayıt korunur ve yazma sürer. | `purgeVaultDuplicates` |
| **Madde 8** Reconcile üç görev taşır ve kasada yakınsar | Sistem girdisi olmayan bir payload yeniden yaratılır; kanıt, geçişin başındaki toplu okumadır. | Her aday **basılacağı anda** id ile yeniden okunur ve girdi **taze okunan gövdeden** yaratılır. İki liste sınaması basmanın hemen önünde, eşzamanlı olarak alınır. Cevap vermeyen kasa, geçişin kalanında basmayı durdurur. | `reconcileFromVault` |
| **Madde 11** Sıra garantileri (uçuş işareti) | İşaretin bir yazıcısı (ekleme) ve bir okuyucusu (reconcile) vardır | İşaretin **ikinci bir yazıcısı** vardır: reconcile'ın kendisi, tek tek adayları değil aday kümesinin tamamını işaretler. **İkinci bir okuyucusu** vardır: tekilleştirme | `creatingIds` |

Üç daraltmanın gerekçesi tek cümlede: bekçiler LİSTENİN adlarını, tekilleştirme KASANIN adlarını okur ve iki depo, geri sarılan bir yazmadan sonra kendiliğinden ayrışır; ayrıştıklarında canlı bir tünelin kaydı orphan gibi, silinmiş bir payload ise geri kurulacak bir aday gibi görünür.

### Sınır Durumları Tablosuna İşlenecekler

Aşağıdakiler ADR-0005'in [Sınır Durumları](0005-system-keychain-tunnel-vault.md#sınır-durumları) tablosuna aittir. Tablo değiştirilmez; bu kararla beraber artık şöyle okunur.

**Değişen iki satır:**

| Mevcut satır | Bugüne kadarki hüküm | Bu kararla artık |
| --- | --- | --- |
| Bir payload'ın adı listelenmiş bir tünelle çakışıyor | "Kurulamayan bir sahnenin son savunması" | Sahne kurulabilir olduğu için savunma kalıntı değil canlıdır: korunan kayıt yüzünden kasa aynı adı taşıyan iki kayıt tutabilir ve atlama davranışı o durumu atıl tutan şeydir. |
| **TunnelVault** içe aktarma anında cevapsız | "Ad çakışması doğamaz" | İçe aktarma hâlâ reddedilir, ancak bu yol çakışmanın tek yolu değildir: bir kaydın korunması da aynı adı taşıyan iki kayıt bırakabilir. |

**Eklenecek satırlar:**

| Durum | Davranış | Değerlendirme |
| --- | --- | --- |
| Bir yazma, kimliği listede olan ya da kurulmakta olan bir payload'ın adını istiyor | Kayıt korunur, yazma sürer | Canlı bir anahtarın tek kopyası silinmez |
| Bir geri kurma adayının payload'ı geçiş sürerken siliniyor | O aday basılmaz | Sırrı çoktan gitmiş girdi doğmaz |
| Geri kurma sırasında kasa karanlığa düşüyor | Geçişin kalanında basma durur | Kanıtsız basma yoktur |
| Bir payload'ın gövdesindeki id, okunduğu anahtarla çelişiyor | Custody anomalisi sayılır ve reddedilir | Normalize edilmez, çünkü uygulamanın yazdığı hiçbir şey bunu üretemez |

## Karar

Bir custody kararı, eylem anında güncel olan kanıta göre verilir; girdisi yolda olan ya da uçuştaki bir geçişin hakkında karar verdiği bir payload ise, diğer yol görebilsin diye işaretlenir. Somut olarak:

1. **Yazma anındaki tekilleştirme yalnız orphan kayıtları siler.** Kimliği listede olan ya da uçuşta işaretli olan kayıt korunur. Bir durum tasarım gereği kapsam dışıdır: girdisi duran ama listenin o anda tutmadığı tünel. Kapsamak her yazmaya bir sistem gidiş dönüşü eklerdi ve o durum gizli girdi sınıfına aittir.

2. **Geri kurma her adayı basacağı anda id ile kanıtlar**, snapshot'a değil o cevaba göre davranır ve girdiyi taze okunan gövdeden yaratır; sonda da bir askı olduğu için canlı listeyi basmayla aynı nefeste bir kez daha okur. Okuma tek denemeliktir: yeniden deneyen değişken karanlık kasada aday başına yaklaşık 16.8 saniyeyi reconcile kilidini tutarak harcardı. İzdüşüm hizalaması, geçişin basmaya ulaştığı her kimliği dışarıda bırakır; indiyse satır zaten geçişin en taze okumasından yazılmıştır, inmediyse geçişin sahiplenemediği taze adın üstüne bayat ad yazılırdı.

3. **Bir reconcile geçişi aday kümesinin tamamını uçuşta işaretler**, adaylığın belirlendiği satırdan geçiş bitene kadar. Tek tek işaretlemek yetmez, çünkü eldeki adayın arkasındaki her aday, önündeki kuyruk boyunca liste satırı olmayan bir payload'dır ve tekilleştirme tam olarak o şekli orphan okur.

Üçünün hiçbiri sırların nerede durduğuna, sahiplik sınırına ya da el sıkışması koşuluna dokunmaz. Yalnızca, biri eylem ortasındayken diğerinin bir payload üzerinde ne yapmasına izin verildiğini değiştirirler.

## Sonuçlar

- Aynı adla yapılan bir içe aktarma, canlı ya da yolda olan bir tünelin anahtarının tek kopyasını artık silemez. Üç sertleştirmenin var oluş sebebi bu sınıftır.
- Geri kurma, sırrı çoktan silinmiş bir girdiyi asla basmaz; görünmez ve silinemez girdi bu yolda artık doğamaz.
- Kasa aynı adı taşıyan iki kayıt tutabilir. Hiçbir katman bu kopyanın üzerine işlem yapmaz ve listeye ulaşan tek durumu kullanıcı görüp geri alabilir.
- Geri kurma adayı başına bir ek kasa okuması; olağan durumda sıfır, karanlık kasada ise aday başına değil geçiş başına tek zaman aşımı.
- Bir durum tasarım gereği açık kalır: girdisi duran ama listenin o anda tutmadığı tünel. Gizli girdinin kendisiyle aynı sınıfa aittir ve onunla birlikte kayıtlıdır.
- Üç değişiklik de temelinde kısıtlayıcıdır. Hiçbir akış yeni yetenek kazanmaz; yazma yolu daha az siler, geri kurma yolu daha az basar.

## İlgili Kayıtlar

- [ADR-0005](0005-system-keychain-tunnel-vault.md) madde 8, 11 ve 12: yukarıdaki tabloda daraltıldı.
- [ADR-0005](0005-system-keychain-tunnel-vault.md) madde 6 ve 9: sahiplik sınırı ve "ne sessizlik ne de başarısız cevap kanıt sayılır" kuralı; değişmedi, ikisi de bu kaydın taşıyıcısıdır. Madde 9 bir okuma için üç sonuç adlandırır; buradaki per-id sonda dört değere dallanır ve dördüncüsü, ADR-0005'in madde 9'da değil kenar durum tablosunda raporladığı "var ama okunamayan" payload'dır.
- [ADR-0001](0001-architectural-decision-records.md) madde 5: bu kaydın var olma biçimi; kabul edilmiş bir ADR düzeltme için oyulmaz, daraltan yeni bir kayıt açılır.
- [ADR-0007](0007-activation-and-vault-hardening.md): hardening işlemleri için bu şekli kuran kayıt.
