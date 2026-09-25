# WstunnelKit

Pre-built universal static library for [wstunnel](https://github.com/ARAS-Workspace/wstunnel) (macOS arm64 + x86_64).

**Source**: Built from the `apple` branch via the [Release macOS workflow](https://github.com/ARAS-Workspace/wstunnel/actions/runs/36175416088), published as [mac-v10.5.2+Phantom.Patch.1](https://github.com/ARAS-Workspace/wstunnel/releases/tag/mac-v10.5.2%2BPhantom.Patch.1).

### Verify checksum

```bash
shasum -a 256 Libraries/WstunnelKit/libwstunnel_apple.a
cat Libraries/WstunnelKit/CHECKSUM.sha256
```

Or in one step:

```bash
shasum -a 256 -c Libraries/WstunnelKit/CHECKSUM.sha256
```

Expected output: `libwstunnel_apple.a: OK`
