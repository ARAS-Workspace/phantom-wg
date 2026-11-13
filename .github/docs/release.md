## Phantom-WG Modern v{{VERSION}}

### Install

From a git clone, which updates in place:

```bash
git clone --depth 1 --branch main https://github.com/ARAS-Workspace/phantom-wg.git
cd phantom-wg
```

Or from the zip of your architecture, which carries the images and installs
without the registry:

```bash
unzip phantom-wg-modern-v{{VERSION}}-amd64.zip    # or -arm64
cd phantom-wg-modern
```

### Setup

```bash
./tools/prod.sh setup
nano .env.daemon              # set WIREGUARD_ENDPOINT_V4
./tools/prod.sh up
```

- Dashboard: `https://<server-ip>`
- WireGuard: UDP port `51820`

### Update

A git clone updates with:

```bash
./tools/prod.sh update
```

A zip install keeps its version; a new version installs from its own zip.

See [`SETUP`][setup], [`UPDATE`][update] and [`CHANGELOG`][changelog] in the
package.

An install of 1.1.5 moves over with [`MIGRATION`][migration] in the package.

[setup]: https://github.com/ARAS-Workspace/phantom-wg/blob/v{{VERSION}}/SETUP
[update]: https://github.com/ARAS-Workspace/phantom-wg/blob/v{{VERSION}}/UPDATE
[changelog]: https://github.com/ARAS-Workspace/phantom-wg/blob/v{{VERSION}}/CHANGELOG
[migration]: https://github.com/ARAS-Workspace/phantom-wg/blob/v{{VERSION}}/MIGRATION
