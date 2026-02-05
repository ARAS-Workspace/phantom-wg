## Factory Reset

Phantom-WG'yi ilk kurulum durumuna geri döndürmek için bağımsız factory reset
betiği kullanılır. Bu işlem API üzerinden değil, doğrudan sunucuda çalıştırılan bir
betikle gerçekleştirilir:

```bash
/opt/phantom-wg/phantom/factory-reset.sh
```

Bu betik sırasıyla şu işlemleri gerçekleştirir:

- Tüm aktif servisleri durdurur (Ghost Mode, Multihop, WireGuard)
- Tüm istemci yapılandırmalarını ve anahtar bilgilerini siler
- Tüm günlükleri, durum dosyalarını ve oturum verilerini kaldırır
- Yeni sunucu anahtar çifti üretir
- Sistemi ilk kurulum durumuna sıfırlar
- SSH port yapılandırmasını korur (sunucuya erişiminiz kesilmez)

**Uyarı:** Bu geri döndürülemeyen bir işlemdir. Yedekleme yapılmaz ve tüm veriler
kalıcı olarak silinir. Factory reset yalnızca sistemi tamamen sıfırlamak
istediğinizde kullanılmalıdır.
