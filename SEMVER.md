# Phantom-WG Semantic Versioning

## Product Versions

| Product               | Description                                   | Branch |
|-----------------------|-----------------------------------------------|--------|
| **Phantom-WG Modern** | Full platform (daemon + SPA + auth + bridges) | main   |

## Version Hierarchy

**Phantom-WG Modern version = Phantom Daemon version.**

The daemon is the central package that defines the product version.
All other components are dependencies with their own independent semver cycles.

```
Phantom-WG Modern vX.Y.Z
  └── Phantom Daemon vX.Y.Z             ← product version source
        ├── auth-service vA.B.C         ← dependency
        ├── wireguard-go-bridge vA.B.C  ← dependency
        ├── firewall-bridge vA.B.C      ← dependency
        ├── react-spa (build artifact)  ← bundled with release
        ├── vendor/linux-{arch}/        ← the two bridges, bundled with release
        └── nginx config                ← bundled with release
```

## Daemon Version (Product Version)

The daemon version follows standard semver and directly maps to the
Phantom-WG Modern release version:

- **Major** — Breaking changes, architectural shifts
- **Minor** — New features, new API endpoints
- **Patch** — Bug fixes, security patches

The daemon version is the single source of truth for the product version.
When a new Phantom-WG Modern release is cut, it carries the daemon version.

### Where it lives

- `phantom_daemon/__init__.py` → `__version__`
- `GET /api/core/hello` → `version` field
- Dashboard status card → displayed to the user

## Dependency Versions

Dependencies maintain their own semver independently. Their versions
change frequently during development. A dependency version bump does
**not** automatically bump the daemon (product) version.

A daemon version bump happens when the integrated product — daemon +
dependencies — reaches a new release milestone.

### Dependencies

| Component               | Versioning           | Branch                  |
|-------------------------|----------------------|-------------------------|
| **auth-service**        | semver               | dev/auth-service        |
| **wireguard-go-bridge** | semver               | dev/wireguard-go-bridge |
| **firewall-bridge**     | semver               | dev/firewall-bridge     |
| **react-spa**           | package.json version | dev/daemon (embedded)   |

### Test Dependencies

Not part of the product and not in the release package. compose-bridge
orchestrates the suites under `e2e_tests/`, which the packager excludes.

| Component            | Versioning | Branch                   |
|----------------------|------------|--------------------------|
| **compose-bridge**   | semver     | dev/tests/compose-bridge |

### Vendor Distribution

Each bridge publishes its own tagged GitHub release, one archive per
architecture:

```
github.com/ARAS-Workspace/phantom-wg/releases/download/
├── vendor-firewall-bridge-v{version}/linux-{arch}.zip
└── vendor-wireguard-go-bridge-v{version}/linux-{arch}.zip
```

There is no `latest` to follow. GitHub's latest-release endpoint answers for
the repository rather than for a component, so every consumer pins a tag. The
daemon pins both versions and the SHA-256 of each archive in `Dockerfile` and
`dev.Dockerfile`; a download that does not match the digest fails the build.

The bridges reach the image two ways:

- **Release package** — the archive carries them under `vendor/linux-{arch}/`,
  written there by the release workflow. The build uses that tree and makes no
  network request.
- **Clone of `main`** — no `vendor/` is present, so the build downloads the
  pinned releases.

