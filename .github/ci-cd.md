# CI/CD — firewall-bridge

## Workflows

| Workflow                      | Trigger                                    | Jobs                                     | Output                         |
|-------------------------------|--------------------------------------------|------------------------------------------|--------------------------------|
| `test-firewall-bridge.yml`    | push (`.github/` ignored), `workflow_call` | `test-rust`, `test-python`, `e2e`        | —                              |
| `build-firewall-bridge.yml`   | push (`.github/` ignored), `workflow_call` | `build-linux-amd64`, `build-linux-arm64` | .so + .h + .sha256 artifacts   |
| `publish-firewall-bridge.yml` | `workflow_dispatch`                        | `version` → `test` → `build` → `publish` | tagged release + zip assets    |

## Flow

```
Branch push (dev/firewall-bridge, .github/ ignored):
  ├── test-firewall-bridge.yml
  │     ├── test-rust      (Docker cargo test)
  │     ├── test-python    (Docker SDK unit runner)
  │     └── e2e            (compose-bridge multihop v4/v6)
  └── build-firewall-bridge.yml
        ├── build-linux-amd64  (ubuntu-latest)
        └── build-linux-arm64  (ubuntu-24.04-arm)

Publish (workflow_dispatch):
  └── publish-firewall-bridge.yml
        ├── version   (extract from firewall_bridge/__init__.py)
        ├── test      (workflow_call → test-firewall-bridge.yml)
        ├── build     (workflow_call → build-firewall-bridge.yml)
        └── publish   (ubuntu-latest, gh release create)
```

## Version

Two sources, kept in sync:

| Side   | Location                      | Symbol              |
|--------|-------------------------------|---------------------|
| Python | `firewall_bridge/__init__.py` | `__version__`       |
| Rust   | `Cargo.toml`                  | `[package] version` |

The publish workflow extracts the Python value, validates that the
Cargo value matches, and aborts on mismatch.

`Cargo.lock` carries the same version under the `firewall-bridge-linux`
package entry — `bump.sh` updates it alongside the other two.

## Bump

```bash
.github/scripts/bump.sh [major|minor|patch]
```

Defaults to `patch`. Updates `__init__.py`, `Cargo.toml`, and
`Cargo.lock` atomically. Refuses to run if the three sources are out
of sync.

## Publish

```bash
.github/scripts/publish.sh
```

No arguments — version is read from source. Triggers
`publish-firewall-bridge.yml` via `workflow_dispatch`.

## Artifacts

| Name                          | Contents                                         | Retention |
|-------------------------------|--------------------------------------------------|-----------|
| `firewall-bridge-linux-amd64` | .so, .h, .sha256, firewall_bridge/*.py, schemas/ | 90 days   |
| `firewall-bridge-linux-arm64` | .so, .h, .sha256, firewall_bridge/*.py, schemas/ | 90 days   |

## Release

Tag: `vendor-firewall-bridge-v<VERSION>` — target: the commit the run built

Assets:

```
linux-amd64.zip
linux-arm64.zip
```

Each zip contains:

```
firewall_bridge/
├── __init__.py
├── _ffi.py
├── bridge.py
├── db.py
├── models.py
├── presets.py
├── schema.py
├── types.py
├── schemas/
│   └── schema.sql
├── libfirewall_bridge_linux.so
├── libfirewall_bridge_linux.so.sha256
├── firewall_bridge_linux.h
├── VERSION
├── LICENSE
└── THIRD_PARTY_LICENSES
```

Download:

```
https://github.com/ARAS-Workspace/phantom-wg/releases/download/vendor-firewall-bridge-v<VERSION>/linux-amd64.zip
```

## Notes

- `.github/` changes do not trigger test/build on push (paths-ignore)
- Publish runs on ubuntu-latest; its only credential is GITHUB_TOKEN
- No moving "latest" pointer: this repository holds several components and
  GitHub's `/releases/latest` answers for the repository, so consumers pin a tag
- VERSION file inside zip for runtime version verification
- Release notes link to the CHANGELOG on this branch
