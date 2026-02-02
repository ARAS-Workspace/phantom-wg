---
id: ghost
label: Ghost
mini_desc: Stealth Mode
title: Ghost Module
subtitle: Censorship-Resistant Tunnel Architecture
icon: ghost
order: 3
---

The Ghost module disguises your WireGuard traffic as standard **HTTPS web traffic**, helping you bypass DPI
systems and firewall blocks. It achieves this using the [**wstunnel**](https://github.com/erebe/wstunnel)
service under the hood. **Phantom-WG** automatically handles wstunnel service configuration, SSL
certificate management, firewall rules, and systemd services. Simply provide a domain with its A record
pointed to your server — the system takes care of the entire technical process.

You can use both your own domain name and free services such as sslip.io or nip.io.

## How It Works

With Ghost, your traffic follows this path:

- **Normal Flow**: Clients → WireGuard (Port 51820) → Internet
- **Ghost Flow**: Clients → HTTPS/WebSocket (Port 443) → WireGuard → Internet

Thanks to this transformation, censorship systems do not see VPN traffic — they only see a legitimate HTTPS
connection.

## Key Features

### Censorship Resistance

- **DPI Bypass**: WireGuard traffic is wrapped in WebSocket and appears as HTTPS
- **Port 443 Usage**: Operates over the standard HTTPS port that cannot be blocked

### Ease of Setup

- **Automatic Configuration**: Firewall rules, wstunnel configuration, and WireGuard configuration are fully
  automated
- **Easy Client Setup**: Ready-to-use client configurations with step-by-step instructions via phantom-casper

## Quick Start

### Domain Preparation

Point your domain's A record to your server IP, or use sslip.io.

### Ghost Module Management

Enable Ghost mode (with a domain):

```bash
phantom-api ghost enable domain="cdn.example.com"
```

Enable Ghost mode (with sslip.io):

```bash
phantom-api ghost enable domain="157-230-114-231.sslip.io"
```

Check Ghost module connection status:

```bash
phantom-api ghost status
```

Disable Ghost mode:

```bash
phantom-api ghost disable
```

### Client Configuration

Get the Ghost client configuration via phantom-casper:

```bash
phantom-casper [username]
```