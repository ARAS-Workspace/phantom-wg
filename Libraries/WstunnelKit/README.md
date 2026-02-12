# WstunnelKit

## 🇺🇸

Pre-built static library for [wstunnel](https://github.com/ARAS-Workspace/wstunnel) (iOS arm64).

**Source**: Built from the `ios/v10.5.2` branch via the [iOS Static Library workflow](https://github.com/ARAS-Workspace/wstunnel/actions/runs/21937285430).

### Verify checksum

```bash
shasum -a 256 Libraries/WstunnelKit/libwstunnel_ios.a
cat Libraries/WstunnelKit/CHECKSUM.sha256
```

Or in one step:

```bash
shasum -a 256 -c Libraries/WstunnelKit/CHECKSUM.sha256
```

Expected output: `Libraries/WstunnelKit/libwstunnel_ios.a: OK`

---

## 🇹🇷

[wstunnel](https://github.com/ARAS-Workspace/wstunnel) icin onceden derlenimis statik kutuphane (iOS arm64).

**Kaynak**: `ios/v10.5.2` branch'inden [iOS Static Library workflow](https://github.com/ARAS-Workspace/wstunnel/actions/runs/21937285430) ile uretilmistir.

### Checksum dogrulama

```bash
shasum -a 256 Libraries/WstunnelKit/libwstunnel_ios.a
cat Libraries/WstunnelKit/CHECKSUM.sha256
```

Tek komutla dogrulama:

```bash
shasum -a 256 -c Libraries/WstunnelKit/CHECKSUM.sha256
```

Beklenen cikti: `Libraries/WstunnelKit/libwstunnel_ios.a: OK`