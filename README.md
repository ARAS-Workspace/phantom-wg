# Phantom-WG

[![Release Workflow](https://github.com/ARAS-Workspace/phantom-wg/actions/workflows/release-workflow.yml/badge.svg)](https://github.com/ARAS-Workspace/phantom-wg/actions/workflows/release-workflow.yml)

```bash
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
```

**Your Server. Your Network. Your Privacy.**

Phantom-WG is a modular tool for setting up and managing WireGuard VPN
infrastructure on your own server. Beyond basic VPN management, it provides
censorship-resistant connections, multi-layer encryption, and advanced privacy scenarios.

🌎 **https://www.phantom.tc**

📰 **https://docs.phantom.tc**

---

## Quick Start

### Requirements

**Server:**
- A server with internet access, a public IPv4 address, and a supported operating system
- Root access

**Operating System:**
- Debian 12, 13
- Ubuntu 22.04, 24.04

> **Resource Usage:** WireGuard runs as a kernel module, consuming minimal system resources.
> For detailed performance information, see [WireGuard Performance](https://www.wireguard.com/performance/).

### Installation

```bash
curl -sSL https://install.phantom.tc | bash
```

![Installation](assets/recordings/installation-dark.gif#gh-dark-mode-only)
![Installation](assets/recordings/installation-light.gif#gh-light-mode-only)

> `install.phantom.tc` is a Cloudflare Worker maintained entirely from this GitHub repository and deployed via GitHub Actions. It does not perform any data collection, telemetry, or logging. For details, see the [Privacy Notice](tools/phantom-install/PRIVACY.md).

### Post-Installation

Upon successful installation, you will see the following output:

```
========================================
   PHANTOM-WG INSTALLED!
========================================

Commands:
  phantom-wg - Interactive UI
  phantom-api       - API access

Quick Start:
  1. Run: phantom-wg
  2. Select 'Core Management'
  3. Add your first client

API Example:
  phantom-api core list_clients
```

---

## Scenarios

### Core - Central Management

Client management, cryptographic key generation, automatic IP allocation, and service
control are managed from a single interface.

![Core Flow](documentation/docs/assets/static/images/index/flow-diagrams/connection-flow-core.svg)

**Key Features:**
- Add/remove clients and share configurations via QR code
- Server status and connection statistics
- Firewall management
- Subnet changes and IP remapping

> **Detailed Usage:** [API Documentation - Core Module](phantom/bin/docs/API.md#core-module)

---

### Multihop - Dual VPN Layer

Chain your traffic through external WireGuard servers. Create a dual encryption
layer using your own servers or commercial VPN providers.

![Multihop Flow](documentation/docs/assets/static/images/index/flow-diagrams/connection-flow-multihop.svg)

**Key Features:**
- Import any WireGuard configuration file
- Automatic routing rules and NAT configuration
- Connection monitoring and automatic reconnection
- VPN connection tests

> **Detailed Usage:** [API Documentation - Multihop Module](phantom/bin/docs/API.md#multihop-module)

---

### Ghost - Stealth Mode

Your WireGuard traffic is disguised as standard HTTPS web traffic. Bypass DPI (Deep Packet
Inspection) systems and firewall blocks for censorship-resistant connectivity.

![Ghost Flow](documentation/docs/assets/static/images/index/flow-diagrams/connection-flow-ghost.svg)

**Key Features:**
- WebSocket tunneling (wstunnel)
- Automatic Let's Encrypt SSL certificates
- Client configuration export via `phantom-casper`

> **Detailed Usage:** [API Documentation - Ghost Module](phantom/bin/docs/API.md#ghost-module)

---

### MultiGhost - Maximum Privacy

Combine Ghost and Multihop modules for the highest level of privacy and censorship
resistance. Your connection is disguised as HTTPS and routed through a dual VPN layer.

![MultiGhost Flow](documentation/docs/assets/static/images/index/flow-diagrams/connection-flow-multighost.svg)

**Activation:**
```bash
# 1. Enable Ghost Mode
phantom-api ghost enable domain="cdn.example.com"

# 2. Import external VPN
phantom-api multihop import_vpn_config config_path="/path/to/vpn.conf"

# 3. Enable Multihop
phantom-api multihop enable_multihop exit_name="vpn-exit"
```

> **Detailed Usage:** [API Documentation - Full Censorship Resistance](phantom/bin/docs/API.md#enable-full-censorship-resistance)

---

## Access Methods

| Method              | Command                         | Description                      |
|---------------------|---------------------------------|----------------------------------|
| **Interactive CLI** | `phantom-wg`                    | Rich TUI-based user interface    |
| **API**             | `phantom-api <module> <action>` | Programmatic access, JSON output |
| **Ghost Export**    | `phantom-casper <client>`       | Ghost Mode client configuration  |

---

## Documentation

| Document                                         | Description                            |
|--------------------------------------------------|----------------------------------------|
| [API Documentation](phantom/bin/docs/API.md)     | Detailed reference for all API actions |
| [Module Architecture](phantom/modules/README.md) | Technical architecture and data models |

---

## Trademark Notice

This project is an independent VPN management implementation that uses the
[WireGuard](https://www.wireguard.com/) protocol. It is not affiliated, associated,
authorized, endorsed by, or in any way officially connected with Jason A. Donenfeld,
ZX2C4 or Edge Security.

WireGuard® is a registered trademark of Jason A. Donenfeld.

---

## License

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>

This software is licensed under the AGPL-3.0 license. See [LICENSE](LICENSE) for details.

For third-party licenses, see [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

---

## 🎖️ Acknowledgments

This project would not be possible without the following open source projects:

- **[WireGuard](https://www.wireguard.com/)**
- **[wstunnel](https://github.com/erebe/wstunnel)**
- **[Let's Encrypt](https://letsencrypt.org/)**
- **[Rich](https://github.com/Textualize/rich)**
- **[TinyDB](https://github.com/msiemens/tinydb)**
- **[qrcode](https://github.com/lincolnloop/python-qrcode)**

---

## Support

Phantom-WG is an open-source project. If you'd like to support the project:

**Monero (XMR):**
```
84KzoZga5r7avaAqrWD4JhXaM6t69v3qe2gyCGNNxAaaJgFizt1NzAQXtYoBk1xJPXEHNi6GKV1SeDZWUX7rxzaAQeYyZwQ
```

**Bitcoin (BTC):**
```
bc1qnjjrsfdatnc2qtjpkzwpgxpmnj3v4tdduykz57
```

---

<!--suppress HtmlDeprecatedAttribute -->

<div align="center">

![Phantom Logo](phantom/bin/docs/assets/phantom-horizontal-master-midnight-phantom.svg#gh-light-mode-only)
![Phantom Logo](phantom/bin/docs/assets/phantom-horizontal-master-stellar-silver.svg#gh-dark-mode-only)

</div>