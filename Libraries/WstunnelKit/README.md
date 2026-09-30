# WstunnelKit

Pre-built XCFramework for [wstunnel](https://github.com/ARAS-Workspace/wstunnel) (iOS arm64 + arm64 simulator).

**Source**: Built from the `apple` branch via the [Release iOS workflow](https://github.com/ARAS-Workspace/wstunnel/actions/runs/36175429677), published as [ios-v10.5.2+Phantom.Patch.1](https://github.com/ARAS-Workspace/wstunnel/releases/tag/ios-v10.5.2%2BPhantom.Patch.1). The same details are recorded in `SOURCE`; the licence and the attribution it carries are in `LICENSE` and `NOTICE`.

### Verify checksum

```bash
shasum -a 256 Libraries/WstunnelKit/WstunnelKit.xcframework/*/libwstunnel_apple.a
cat Libraries/WstunnelKit/CHECKSUM.sha256
```

Or in one step:

```bash
(cd Libraries/WstunnelKit && shasum -a 256 -c CHECKSUM.sha256)
```

Expected output:

```
WstunnelKit.xcframework/ios-arm64/libwstunnel_apple.a: OK
WstunnelKit.xcframework/ios-arm64-simulator/libwstunnel_apple.a: OK
```

The paths inside `CHECKSUM.sha256` are relative to this directory, so `shasum -c` has to run from here; the subshell keeps your own working directory where it was.
