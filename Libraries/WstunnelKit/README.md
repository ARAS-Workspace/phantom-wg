# WstunnelKit

Pre-built universal static library for [wstunnel](https://github.com/ARAS-Workspace/wstunnel) (macOS arm64 + x86_64).

**Source**: Built from the `apple` branch via the [Release macOS workflow](https://github.com/ARAS-Workspace/wstunnel/actions/runs/36175416088), published as [mac-v10.5.2+Phantom.Patch.1](https://github.com/ARAS-Workspace/wstunnel/releases/tag/mac-v10.5.2%2BPhantom.Patch.1). The same details are recorded in `SOURCE`; the licence and the attribution it carries are in `LICENSE` and `NOTICE`.

### Verify checksum

```bash
shasum -a 256 Libraries/WstunnelKit/libwstunnel_apple.a
cat Libraries/WstunnelKit/CHECKSUM.sha256
```

Or in one step:

```bash
(cd Libraries/WstunnelKit && shasum -a 256 -c CHECKSUM.sha256)
```

Expected output:

```
libwstunnel_apple.a: OK
```

The paths inside `CHECKSUM.sha256` are relative to this directory, so `shasum -c` has to run from here; the subshell keeps your own working directory where it was.
