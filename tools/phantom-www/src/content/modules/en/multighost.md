---
id: multighost
label: MultiGhost
mini_desc: Maximum Privacy
title: MultiGhost Scenario
subtitle: Symphony of Invisibility Layers
icon: multighost
order: 4
---

MultiGhost is an advanced security scenario where the **Multihop** and **Ghost** modules are used together.
In this scenario, your connection is masked as HTTPS traffic while your traffic is routed through an external
VPN server, creating a double layer. By combining the strengths of both modules, this approach provides an
ideal solution for use cases requiring maximum privacy and censorship resistance.

The connection to the **Phantom-WG** server is concealed by the Ghost module and appears as standard
HTTPS traffic. Once the traffic reaches the server, it is routed to an external VPN server via the Multihop
module. This way, you bypass DPI systems while achieving a high level of anonymity through the double VPN layer.

Both modules operate independently and can be disabled at any time.

## How It Works

With MultiGhost, your traffic follows this path:

- **Normal Flow**: Clients → Phantom-WG → Internet
- **Ghost Flow**: Clients → HTTPS/WebSocket (Port 443) → Phantom-WG → Internet
- **MultiGhost Flow**: Clients → HTTPS/WebSocket (Port 443) → Phantom-WG → VPN Exit → Internet

This layered structure both bypasses DPI systems and makes traffic analysis harder. Your connection appears
as HTTPS while your real destination and IP address remain hidden behind the double VPN layer.

## Key Features

### Maximum Security

- **Dual Protection**: DPI bypass + double VPN layer working together
- **Censorship Resistance**: Overcomes network blocks with HTTPS masking
- **Traffic Analysis Difficulty**: The layered structure makes tracing extremely difficult

### Modular Architecture

- **Independent Modules**: Ghost and Multihop can be managed separately
- **Flexible Usage**: Enable or disable each module at any time
- **Automatic Orchestration**: Phantom-WG ensures modules operate independently yet harmoniously

## Quick Start

### Prerequisites

1. A domain name (A record pointed to your server) or sslip.io
2. An external VPN server WireGuard client configuration

### MultiGhost Activation

**Step 1:** Enable Ghost mode:

```bash
phantom-api ghost enable domain="cdn.example.com"
```

**Step 2:** Import the external VPN configuration:

```bash
phantom-api multihop import_vpn_config config_path="/home/user/exit-wg.conf"
```

**Step 3:** Enable Multihop mode:

```bash
phantom-api multihop enable_multihop exit_name="exit-wg"
```

### Status Check and Testing

Check Ghost module status:

```bash
phantom-api ghost status
```

Check Multihop module status:

```bash
phantom-api multihop status
```

Test the VPN exit connection:

```bash
phantom-api multihop test_vpn
```

### Disabling Modules

Disable Multihop mode:

```bash
phantom-api multihop disable_multihop
```

Disable Ghost mode:

```bash
phantom-api ghost disable
```