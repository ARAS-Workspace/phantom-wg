# Üçüncü Taraf Araç Beyanı

Bu belge, `projects/` dizinindeki ses varlıklarını üretmek için kullanılan
üçüncü taraf araçları ve yazılımları beyan eder. Her projenin `README.md`
dosyası, o kayıt için kullanılan spesifik araç, ön ayar ve konfigürasyonu
içerir. Bu belge, söz konusu araçları yöneten lisans şartları için
merkezi bir referans olarak hizmet eder.

> **Dil notu:** Aşağıda alıntılanan üçüncü taraf lisans metinleri ve
> Mutopia Project tanım metinleri, bağlayıcı niteliklerini koruması için
> orijinal İngilizce halleriyle bırakılmıştır. Çeviri, çevreleyen bağlam
> ve akışla sınırlıdır. İngilizce orijinal sürüm için
> [`DISCLOSURE.md`](./DISCLOSURE.md) dosyasına bakınız.

## Genel Bakış

Bu dizindeki ses varlıkları, Phantom-WG video eğitimlerinde kullanılmak
üzere üretilmiş eğitim arka plan müziği kayıtlarıdır. Her kayıt aşağıdaki
unsurları birleştirir:

- Kamu malı (public domain) statüsünde bir müzik bestesi
- Mutopia Project'ten temin edilen bir MIDI transkripsiyonu
- Logic Pro içinde sanal enstrüman olarak kullanılan Splice INSTRUMENT
  ön ayarları
- Logic Pro içinde alınan üretim kararları (tempo, panlama, ses dengesi,
  ses efektleri, mastering)

Hiçbir canlı performans kaydı, yorumsal insanileştirme veya düzenleme
değişikliği uygulanmamıştır. Kayıtlar, kaynak MIDI dosyalarının seçilmiş
ön ayarlar üzerinden deterministik şekilde çalınmasıdır; karıştırma ve
mastering kararları her proje için ayrıca belgelenmiştir.

## Splice INSTRUMENT

Bu dizindeki kayıtlar, Splice (Distributed Creation Inc., 817 Broadway,
4th Floor, New York, NY 10003) tarafından dağıtılan **Splice INSTRUMENT**
sanal enstrüman eklentisini kullanır. Splice INSTRUMENT ön ayarları,
Logic Pro'da Audio Unit (AU) eklentisi olarak yüklenir ve MIDI
dosyalarını sese dönüştürmek için kullanılır.

### Lisans Şartları

Splice INSTRUMENT ön ayarlarının kullanımı, Splice Terms of Use (Splice
Kullanım Şartları) tarafından düzenlenir. Bölüm 5.3.2 (Usage)
kullanıcılara, Instrument Preset'leri New Recordings ve Creative Works
içinde süresiz (perpetual) olarak kullanma hakkı tanır:

> "Subject to your compliance with the Agreement, we grant you a
> non-exclusive, non-transferable, limited, worldwide, perpetual right to
> perform, display and use/download any Instrument Preset(s), which are
> used in Splice Instrument, solely in New Recordings and/or in Creative
> Works for commercial and non-commercial purposes, except as prohibited
> below. This means that you may modify, publicly perform, distribute,
> transmit, communicate to the public, sublicense and otherwise use the
> Instrument Presets solely as embodied in a New Recording and/or in a
> Creative Work. For the avoidance of doubt, you will not own the
> Instrument Presets." [1]

Bu dizindeki ses kayıtları, söz konusu şartlar kapsamında New Recording
(Yeni Kayıt) olarak değerlendirilir. Her kayıt, bir Instrument Preset'i
bir müzik bestesi (kamu malı bir klasik eser) içine yerleştirir ve bu
sayede "solely as embodied in a New Recording" şartını karşılar.

### Kısıtlamalar

Splice Terms of Use'un Bölüm 5.3.2.1 (Prohibited Uses) maddesindeki
aşağıdaki kısıtlamalar geçerlidir [2]:

- Splice INSTRUMENT ön ayarlarının kendileri bu depoda **yeniden
  dağıtılmamaktadır**. Yalnızca üretilmiş ses çıktıları (`.wav`
  dosyaları) dahil edilmiştir.
- Ses çıktıları, başka eserlerde kaynak materyal olarak yeniden
  dağıtılmak üzere örnek (sample), döngü (loop) veya ses efekti olarak
  yeniden çıkarılamaz.
- Splice INSTRUMENT ön ayarları, bireysel olarak veya yeni paketlerin
  parçası olarak yeniden dağıtılmamaktadır.
- Splice INSTRUMENT ön ayarları, herhangi bir üretken yapay zeka veya
  diğer yapay zeka modelleri için eğitim materyali olarak
  kullanılmamaktadır.
- Splice INSTRUMENT ön ayarlarıyla ilişkili marka veya sanatçıların
  isimleri, görselleri veya benzerlikleri bu kayıtlarla bağlantılı
  olarak kullanılmamıştır.

Yasaklanan kullanımlar maddesinin tam metni aşağıdaki Referanslar
bölümünde yer almaktadır.

### Abonelik Durumu

Splice INSTRUMENT ön ayarlarına, kayıt sırasında aktif bir Splice
aboneliği üzerinden erişilmiştir. Splice Terms of Use'un Bölüm 5.3.2
maddesi uyarınca, Instrument Preset'lerle yapılan üretilmiş kayıtların
New Recordings ve Creative Works içinde kullanım hakkı **süresizdir
(perpetual)** ve abonelik iptalinden sonra da geçerliliğini korur. Bu
nedenle bu dizindeki ses çıktıları, gelecekteki abonelik durumundan
bağımsız olarak kullanılmaya devam edilebilir.

### Kullanılan Ön Ayarlar

Bu dizindeki projelerde aşağıdaki Splice INSTRUMENT ön ayarları
kullanılmıştır:

- **Intimate Grand Piano - Direct**: Belirgin atak karakterine sahip,
  yakın mikrofonlanmış bir kuyruklu piyano. Mevcut tüm kayıtlarda birincil
  sanal enstrüman olarak, hem tiz (sağ el / melodi) hem de bas (sol el /
  eşlik) MIDI parçalarına uygulanmıştır.

Her projenin `README.md` dosyası, o kayıt için kullanılan spesifik ön
ayar konfigürasyonunu belgeler.

## Kaynak MIDI Dosyaları

Bu kayıtlarda girdi olarak kullanılan MIDI dosyaları, kamu malı ve
Creative Commons lisanslı nota ve MIDI dosyalarının kar amacı gütmeyen,
gönüllüler tarafından yürütülen bir deposu olan **Mutopia Project**'ten
(https://www.mutopiaproject.org/) temin edilmiştir. Mutopia Project ana
sayfasında belirtildiği üzere:

> "All of the music on Mutopia may be freely downloaded, printed, copied,
> distributed, modified, performed and recorded. ... Most of our music
> is distributed under Creative Commons licenses. Each piece clearly
> lists what license it is distributed under." [3]

Mutopia Project dosyaları, gönüllüler tarafından kamu malı nota
edisyonlarından LilyPond yazılımı kullanılarak dizilir; ses önizlemeleri
programatik olarak MIDI dosyaları biçiminde üretilir [3]. Her projenin
`README.md` dosyası, kullanılan MIDI kaynağının tam Mutopia URL'sini,
dizici (typesetter) atfını ve lisans rozetini belirtir.

## Besteler

Bu kayıtlarda icra edilen müzik besteleri, ölümleri 70 yıldan daha uzun
süre önce gerçekleşmiş klasik bestecilere ait eserlerdir. Bu besteler,
Avrupa Birliği, Birleşik Krallık, Türkiye ve Amerika Birleşik Devletleri
dahil olmak üzere çoğu yargı bölgesinde kamu malı statüsündedir. Her
projenin `README.md` dosyası, ilgili spesifik besteyi, besteciyi, yayım
yılını ve telif hakkı durumunu belgeler.

## Çıktı Formatı

Tüm ses çıktıları aşağıdaki spesifikasyonlarda üretilmiştir:

- Dosya Formatı: WAV
- Örnekleme Hızı: 48 kHz
- Bit Derinliği: 24-bit
- Kanallar: Stereo

## Beyan Güncellemeleri

Bu beyan, dizine eklenmiş son projenin tarihine kadar kullanılan üçüncü
taraf araçları yansıtır. Yeni araçlar dahil edildiğinde veya mevcut
araçların şartları değiştiğinde, bu beyan buna uygun şekilde
güncellenecektir. Burada referans verilen Splice Terms of Use 29 Eylül
2025 tarihlidir; kullanıcıların güncellemeler için
https://splice.com/terms adresindeki güncel sürüme başvurması önerilir.

## Referanslar

**[1]** Splice Terms of Use, Bölüm II.5.3.2 (Usage), Distributed Creation
Inc. tarafından yayımlanmıştır:

> "Subject to your compliance with the Agreement, we grant you a
> non-exclusive, non-transferable, limited, worldwide, perpetual right to
> perform, display and use/download any Instrument Preset(s), which are
> used in Splice Instrument, solely in New Recordings and/or in Creative
> Works for commercial and non-commercial purposes, except as prohibited
> below. This means that you may modify, publicly perform, distribute,
> transmit, communicate to the public, sublicense and otherwise use the
> Instrument Presets solely as embodied in a New Recording and/or in a
> Creative Work. For the avoidance of doubt, you will not own the
> Instrument Presets."

Kaynak: https://splice.com/terms (Son Güncelleme: 29 Eylül 2025)

**[2]** Splice Terms of Use, Bölüm II.5.3.2.1 (Prohibited Uses):

> "Notwithstanding anything to the contrary and solely with respect to
> Instrument Presets, you may not (a) sublicense the Instrument Presets
> in isolation as sound effects, loops, or as source material for any
> other form of sample (even if you modify the Instrument Presets), (b)
> use or sublicense Instrument Presets in a manner competitive to Splice
> or its licensors, (c) sublicense, sell, loan, share, lend, broadcast,
> rent, lease, assign, distribute, or transfer the Instrument Presets to
> a third party except as incorporated into a New Recording or Creative
> Work as noted above; (d) redistribute Instrument Presets either
> individually and/or in a new pack(s); (e) use any Instrument Presets
> or portions of Instrument Presets identified as made available for
> 'preview' other than to internally and locally (on the Service)
> preview the applicable Instrument Presets (and for the avoidance of
> doubt, 'preview' Instrument Presets may not be modified, reproduced,
> publicly performed, distributed, transmitted, communicated to the
> public, sublicensed, or otherwise used, including for commercial
> purposes); or (f) use the Instrument Presets as source or training
> material for generative or other types of artificial intelligence
> models. Additionally, you may not use the name, image, or likeness of
> any brand and/or artist associated with Instrument Presets in any way."

Kaynak: https://splice.com/terms (Son Güncelleme: 29 Eylül 2025)

**[3]** Mutopia Project, ana sayfa:

> "All of the music on Mutopia may be freely downloaded, printed, copied,
> distributed, modified, performed and recorded. ... Most of our music
> is distributed under Creative Commons licenses. Each piece clearly
> lists what license it is distributed under."

> "These are based on editions in the public domain. A team of
> volunteers typesets the music using LilyPond software. ... Computer-
> generated audio previews of the music are available as MIDI files."

Kaynak: https://www.mutopiaproject.org/