---
id: multihop
label: Multihop
mini_desc: Double VPN
title: Multihop Module
subtitle: Layered Multi-VPN Architecture
icon: server
order: 2
---

The Multihop module routes your traffic through an external WireGuard server, creating a **double VPN layer**.
This external server can be either a commercial VPN provider or another server you have set up yourself.
**Phantom-WG** connects to the external server using the WireGuard client configuration you provide and
routes all traffic through this connection. Simply import the client configuration — the entire routing process
is managed automatically by the system.

This advanced architecture makes traffic analysis significantly harder, providing high levels of anonymity and
multiple security layers. **Phantom-WG** manages this process fully automatically, giving you complete
flexibility and control without depending on any third party or service.

Thanks to the system's flexibility, you can also chain multiple **Phantom-WG** servers together and route
your traffic sequentially through them. By importing the WireGuard client configuration from each
**Phantom-WG** server as the exit server configuration in the previous server's Multihop module, you can
build a layered chain structure. Each server connects to the next one as a client and routes traffic through it.
This approach lets you build a multi-server chain entirely under your own control, creating a reliable
infrastructure tailored to your use cases without relying on commercial VPN providers.

## How It Works

With Multihop, your traffic follows this path:

- **Normal Flow**: Clients → Phantom-WG → Internet
- **Multihop Flow**: Clients → Phantom-WG → VPN Exit → Internet

This layered approach conceals your real IP address behind a **double VPN layer** and makes tracing your traffic
significantly harder.

## Key Features

### Security Advantages

- **IP Concealment**: Your real IP address is hidden behind two layers
- **Layered Routing**: Makes traffic analysis harder
- **Exit Point Flexibility**: Your own server or any VPN provider of your choice — the decision is yours
- **Private VPN Network**: Secure, uninterrupted connectivity between peers when Multihop is active

## Quick Start

### VPN Configuration Management

Import a WireGuard client configuration:

```bash
phantom-api multihop import_vpn_config config_path="/home/user/exit-wg.conf"
```

List existing exit points:

```bash
phantom-api multihop list_exits
```

Remove an exit point configuration:

```bash
phantom-api multihop remove_vpn_config exit_name="exit-wg"
```

### Multihop Activation

Enable Multihop mode:

```bash
phantom-api multihop enable_multihop exit_name="exit-wg"
```

Check Multihop connection status:

```bash
phantom-api multihop status
```

Test the VPN exit connection:

```bash
phantom-api multihop test_vpn
```

Disable Multihop mode:

```bash
phantom-api multihop disable_multihop
```

### Advanced Operations

View Multihop session logs:

```bash
phantom-api multihop get_session_log lines=50
```

Completely reset Multihop state:

```bash
phantom-api multihop reset_state
```