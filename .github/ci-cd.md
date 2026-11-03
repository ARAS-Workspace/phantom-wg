# CI/CD — wireguard-go-bridge

## Workflows

| Workflow                          | Trigger               | Jobs                                                  | Output                       |
|-----------------------------------|-----------------------|-------------------------------------------------------|------------------------------|
| `test-wireguard-go-bridge.yml`    | push, `workflow_call` | `test-go` (go test), `test` (Docker unit+integration) | test-results artifact        |
| `build-wireguard-go-bridge.yml`   | push, `workflow_call` | `build-linux-amd64`, `build-linux-arm64`              | .so + .h + .sha256 artifacts |
| `publish-wireguard-go-bridge.yml` | `workflow_dispatch`   | `version`, `test` → `build`; `publish` after both     | tagged release + zip assets  |

## Flow

```
Branch push (dev/wireguard-go-bridge):
  ├── test-wireguard-go-bridge.yml   (go test -race in golang:<GO_VERSION>-trixie;
  │                                   unit + integration via test_runner.py)
  └── build-wireguard-go-bridge.yml  (amd64 on ubuntu-26.04, arm64 on ubuntu-26.04-arm,
                                      each in golang:<GO_VERSION>-trixie as the
                                      runner's user → artifact upload)

Publish (workflow_dispatch):
  └── publish-wireguard-go-bridge.yml
        ├── version   (extract from wireguard_go_bridge/__init__.py)
        ├── test      (workflow_call → test-wireguard-go-bridge.yml, alongside version)
        ├── build     (workflow_call → build-wireguard-go-bridge.yml, after test)
        └── publish   (ubuntu-26.04, gh release create, or upload --clobber on a
                       re-run of a released version; after version and build)
```

## Version

Two sources, kept in sync:

| Side   | Location                          | Symbol             |
|--------|-----------------------------------|--------------------|
| Python | `wireguard_go_bridge/__init__.py` | `__version__`      |
| Go     | `src/version.go`                  | `BridgeVersionStr` |

The publish workflow extracts the Python value and validates that the Go
value matches; a mismatch fails the `version` job, and `publish` does not
run.

## Bump

```bash
.github/scripts/bump.sh [major|minor|patch]
```

Defaults to `patch`. Updates both version sources atomically and creates
a single `Bump v<VERSION>` commit. Refuses to run if the two sources
are already out of sync.

## Publish

```bash
.github/scripts/publish.sh
```

No arguments — version is read from source. Triggers
`publish-wireguard-go-bridge.yml` via `workflow_dispatch`.

## Artifacts

| Name                              | Contents                | Retention |
|-----------------------------------|-------------------------|-----------|
| `test-results`                    | pytest output, coverage | 30 days   |
| `wireguard-go-bridge-linux-amd64` | .so, cgo's .h, .sha256  | 90 days   |
| `wireguard-go-bridge-linux-arm64` | .so, cgo's .h, .sha256  | 90 days   |

## Release

Tag: `vendor-wireguard-go-bridge-v<VERSION>` — target: `dev/wireguard-go-bridge`

Assets:

```
linux-amd64.zip
linux-arm64.zip
```

Each zip contains:

```
wireguard_go_bridge/
├── __init__.py
├── _ffi.py
├── bridge.py
├── keys.py
├── types.py
├── wireguard_go_bridge.so
├── wireguard_go_bridge.so.sha256
├── VERSION
├── LICENSE
├── THIRD_PARTY_LICENSES
└── licenses/
```

Download:

```
https://github.com/ARAS-Workspace/phantom-wg/releases/download/vendor-wireguard-go-bridge-v<VERSION>/linux-amd64.zip
```

## Notes

- No moving "latest" pointer: this repository holds several components and
  GitHub's `/releases/latest` answers for the repository, so consumers pin a tag
- VERSION file inside zip for runtime version verification
- Release notes link to the CHANGELOG on this branch
