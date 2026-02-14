# WstunnelKit

Pre-built static library for [wstunnel](https://github.com/ARAS-Workspace/wstunnel) (macOS arm64 / Apple Silicon).

**Source**: Built from the `mac/v10.5.2` branch via the [macOS Static Library workflow](https://github.com/ARAS-Workspace/wstunnel/actions/runs/22015722890).

### Verify checksum

```bash
shasum -a 256 Libraries/WstunnelKit/libwstunnel_mac.a
cat Libraries/WstunnelKit/CHECKSUM.sha256
```

Or in one step:

```bash
shasum -a 256 -c Libraries/WstunnelKit/CHECKSUM.sha256
```

Expected output: `libwstunnel_mac.a: OK`
