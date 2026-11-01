# firewall-bridge

Linux firewall manager — nftables + policy routing, SQLite state, YAML presets.

- Rust backend talks to the kernel through a netlink socket and the nft program.
- Python layer provides state machine, DB persistence and preset system.

## Download

Each version is a tagged release. Pick one and take its assets:

```
https://github.com/ARAS-Workspace/phantom-wg/releases/download/vendor-firewall-bridge-v<X.Y.Z>/linux-amd64.zip
https://github.com/ARAS-Workspace/phantom-wg/releases/download/vendor-firewall-bridge-v<X.Y.Z>/linux-arm64.zip
```

Each zip extracts to:

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

Releases are listed at [https://github.com/ARAS-Workspace/phantom-wg/releases](https://github.com/ARAS-Workspace/phantom-wg/releases); this component's tags carry the
`vendor-firewall-bridge-` prefix. The version in this branch is in
[`firewall_bridge/__init__.py`](firewall_bridge/__init__.py) (`__version__`).

## Architecture

```mermaid
graph TB
    subgraph Python ["Python — State + API"]
        B[FirewallBridge]
        DB[(SQLite)]
        P[Presets]
        B --> DB
        P --> B
    end

    subgraph Rust ["Rust — Kernel Backend (.so)"]
        NFT[nft.rs<br/>nft process]
        RT[route.rs<br/>netlink socket]
    end

    B -- "ctypes FFI" --> NFT
    B -- "ctypes FFI" --> RT
    NFT --> K[nftables kernel]
    RT --> K2[routing kernel]
```

## Layers

| Layer        | Responsibility                                |
|--------------|-----------------------------------------------|
| `bridge.py`  | State machine, DB CRUD, FFI dispatch          |
| `presets.py` | YAML parse, group create, batch rule apply    |
| `db.py`      | SQLite persistence, migration, WAL mode       |
| `_ffi.py`    | cdylib load, ctypes binding                   |
| `nft.rs`     | nftables chain/rule CRUD — nft process        |
| `route.rs`   | Policy routing + route table — netlink socket |

## Data Flow

```mermaid
sequenceDiagram
    participant App as Application
    participant Bridge as FirewallBridge
    participant DB as SQLite
    participant Rust as Rust FFI (.so)
    participant Kernel as Linux Kernel

    App->>Bridge: apply_preset(yaml)
    Bridge->>DB: create group + rules
    Bridge->>Rust: nft_add_rule(chain, expr)
    Rust->>Kernel: nft -f -
    Bridge->>Rust: rt_policy_add(from, table, family)
    Rust->>Kernel: netlink socket
    Bridge->>DB: mark applied=true
```

## Crash Recovery

```mermaid
sequenceDiagram
    participant Bridge as FirewallBridge
    participant DB as SQLite
    participant Rust as Rust FFI

    Note over Bridge: start() called
    Bridge->>DB: state="stopped"?
    DB-->>Bridge: yes
    Bridge->>Rust: nft_init() — create table from scratch
    Bridge->>DB: read all rules where applied=true
    loop Each rule
        Bridge->>Rust: nft_add_rule / rt_policy_add
    end
    Bridge->>DB: state="running"
```

DB is the source of truth. Kernel state is rebuilt from DB on every start. A daemon restart is sufficient after a crash.

## Preset Structure

```yaml
name: multihop-exit-v6
priority: 80
metadata:
  description: Forward IPv6 traffic wg_main to wg_exit

table:
  - ensure: {id: 201, name: mh6, family: 10}
  - policy: {from: "fd00:10:1::/64", to: "fd00:10:1::/64", table: main, priority: 99, family: 10}
  - policy: {from: "fd00:10:1::/64", table: mh6, priority: 100, family: 10}
  - route:  {destination: default, device: wg_exit, table: mh6, family: 10}

rules:
  - chain: forward
    action: accept
    family: 10
    in_iface: wg_main
    out_iface: wg_exit
  - chain: postrouting
    action: masquerade
    family: 10
    source: "fd00:10:1::/64"
    out_iface: wg_exit
```

`family: 10` = AF_INET6, `family: 2` (default) = AF_INET.

## Dual-Stack IPv6

```mermaid
graph LR
    subgraph Policy Routing
        P99["priority 99<br/>from subnet to subnet → main"]
        P100["priority 100<br/>from subnet → table mh6"]
    end

    subgraph Table mh6
        R1["subnet → wg_main"]
        R2["default → wg_exit"]
    end

    P99 -- "intra-subnet<br/>(client ↔ daemon)" --> MAIN[main table]
    P100 -- "exit traffic" --> R2
```

The priority 99 rule routes intra-subnet traffic (client replies) through the main table. Without it, reply packets would be sent to the exit tunnel.

## Directory Structure

```
firewall-bridge/
├── src/                    # Rust — kernel backend
│   ├── lib.rs              # FFI export, nft context
│   ├── nft.rs              # nftables chain/rule ops
│   ├── route.rs            # netlink policy routing
│   └── error.rs            # error codes
├── include/
│   └── firewall_bridge_linux.h  # C FFI header
├── firewall_bridge/        # Python — state + API
│   ├── __init__.py         # public API, __version__
│   ├── bridge.py           # FirewallBridge state machine
│   ├── db.py               # SQLite persistence + migration
│   ├── models.py           # Group, FirewallRule, RoutingRule
│   ├── presets.py          # YAML preset applicator
│   ├── schema.py           # preset validation
│   ├── _ffi.py             # ctypes bindings
│   ├── types.py            # error types
│   └── schemas/schema.sql  # DB schema
├── tests/                  # Unit tests (Docker SDK runner)
├── e2e_tests/              # E2E tests (compose-bridge)
├── dev/                    # Local dev tools
└── .github/
    ├── workflows/          # CI/CD
    └── scripts/publish.sh  # release publish trigger
```

## Development

```bash
# Rust tests
dev/build.sh && dev/cargo.sh test --lib

# Python unit tests
python tests/runner.py

# E2E tests (compose-bridge required)
bash fetch_compose_bridge.sh
python e2e_tests/runner.py

# Publish (triggers workflow_dispatch)
.github/scripts/publish.sh
```

## Version

Single source of truth: `firewall_bridge/__init__.py` → `__version__`

CI/CD, publish workflow and VERSION file are all derived from this value.

## Package Verification

The zip carries its own hash: `libfirewall_bridge_linux.so.sha256` sits next to the library it
describes, so the package can be checked after extraction without fetching
anything.

```bash
unzip -q linux-amd64.zip
cd firewall_bridge && sha256sum -c libfirewall_bridge_linux.so.sha256
```

The zip itself is attested by the release it came from. GitHub records a
digest for every asset; `gh` prints it:

```bash
gh release view vendor-firewall-bridge-v<X.Y.Z> \\
  --repo ARAS-Workspace/phantom-wg --json assets \\
  --jq '.assets[] | "\\(.name) \\(.digest)"'
```

## License

AGPL-3.0 — [LICENSE](LICENSE) | [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)
