# wireguard-go-bridge

Userspace WireGuard — Go backend, SQLite IPC state persistence, Python FFI.

- Go backend: wireguard-go TUN device + IPC protocol, her state değişikliği SQLite'a persist edilir.
- Python katmanı: ctypes FFI binding, key generation, bridge lifecycle.
- Kernel modülü gerektirmez — tamamen userspace.

## İndirme

Son sürüm:

```
https://vendor.phantom.tc/wireguard-go-bridge/latest/linux-amd64.zip
https://vendor.phantom.tc/wireguard-go-bridge/latest/linux-arm64.zip
```

Her zip şu yapıya açılır:

```
wireguard_go_bridge/
├── __init__.py
├── _ffi.py
├── bridge.py
├── keys.py
├── types.py
├── wireguard_go_bridge.so
├── wireguard_go_bridge.so.sha256
└── VERSION
```

Belirli bir sürüm için: `latest/` yerine `v<X.Y.Z>/` kullan. Mevcut
sürüm [`wireguard_go_bridge/__init__.py`](wireguard_go_bridge/__init__.py)
içinde (`__version__`).

## Mimari

```mermaid
graph TB
    subgraph Python ["Python — FFI"]
        WB[WireGuardBridge]
        K[keys.py]
    end

    subgraph Go ["Go — WireGuard Backend (.so)"]
        PD[PersistentDevice]
        KG[core/keys.go]
        DB[(SQLite)]
        WG[wireguard-go<br/>TUN + IPC]
    end

    WB -- "ctypes FFI" --> PD
    K -- "ctypes FFI" --> KG
    PD --> DB
    PD --> WG
    WG --> TUN["/dev/net/tun"]
```

## Veritabanı

Go backend SQLite'a tek tablo ile state persist eder:

```sql
CREATE TABLE IF NOT EXISTS ipc_state (
    id    INTEGER PRIMARY KEY CHECK (id = 1),
    dump  TEXT NOT NULL
);
```

`dump` kolonu WireGuard IPC protocol formatında tam device state'i tutar (private key, listen port, peer'lar). Her `ipc_set` çağrısında üzerine yazılır, `restore()` ile geri yüklenir.

## Katmanlar

| Katman                 | Sorumluluk                                                   |
|------------------------|--------------------------------------------------------------|
| `bridge.py`            | WireGuardBridge lifecycle — create, ipc_set, up, down, close |
| `keys.py`              | Key generation — private, public, preshared, hex↔base64      |
| `_ffi.py`              | cdylib load, ctypes binding                                  |
| `types.py`             | Error types                                                  |
| `persistent_device.go` | WireGuard device + automatic IPC state persistence           |
| `exports.go`           | C FFI export layer — public API surface                      |
| `core/keys.go`         | Curve25519 key generation                                    |
| `core/registry.go`     | Handle registry — device handle management                   |

## Yükleme

```python
from wireguard_go_bridge import WireGuardBridge

bridge = WireGuardBridge(
    ifname="wg_phantom_main",
    mtu=1420,
    db_path="/var/lib/phantom/state/db/wireguard/wg_phantom_main/device.db",
)
```

## IPC Konfigürasyon Formatı (UAPI)

```text
private_key={hex}
listen_port={int}
replace_peers=true
public_key={hex}
preshared_key={hex}
allowed_ip={ipv4}/32
allowed_ip={ipv6}/128
persistent_keepalive_interval={int}
```

## Anahtar Üretimi

```python
from wireguard_go_bridge.keys import (
    generate_private_key,
    derive_public_key,
    generate_preshared_key,
)

private = generate_private_key()       # Curve25519 (hex)
public  = derive_public_key(private)   # Public key (hex)
psk     = generate_preshared_key()     # PSK (hex)
```

## Hata Türleri

| Exception           | Durum                            |
|---------------------|----------------------------------|
| `BridgeError`       | Temel hata sınıfı                |
| `TunCreateError`    | TUN arayüz oluşturma hatası      |
| `DeviceCreateError` | Cihaz oluşturma hatası           |
| `IpcError`          | IPC iletişim hatası              |
| `DeviceUpError`     | Arayüz etkinleştirme hatası      |
| `DeviceDownError`   | Arayüz devre dışı bırakma hatası |

## State Persistence

```mermaid
sequenceDiagram
    participant App as Uygulama
    participant Bridge as WireGuardBridge
    participant Go as Go FFI (.so)
    participant DB as SQLite
    participant TUN as /dev/net/tun

    App->>Bridge: WireGuardBridge(ifname, mtu, db_path)
    Bridge->>Go: DeviceCreate(ifname, mtu, db_path)
    Go->>TUN: TUN device oluştur
    Go->>DB: Önceki state var mı?
    DB-->>Go: evet → IPC state restore
    Go-->>Bridge: handle

    App->>Bridge: ipc_set(config)
    Bridge->>Go: DeviceIpcSet(handle, config)
    Go->>Go: WireGuard IPC uygula
    Go->>DB: Tüm device state persist
```

## Lifecycle

```mermaid
flowchart
    A["WireGuardBridge()"] --> B["up()"]
    B --> C["ipc_set / ipc_get"]
    C --> D["down()"]
    D --> E["close()"]
```

## Dizin Yapısı

```
wireguard-go-bridge/
├── src/                        # Go — WireGuard backend
│   ├── main.go                 # cgo entry
│   ├── exports.go              # C FFI exports
│   ├── persistent_device.go    # Device + SQLite persistence
│   ├── handle_registry.go      # Device handle management
│   ├── errors.go               # Error codes
│   ├── version.go              # BridgeVersionStr
│   ├── wireguard_go_bridge.h   # C FFI header
│   └── core/
│       ├── keys.go             # Curve25519 key ops
│       └── registry.go         # Handle registry
├── wireguard_go_bridge/        # Python — FFI + keys
│   ├── __init__.py             # public API, __version__
│   ├── bridge.py               # WireGuardBridge wrapper
│   ├── keys.py                 # Key generation utilities
│   ├── _ffi.py                 # ctypes bindings
│   └── types.py                # error types
├── tests/                      # Unit + integration tests
└── .github/
    ├── workflows/              # CI/CD
    └── scripts/publish.sh      # R2 publish trigger
```

## Geliştirme

```bash
# Test (Docker container içinde Go build + pytest)
python test_runner.py

# Publish (workflow_dispatch tetikler)
.github/scripts/publish.sh
```

## Versiyon

Tek kaynak: `wireguard_go_bridge/__init__.py` → `__version__`

Go tarafı: `src/version.go` → `BridgeVersionStr` (publish'te eşleşme validasyonu yapılır).

## Paket Doğrulama

Vendor paketleri R2'den (`vendor.phantom.tc`) sunulur. Güven kökü ise
burada, branch üzerindedir: [CHECKSUMS](CHECKSUMS) dosyasını her
yayından sonra yalnızca publish workflow'u yazar. Artefakt ile
beklenen hash iki bağımsız kanaldan gelir; kurcalanmış bir indirme
kendi kendini yeniden onaylayamaz.

```bash
#!/usr/bin/env bash
# verify.sh — vendor paketlerini branch'teki güven köküne karşı doğrula
set -euo pipefail

BASE="https://vendor.phantom.tc/wireguard-go-bridge"
TRUST="https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/refs/heads/dev/wireguard-go-bridge/CHECKSUMS"

VERSION=$(curl -fsSL "${BASE}/latest/VERSION")
CHECKSUMS=$(curl -fsSL "${TRUST}")

for ARCH in linux-amd64 linux-arm64; do
  curl -fsSL -o "${ARCH}.zip" "${BASE}/${VERSION}/${ARCH}.zip"
  EXPECTED=$(printf '%s\n' "${CHECKSUMS}" | grep -- "- ${ARCH}.zip/" | cut -d'/' -f2)
  ACTUAL=$(sha256sum "${ARCH}.zip" | cut -d' ' -f1)
  if [ "${EXPECTED}" = "${ACTUAL}" ]; then
    echo "OK   ${ARCH}.zip ${VERSION} (${ACTUAL})"
  else
    echo "FAIL ${ARCH}.zip — beklenen ${EXPECTED}, gelen ${ACTUAL}" >&2
    exit 1
  fi
done
```

`CHECKSUMS` her zaman yalnızca güncel sürümü tarif eder; eski sürümler
dosyanın git geçmişi üzerinden doğrulanabilir kalır.

## Lisans

AGPL-3.0 — [LICENSE](LICENSE) | [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)
